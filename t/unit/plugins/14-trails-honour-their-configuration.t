#!/usr/bin/perl
# SM393: trails honour their configuration - and the switch that turns them off
# does not also turn off the deletion.
#
# Three documented claims, each asserted here because each is the kind that
# quietly stops being true:
#   `trails: off` stops the RECORDING
#   it does NOT stop the EXPIRY - a site that switches trails off must still age
#     out what it already wrote, or "off" silently means "frozen for ever"
#   `trails_retention_days` is honoured, and deletes only what is PAST it
#
# The keys live in stats.conf, not lazysite.conf. A first version of this
# fixture put them in lazysite.conf, where read_conf never looks, and every
# assertion passed for the wrong reason - `trails: off` appeared not to work
# because the key was never read at all.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $now = time();

# SM600: every day this fixture names is measured from the instant its RECORDS
# carry (90 minutes back, so the export closes the session), not from the
# clock. Inside 90 minutes of UTC midnight the two fall on different days and
# the pre-seeded trail files land a day away from the log they are checked
# against. `$now` stays real: the export compares against real time to decide
# what is old enough to close.
my $rec = $now - 5400;

sub day_of { my @t = gmtime( $rec - ( $_[0] * 86_400 ) ); sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] }

# Build a site with some traffic and some pre-existing trail files, run the
# export, and hand back what survived.
sub run_site {
    my ( $stale_days, %conf ) = @_;
    my $d = tempdir( 'lazysite-trailcfg-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path( "$d/lazysite/logs", "$d/lazysite/stats/trails", "$d/lazysite/cache" );

    open my $lc, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$lc} "site_url: https://d.example.io\n";
    close $lc;

    open my $sc, '>', "$d/lazysite/stats.conf" or die $!;
    print {$sc} "$_: $conf{$_}\n" for sort keys %conf;
    close $sc;

    # Two existing days: one past the retention in force for THIS run, one
    # yesterday. The stale offset is a parameter because the retention differs
    # between the cases - a 5-day-old file is correctly KEPT under the 30-day
    # default, and an earlier version of this test read that as a failure.
    for my $ago ( $stale_days, 1 ) {
        my $f = "$d/lazysite/stats/trails/" . day_of($ago) . '.json';
        open my $fh, '>', $f or die $!;
        print {$fh} '{"date":"' . day_of($ago) . '","retention_days":30,"trails":[]}';
        close $fh;
    }

    my @t   = gmtime($rec);
    my $ymd = sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;

    # Aged past SESSION_GAP so the visit is CLOSED by the export; an open
    # session has no trail yet and would prove nothing either way.
    printf {$lf} qq({"t":%d,"p":"/p%d","s":200,"ch":"page","v":"READER","ua":"Mozilla/5.0 Chrome/120"}\n),
        $now - $_, $_
        for ( 5400, 5360, 5300 );
    close $lf;

    `DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export --window 30 2>/dev/null`;
    return $d;
}

# --- off ---------------------------------------------------------------
{
    # No retention configured, so the 30-day default is in force.
    my $d = run_site( 400, trails => 'off' );
    ok( !-f "$d/lazysite/stats/trails/" . day_of(0) . '.json',
        'trails: off records nothing for today' );
    ok( !-f "$d/lazysite/stats/trails/" . day_of(400) . '.json',
        'trails: off still expires what was already written' );
    ok( -f "$d/lazysite/stats/trails/" . day_of(1) . '.json',
        'trails: off does not delete a day that is within retention' );
}

# --- retention ---------------------------------------------------------
{
    my $d = run_site( 5, trails_retention_days => 2 );
    my $f = "$d/lazysite/stats/trails/" . day_of(0) . '.json';
    ok( -f $f, 'recording is on by default' );

    my $doc = decode_json( do { open my $fh, '<', $f or die $!; local $/; <$fh> } );
    is( $doc->{retention_days}, 2, 'the file states the configured retention, not the default' );

    ok( !-f "$d/lazysite/stats/trails/" . day_of(5) . '.json',
        'a day past the configured retention is deleted' );
    ok( -f "$d/lazysite/stats/trails/" . day_of(1) . '.json',
        'a day within it is kept - the expiry is a cutoff, not a sweep' );
}

done_testing();
