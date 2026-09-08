#!/usr/bin/perl
# SM766 (SM760's lesson, made a rule): a store reader never turns an
# unopenable file into an empty answer in silence.
#
# `open ... or return {}` on a file that EXISTS turned a permissions fault
# into "this account holds nothing" for the runtime and a dead process for
# Status - both read as facts about the site, both wrong, neither logged.
#
# SM768: the connector store, added in 0.13.5, was not on this lint's list and
# the field found the same fault there within a day - `has_secret: 0` for a
# secret that was merely unreadable. A lint that names the stores it protects
# protects the stores somebody remembered.
#
# SM770, so that forgetting is not the default outcome:
#
#   1. THE CATALOGUE DECIDES, not this file. Lazysite::Stores classifies every
#      directory under lazysite/ as a store or not, with the reason written
#      down. A directory the engine uses and the catalogue does not name fails
#      here - so a store added next release is covered the day it appears.
#   2. `or do { ... }` IS A FAILURE BRANCH. The old regex only saw a return on
#      the same line as the open, so the multi-line form SM768 itself
#      introduced was invisible to the very lint that asked for it.
#   3. NO STAT GUARD IN FRONT OF A STORE READ. A stat the process is not
#      allowed to make fails the same way as an open it is not allowed to
#      make, and `return {} unless -f $path` renders that as absence before
#      the open can report it. Where a reader caches on file identity the stat
#      serves the cache key, never the absence decision.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Stores qw(stores store_for);

my $root = "$FindBin::Bin/../..";

# --- 1. every directory the engine uses under lazysite/ is classified --------
subtest 'the catalogue names every lazysite/ directory the engine uses' => sub {
    my @src;
    find( { wanted => sub { push @src, $File::Find::name if /\.p[ml]\z/ && -f }, no_chdir => 1 },
        "$root/lib" );
    push @src, grep { -f } map { "$root/$_" } qw(lazysite-manager-api.pl lazysite-mcp.pl
        lazysite-auth.pl lazysite-processor.pl lazysite-dav.pl);

    my %seen;
    for my $f (@src) {
        open my $fh, '<', $f or die "$f: $!";
        while ( my $l = <$fh> ) {
            next if $l =~ m{^\s*#};
            next if $l =~ m{/usr/share/|/etc/lazysite}; # the installed tree, not a site's
                # A DIRECTORY, which means the name is followed by a slash or ends
                # the string. `lazysite/notify.conf` is a file and `content="lazysite/i`
                # is a regex with its modifier - neither is a directory.
            while ( $l =~ m{lazysite/([a-z][a-z0-9_-]*)(?=/|['"\)\},]|\s*$)}g ) {
                push @{ $seen{$1} }, ( $f =~ s{^\Q$root/\E}{}r );
            }
        }
        close $fh;
    }

    my %known        = map       { $_->{dir} => 1 } stores();
    my @unclassified = sort grep { !$known{$_} } keys %seen;
    is_deeply( \@unclassified, [], 'no unclassified directory under lazysite/' )
        or diag( "Add each to Lazysite::Stores - a store whose readers obey the rule, or\n"
            . "not a store WITH THE REASON. Found in:\n"
            . join( "\n", map { "  $_: " . join( ', ', @{ $seen{$_} }[ 0 .. 1 ] ) } @unclassified ) );

    # NOT the other direction: a reader reaches its store through a helper
    # (`_dir()`, `_auth_dir()`, `$AUTH_DIR`) far more often than it spells the
    # path, so "nothing mentions this entry" says nothing about whether it is
    # read. `connectors` is the proof - Connectors.pm never writes the literal.
};

# --- 2. every read-open in a store's modules reports before returning --------
#
# Two shapes count as a failure branch: `or return`/`or next` on the line, and
# `or do {` opening a block. The block is read to its closing brace.
sub _read_opens {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    my @found;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;
        next unless $l =~ /\bopen\s*\(?\s*my\s+\$\w+\s*,\s*'<[^']*'\s*,/;
        next unless $l =~ /\bor\b/;
        my $text  = $l;
        my $lines = 1;
        if ( $l =~ /\bor\s+do\s*\{/ ) {    # read the block
            my $depth = 1;
            for my $j ( $i + 1 .. $#lines ) {
                $text .= $lines[$j];
                $lines++;
                $depth++ while $lines[$j] =~ /\{/g;
                $depth-- while $lines[$j] =~ /\}/g;
                last if $depth <= 0;
                last if $lines > 12;    # a failure branch is short; longer is a smell
            }
        }
        elsif ( $l !~ /\b(?:return|next)\b/ ) { next }
        push @found, { line => $i + 1, text => $text };
    }
    return @found;
}

subtest 'every store reader reports through cannot_read before returning' => sub {
    my $n = 0;
    my @bad;
    for my $s ( grep { $_->{store} } stores() ) {
        for my $rel ( @{ $s->{modules} } ) {
            my $f = "$root/$rel";
            ok( -f $f, "$rel exists (catalogue: $s->{dir})" ) or next;
            for my $o ( _read_opens($f) ) {
                $n++;
                next if $o->{text} =~ /cannot_read\s*\(/;
                next if $o->{text} =~ /# not a store/;
                push @bad, "$rel:$o->{line}: " . ( $o->{text} =~ s/\s+/ /gr );
            }
        }
    }
    cmp_ok( $n, '>=', 12, "read-opens with a failure branch found ($n)" );
    is_deeply( \@bad, [], 'every one reports through cannot_read before returning' )
        or diag join "\n", @bad;
};

# --- 3. no stat guard in front of a store read ------------------------------
subtest 'no -f/-e guard stands in front of a store read' => sub {
    my @guards;
    for my $s ( grep { $_->{store} } stores() ) {
        for my $rel ( @{ $s->{modules} } ) {
            my $f = "$root/$rel";
            next unless -f $f;
            open my $fh, '<', $f or die "$f: $!";
            my $i = 0;
            while ( my $l = <$fh> ) {
                $i++;
                next if $l =~ /^\s*#/;
                # SM778: `[^;]*` after the condition word, not `\s*`. The first
                # spelling of this only matched a guard whose -f came straight
                # after the `unless`, so `return {} unless defined $DIR && -f
                # $path` - the guard TWO store readers were actually using -
                # was invisible to the check written to find it.
                next unless $l =~ /\b(?:return|next)\b[^;]*\b(?:unless|if\s*!)\b[^;]*-[fe]\b/;
                next if $l     =~ /# not a store/;
                push @guards, "$rel:$i: " . ( $l =~ s/^\s+|\s+$//gr );
            }
            close $fh;
        }
    }
    is_deeply( \@guards, [], 'absence is the open\'s ENOENT, never a stat' )
        or diag( "A stat the process may not make fails like an open it may not make.\n"
            . join( "\n", @guards ) );
};

done_testing;
