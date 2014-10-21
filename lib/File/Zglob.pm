package File::Zglob;
use strict;
use warnings FATAL => 'recursion';
use 5.008008;
our $VERSION = '0.02';
use base qw(Exporter);

our @EXPORT = qw(zglob);

use Text::Glob qw(glob_to_regex);
use File::Basename;

sub subname { $_[1] }
# use Sub::Name qw(subname);

our $SEPCHAR = $^O eq 'Win32' ? '\\' : '/';
our $DIRFLAG = \"DIR?";
our $DEEPFLAG = \"**";
our $DEBUG = 0;
our $FOLDER;

sub zglob {
    my ($pattern) = @_;
    $pattern =~ s!^\~![glob("~")]->[0]!e;
    return zglob_fold($pattern, \&cons, []);
}

sub dbg(@) {
    return unless $DEBUG;
    my ($pkg, $filename, $line, $sub) = caller(1);
    my $i = 0;
    while (caller($i++)) { 1 }
    my $msg;
    $msg .= ('-' x ($i-5));
    $msg .= " [$sub] ";
    for (@_) {
        $msg .= ' ';
        if (not defined $_) {
            $msg .= '<<undef>>';
        } elsif (ref $_) {
            local $Data::Dumper::Terse = 1;
            local $Data::Dumper::Indent = 0;
            $msg .= Data::Dumper::Dumper($_);
        } else {
            $msg .= $_;
        }
    }
    $msg .= " at $filename line $line\n";
    print($msg);
}

sub zglob_fold {
    my ($patterns, $proc, $seed) = @_;
    my @ret;
    for my $pattern (glob_expand_braces($patterns)) {
        push @ret, @{glob_fold_1($pattern, $proc, $seed)};
    }
    return @ret;
}

sub cons { [$_[0], @{$_[1]}] }

sub glob_fold_1 {
    my ($pattern, $proc, $seed) = @_;
    #dbg("FOLDING: $pattern");
    $FOLDER ||= make_glob_fs_fold();
    my ($rec, $recstar);
    $recstar = subname('recstar', sub {
        my ($node, $matcher, $seed) = @_;
        #dbg("recstar: ", $node, $matcher, $seed);
        my $dat = $FOLDER->(\&cons, [], $node, qr{^[^.].*$}, 1);
        my $foo = $rec->($node, $matcher, $seed);
        #dbg("recstar:: dat: ", $dat, " foo: ", $foo);
        for my $thing (@$dat) {
            $foo = $recstar->($thing, $matcher, $foo);
        }
        return $foo;
    });
    $rec = subname('rec' => sub {
        my ($node, $matcher, $seed) = @_;
        #dbg($node, $matcher, $seed);
        my ($current, @rest) = @{$matcher};
        if (!defined $current) {
            #dbg("FINISHED");
            return $seed;
        } elsif (ref($current) eq 'SCALAR' && $current == $DEEPFLAG) {
            #dbg("** mode");
            return $recstar->($node, \@rest, $seed);
        } elsif (@rest == 0) {
            #dbg("file name");
            # (folder proc seed node (car matcher) #f)
            return $FOLDER->($proc, $seed, $node, $current, 0);
        } else {
            #dbg "NORMAL MATCH";
            return $FOLDER->(sub {
                # my ($node, $seed) = @_;
                #dbg("NEXT: ", $node, \@rest);
                return $rec->($_[0], \@rest, $_[1]);
            }, $seed, $node, $current, 1);
        }
    });
    my ($node, $matcher) = glob_prepare_pattern($pattern);
    #dbg("pattern: ", $node, $matcher);
    return $rec->($node, $matcher, $seed);
}

# /^home$/ のような固定の文字列の場合に高速化をはかるための最適化予定地なので、とりあえず undef をかえしておいても問題がない
sub fixed_regexp_p {
    return undef;
    die "TBI"
}

