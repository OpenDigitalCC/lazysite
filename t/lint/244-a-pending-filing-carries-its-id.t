#!/usr/bin/perl
# P22 (WORK-PLAN-0154), ruled 2026-10-12 "Fix both": the release step stamps a
# filing's "SHIPPED (PENDING)" status-note by the filing's `id:` (tools/
# release-material.pl), so a filing with no id cannot be stamped. 35 said
# PENDING and had none - SM842 and 34 under archive/ - and each now carries the
# id its file name gives it.
#
# This keeps it so: every filing whose status-note still says SHIPPED
# (PENDING) carries an `id:`, and the id is the SM number its file name begins
# with - an id copied from a neighbour would stamp the wrong filing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $dir   = repo_root() . '/docs/feature-requests';
my @files = sort( glob("$dir/SM*.md"), glob("$dir/archive/SM*.md") );
cmp_ok( scalar @files, '>=', 60, 'the feature-request corpus is present' );

my ( $pending, @missing, @wrong ) = (0);
for my $f (@files) {
    ( my $rel = $f ) =~ s{^\Q$dir\E/}{};
    open my $fh, '<', $f or do { fail("$rel: unreadable"); next };
    my $text = do { local $/; <$fh> };
    close $fh;
    my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s or next;
    next unless $fm =~ /^status-note:\s*"SHIPPED \(PENDING\)/m;
    $pending++;
    my ($named) = $rel =~ m{(?:\A|/)(SM\d+[a-z]?)-};
    my ($id)    = $fm  =~ /^id:\s*(\S+)\s*$/m;
    if    ( !defined $id )                     { push @missing, $rel }
    elsif ( !defined $named || $id ne $named ) { push @wrong,   "$rel: id $id" }
}
cmp_ok( $pending, '>', 0, 'there are PENDING filings to check' );
is_deeply( \@missing, [], 'every SHIPPED (PENDING) filing carries an id: the release step stamps by it' )
    or diag( "No `id:` in the front matter, so tools/release-material.pl can never stamp these:\n  "
        . join( "\n  ", @missing ) );
is_deeply( \@wrong, [], '...and the id is the SM number its file name begins with' )
    or diag( join "\n", @wrong );

done_testing();
