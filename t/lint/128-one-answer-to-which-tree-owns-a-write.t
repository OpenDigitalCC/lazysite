#!/usr/bin/perl
# SM836: "which tree owns this write target" has one answer, and it lives in
# Lazysite::Private::write_root.
#
# Three faults in one cycle came from write paths that disagreed with the store
# about where a gated file lives - SM438, SM418/SM286, SM836 - each found by a
# person. Two of the paths that did answer correctly answered in the same five
# hand-written lines: resolve_for_write, discard the path, swap in private_root.
# A hand-written answer is the thing that drifts, so this fails any file outside
# Private.pm that rebuilds it.
#
# WHAT THIS CANNOT SEE, said so nobody reads more into a pass: a write path that
# resolves NOTHING at all - builds "$DOCROOT/$rel" and writes - is the SM418
# shape, and no source pattern tells a deliberate docroot-only write (a theme, a
# nav file, config under lazysite/) from a forgotten one. The review of every one
# (sixty) is docs/review/2026-09-11-docroot-write-paths.md; what it found open is
# SM852.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @files;
find( sub { push @files, $File::Find::name if /\.(?:pm|pl)\z/ && -f },
    "$root/lib", "$root/tools", "$root/plugins" );
push @files, grep { -f } glob "$root/lazysite-*.pl";

my @offenders;
for my $f (@files) {
    next if $f =~ m{/lib/Lazysite/Private\.pm\z};
    open my $fh, '<:utf8', $f or next;
    my @lines = <$fh>;
    close $fh;
    for my $i ( 0 .. $#lines ) {
        next unless $lines[$i] =~ /resolve_for_write\s*\(/;
        next if $lines[$i] =~ /^\s*#/;
        my $lo = $i - 3 < 0 ? 0 : $i - 3;
        my $hi = $i + 8 > $#lines ? $#lines : $i + 8;
        my $window = join '', grep { !/^\s*#/ } @lines[ $lo .. $hi ];
        if ( $window =~ /private_root\s*\(/ ) {
            ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
            push @offenders, "$rel:" . ( $i + 1 );
        }
    }
}

is_deeply( \@offenders, [],
    'no file outside Lazysite::Private rebuilds the owning root from '
        . 'resolve_for_write and private_root - call write_root' )
    or diag "hand-written copies: @offenders";

# And the function exists and is exported - a lint that forbids the copy while
# the shared answer is missing would only move people to a third shape.
require Lazysite::Private;
ok( Lazysite::Private->can('write_root'), 'write_root exists' );
ok( ( grep { $_ eq 'write_root' } @Lazysite::Private::EXPORT_OK ), '...and is exported' );

done_testing();