sub make_glob_fs_fold {
    my ($root_path, $current_path) = @_;
    my $ensure_dirname = sub {
        my $s = shift;
        if (defined($s) && length($s) > 0 && $s =~ m{$SEPCHAR$}) {
            $s .= $SEPCHAR;
        }
        return $s;
    };
    $root_path = $ensure_dirname->($root_path);
    $current_path = $ensure_dirname->($current_path);
    
    # returns arrayref of seeds.
    subname('folder' => sub {
        my ($proc, $seed, $node, $regexp, $non_leaf_p) = @_;
        my $prefix = do {
            if (ref $node eq 'SCALAR') {
                if ($$node eq 1) { #t
                    $root_path || $SEPCHAR
                } elsif ($$node eq '0') { #f
                    $current_path || '';
                } else {
                    die "FATAL";
                }
            } else {
                $node . '/';
            }
        };
        #dbg("prefix: $prefix");
        #dbg("regxp: ", $regexp);
        if (ref $regexp eq 'SCALAR' && $regexp == $DIRFLAG) {
            $proc->($prefix, $seed);
        } elsif (my $string_portion = fixed_regexp_p($regexp)) { # /^path$/
            my $full = $prefix . $string_portion;
            if (-e $full && (!$non_leaf_p || -d $full)) {
                $proc->($full, $seed);
            } else {
                $proc;
            }
        } else { # normal regexp
            #dbg("normal regexp");
            my $dir = do {
                if (ref($node) eq 'SCALAR' && $$node eq 1) {
                    $root_path || $SEPCHAR
                } elsif (ref($node) eq 'SCALAR' && $$node eq 0) {
                    $current_path || '.';
                } else {
                    $node;
                }
            };
            #dbg("dir: $dir");
            opendir my $dirh, $dir or do {
                #dbg("cannot open dir: $dir: $!");
                return $seed;
            };
            while (my $child = readdir($dirh)) {
                next if $child eq '.' or $child eq '..';
                my $full;
                #dbg("non-leaf: ", $non_leaf_p);
                if (($child =~ $regexp) && ($full = $prefix . $child) && (!$non_leaf_p || -d $full)) {
                    #dbg("matched: ", $regexp, $child, $full);
                    $seed = $proc->($full, $seed);
                } else {
                    #dbg("Don't match: $child");
                }
            }
            return $seed;
        }
    });
}

sub glob_prepare_pattern {
    my ($pattern) = @_;
    my @path = split $SEPCHAR, $pattern;

    my $is_absolute = $path[0] eq '' ? 1 : 0;
    if ($is_absolute) {
        shift @path;
    }

    @path = map {
        if ($_ eq '**') {
            $DEEPFLAG
        } elsif ($_ eq '') {
            $DIRFLAG
        } else {
            glob_to_regex($_) # TODO: replace with original implementation?
        }
    } @path;

    return ( \$is_absolute, \@path );
}

# TODO: better error detection?
# TODO: nest support?
sub glob_expand_braces {
    my ($pattern, @more) = @_;
    if (my ($prefix, $body, $suffix) = ($pattern =~ /^(.*)\{([^}]+)\}(.*)$/)) {
        return (
            ( map { glob_expand_braces("$prefix$_$suffix") } split /,/, $body ),
            @more
        );
    } else {
        return ($pattern, @more);
    }
}

1;
__END__

=encoding utf8

=head1 NAME

File::Zglob - Extended globs.

=head1 SYNOPSIS

    use File::Zglob;

    my @files = zglob('**/*.pm');

=head1 DESCRIPTION

B<WARNINGS: THIS IS ALPHA VERSION. API MAY CHANGE WITHOUT NOTICE>

File::Zglob is extended glob. It supports C<< **/*.pm >> form.

=head1 zglob and deep recursion

C<< **/* >> form makes deep recursion by soft link. zglob throw exception if it's deep recursion.

=head1 LIMITATIONS

    - Only support UNIX-ish systems.
    - File order is not compatible with shells.

=head1 AUTHOR

Tokuhiro Matsuno E<lt>tokuhirom AAJKLFJEF GMAIL COME<gt>

=head1 THANKS TO

Most code was translated from gauche's fileutil.scm.

=head1 SEE ALSO

L<File::DosGlob>, L<Text::Glob>, gauche's fileutil.scm

=head1 LICENSE

Copyright (C) Tokuhiro Matsuno

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
