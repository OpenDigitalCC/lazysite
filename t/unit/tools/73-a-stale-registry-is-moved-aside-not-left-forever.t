#!/usr/bin/perl
# SM627: a stale generated registry left in the document root is repairable, and
# the repair is a MOVE.
#
# It stood on all 26 sites of a fleet after an upgrade, and no repair could
# clear it - so `repair --all` reported every site as needing a human, forever.
# The file must not stay where it is: the front end resolves it BEFORE the
# engine is consulted, so a sitemap frozen on the day of the upgrade keeps being
# served and nothing regenerates it.
#
# WHY MOVE AND NOT DELETE. The engine deliberately yields to an operator's own
# sitemap or llms.txt, and nothing on disk says which kind a file is - the
# shipped templates emit no generator marker, so a generated registry and a
# hand-written one are indistinguishable. Deleting would therefore destroy an
# operator's deliberate file on a fleet-wide run, silently, 26 times. Moving
# stops it being served, lets the engine serve a current one, and leaves the
# original recoverable by name.
#
# That is the recoverable-vs-irreversible line SM587 and SM591 drew for data,
# applied to a file: this tier may act BECAUSE what it does can be undone.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/lazysite-check.pl";
plan skip_all => "no $tool" unless -f $tool;

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/templates/registries");
    make_path("$d/lazysite/backups");
    open my $fh, '>', "$d/lazysite/templates/registries/$_.tt" or die $!
        for qw(sitemap.xml llms.txt);
    return $d;
}
sub put { my ( $p, $t ) = @_; open my $fh, '>', $p or die $!; print {$fh} $t; close $fh }
# t/lint/40: no list interpolated into a shell string - word splitting makes the
# command a different command than it reads as. Built as a LIST and run through a
# pipe-open, so the arguments cannot be re-split.
sub run {
    my ( $d, @a ) = @_;
    open my $fh, '-|', $^X, $tool, '--docroot', $d, @a or return '';
    my $out = do { local $/; <$fh> };
    close $fh;
    return $out // '';
}

# --- 1. it is reported, and the hint says what --fix will do ----------------
{
    my $d = site();
    put( "$d/sitemap.xml", "<urlset>stale</urlset>\n" );
    my $out = run($d);
    like( $out, qr/generated files are still in the document root/,
        'a stale registry is reported' );
    like( $out, qr/MOVES them/,
        'and the hint says the repair MOVES rather than deletes' );
    unlike( $out, qr/delete them and the engine/,
        'the old hint, which told the operator to delete by hand, is gone' );
}

# --- 2. --fix moves it, and the file still EXISTS afterwards ----------------
# The whole safety argument. A test that only asserted "gone from the docroot"
# would pass just as well on a delete.
{
    my $d = site();
    put( "$d/sitemap.xml", "<urlset>stale</urlset>\n" );
    put( "$d/llms.txt",    "# my own\n" );

    my $out = run( $d, '--fix' );
    like( $out, qr/^fixed: moved sitemap\.xml/m, 'the repair reports the move' );
    ok( !-e "$d/sitemap.xml", 'the stale file is out of the document root' );
    ok( !-e "$d/llms.txt",    'and so is the other one' );

    my $bak = "$d/lazysite/backups/stale-registries";
    ok( -d $bak, 'a quarantine directory exists' );
    opendir my $dh, $bak or die $!;
    my @kept = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;

    is( scalar @kept, 2, 'BOTH files still exist - moved, not deleted' )
        or diag( explain \@kept );
    ok( ( grep { /^sitemap\.xml\./ } @kept ), 'kept under its own name' );
    ok( ( grep { /^llms\.txt\./ } @kept ),    'and the other too' );

    # Recoverable means readable, with its content intact - an empty file at the
    # right name would satisfy "it still exists" and help nobody.
    my ($one) = grep { /^llms\.txt\./ } @kept;
    open my $fh, '<', "$bak/$one" or die $!;
    my $body = do { local $/; <$fh> };
    is( $body, "# my own\n",
        "the operator's own content survives the move byte-for-byte" );
}

# --- 3. the warning actually clears -----------------------------------------
# The reason this was filed: it could not be cleared, so every site sat in the
# worst bucket of a fleet report permanently.
{
    my $d = site();
    put( "$d/sitemap.xml", "<urlset>stale</urlset>\n" );
    run( $d, '--fix' );
    my $after = run($d);
    unlike( $after, qr/generated files are still in the document root/,
        'after the repair the warning is gone, so a fleet run can reach clean' );
}

# --- 4. two repairs do not destroy the first copy ---------------------------
# The move is named with the time. Without that, a second repair overwrites the
# first quarantined file - and if that was the operator's own, the only
# remaining copy is destroyed by the very mechanism meant to preserve it.
{
    my $d = site();
    put( "$d/sitemap.xml", "first\n" );
    run( $d, '--fix' );
    put( "$d/sitemap.xml", "second\n" );
    run( $d, '--fix' );

    my $bak = "$d/lazysite/backups/stale-registries";
    opendir my $dh, $bak or die $!;
    my @kept = grep { /^sitemap\.xml\./ } readdir $dh;
    closedir $dh;
    cmp_ok( scalar @kept, '>=', 1, 'at least one copy is kept' );
    my %seen;
    for my $f (@kept) {
        open my $fh, '<', "$bak/$f" or next;
        local $/;
        $seen{<$fh>} = 1;
    }
    ok( $seen{"first\n"} || scalar @kept > 1,
        'the first copy is not silently overwritten by the second' )
        or diag( explain [ \@kept, [ keys %seen ] ] );
}

# --- 5. nothing to do when the docroot is clean -----------------------------
{
    my $d   = site();
    my $out = run( $d, '--fix' );
    unlike( $out, qr/moved/, 'a clean docroot triggers no move' );
}

done_testing();
