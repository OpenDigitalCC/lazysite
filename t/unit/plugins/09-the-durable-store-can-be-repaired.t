#!/usr/bin/perl
# SM343 + SM341 + SM339: the durable day store, made complete, dated, and
# repairable.
#
# Three filings, one artefact, and they had to be done together because each
# blocks the others.
#
# SM343 - A CLOSED DAY WAS FROZEN AT THE LAST CALL MADE DURING IT. Today's file
# was refreshed on every call and a closed day was written only if absent, so a
# file created at 14:00 on Tuesday WAS Tuesday's permanent record and Tuesday's
# evening never reached it. A day file was complete only if nobody looked at the
# statistics that day. Measured in the field: one day frozen at 19:23 with 838
# scanner hits absent, because a field-validation agent read the store during it.
# Reading the statistics damaged the statistics.
#
# SM341 - THE PAYLOAD COULD NOT SAY WHEN IT WAS MADE. The index carried
# `generated`; the day and month payloads carried nothing, so an agent holding a
# rollup from before an upgrade and one from after could say what changed and
# not when either was produced. It cost a real claim - whether a day file
# predated a capture or was created by it was not establishable from the
# artefact.
#
# SM339 - AND NOTHING COULD REPAIR WHAT WAS ALREADY WRITTEN. A file written once
# can never acquire a field added later, so SM338's basis stamp never reached a
# closed day; and historical days keep basis 1 with their asset-inflated counts,
# correctly, until something recounts them.
#
# The recount is DRY RUN BY DEFAULT because it writes over the only durable
# record a site has, and BOUNDED by the retained logs because that is all it can
# honestly rebuild.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json encode_json);
use POSIX      qw(strftime);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
ok( -f $plugin, 'the stats plugin is present' );

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\nfirst_party: true\n";
    close $cf;
    return $d;
}

sub log_event {
    my ( $d, $when, $path ) = @_;
    my $day = strftime( '%Y%m%d', localtime($when) );
    open my $fh, '>>', "$d/lazysite/logs/access-$day.jsonl" or die $!;
    print $fh encode_json( {
            t => $when, p => $path, s => 200, b => 100,
            u => 'Mozilla/5.0 Chrome/120', v => 'reader', r => '-',
    } ) . "\n";
    close $fh;
}

sub run {
    my ( $d, @args ) = @_;
    local $ENV{DOCUMENT_ROOT} = $d;

    # LIST FORM, no shell. The first version was
    # `qx($^X \Q$plugin\E @args 2>/dev/null)`, which interpolates a list into a
    # command STRING - it re-splits on whitespace, so an argument containing a
    # space silently becomes two. t/lint/40 exists for exactly that and caught
    # this, which is the lint doing its job on the person who has been writing
    # lints all week.
    open my $ph, '-|', $^X, $plugin, @args
        or die "cannot run the plugin: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    return eval { decode_json($out) };
}

sub day_file {
    my ( $d, $day ) = @_;
    my $p = "$d/lazysite/stats/daily/$day.json";
    return undef unless -f $p;
    return decode_json( do { open my $fh, '<', $p or die $!; local $/; <$fh> } );
}

my $YEST    = time() - 86400;
my $YESTDAY = strftime( '%Y-%m-%d', localtime($YEST) );

subtest 'a short day file is rewritten from the bucket that has the whole day'
    => sub {
    # THE UPGRADE CASE, which is also the repair. An existing site has closed
    # day files written by the old engine - short, because each was frozen at
    # the last call made during its day - and a cache whose BUCKET for that day
    # is complete, because the bucket kept accumulating after the file stopped.
    #
    # An earlier version of this subtest tried to reproduce the freeze by
    # logging yesterday's events and calling today. That does not reproduce it:
    # the engine sees a closed day on the first call and finalises it correctly,
    # so the fixture measured the fix working rather than the defect. The defect
    # needs a file that is already short and a cache that has never finalised
    # it, which is exactly what an upgrading site has.
    my $d = site();
    log_event( $d, $YEST + $_, "/p$_" ) for 1 .. 10;
    run( $d, '--export', '--window', 30 );
    is( day_file( $d, $YESTDAY )->{pageviews}, 10,
        'the bucket holds the whole day' );

    # Damage it the way the old engine did, and remove the finalise marker the
    # old engine never wrote.
    my $path   = "$d/lazysite/stats/daily/$YESTDAY.json";
    my $rollup = day_file( $d, $YESTDAY );
    $rollup->{pageviews} = 3;
    open my $fh, '>', $path or die $!;
    print {$fh} encode_json($rollup);
    close $fh;

    my $cpath = "$d/lazysite/cache/stats-export.json";
    my $cache = decode_json( do { open my $c, '<', $cpath or die $!; local $/; <$c> } );
    ok( delete $cache->{final}, 'the pre-upgrade cache has no finalise marker' );
    open my $co, '>', $cpath or die $!;
    print {$co} encode_json($cache);
    close $co;

    run( $d, '--export', '--window', 30 );
    is( day_file( $d, $YESTDAY )->{pageviews}, 10,
        'the next run repairs it from the bucket' )
        or diag( 'Three means a closed day is still written once and never '
            . 'revisited, so every day an upgrading site already has stays '
            . 'short for ever.' );
    };

subtest 'and is not rewritten on every call thereafter' => sub {
    # The reason it was write-once in the first place. Finalising must cost one
    # extra write per day, not one per call.
    my $d = site();
    log_event( $d, $YEST + $_, "/p$_" ) for 1 .. 3;
    run( $d, '--export', '--window', 30 );
    run( $d, '--export', '--window', 30 );    # the finalising call

    my $path  = "$d/lazysite/stats/daily/$YESTDAY.json";
    my $mtime = ( stat $path )[9];
    sleep 1;
    run( $d, '--export', '--window', 30 );
    is( ( stat $path )[9], $mtime,
        'a settled closed day is left alone' )
        or diag( 'Rewriting every closed day on every call turns the durable '
            . 'store into a write amplifier - which is why it was write-once.' );
};

subtest 'a day and a month say when they were produced' => sub {
    my $d = site();
    log_event( $d, time() - 60, '/article' );
    run( $d, '--export', '--window', 30 );

    my $today = strftime( '%Y-%m-%d', localtime );
    my $day   = day_file( $d, $today );
    like( $day->{generated}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'the day payload carries a generated timestamp' )
        or diag( 'Without it, two rollups cannot be ordered from the artefacts '
            . 'alone - only from the notes of whoever fetched them.' );

    my ($mon) = $today =~ /^(\d{4}-\d{2})/;
    my $m = decode_json( do {
            open my $fh, '<', "$d/lazysite/stats/monthly/$mon.json" or die $!;
            local $/;
            <$fh>;
    } );
    like( $m->{generated}, qr/^\d{4}-\d{2}-\d{2}T/,
        'and so does the month' );
};

subtest 'the durable files are byte-comparable' => sub {
    # SM339 needs this: a repair somebody has to trust must be checkable with
    # diff, and Perl's hash order is randomised per process, so the same content
    # written twice produced different bytes.
    my $d = site();
    log_event( $d, time() - 60, '/article' );
    run( $d, '--export', '--window', 30 );
    my $today = strftime( '%Y-%m-%d', localtime );
    my $path  = "$d/lazysite/stats/daily/$today.json";
    my $first = do { open my $fh, '<', $path or die $!; local $/; <$fh> };
    run( $d, '--export', '--window', 30 );
    my $second = do { open my $fh, '<', $path or die $!; local $/; <$fh> };

    # SM370: EXCEPT `generated`, which is SUPPOSED to differ.
    #
    # This flaked at roughly 1 run in 40 and cost a filing that named the wrong
    # subtest and the wrong cause. The two writes are byte-identical unless they
    # straddle a second boundary, at which point the SM341 timestamp inside the
    # payload moves - 06:50:01Z against 06:50:02Z - and a full byte comparison
    # fails on the one field whose entire purpose is to change.
    #
    # SM341 added that field after this assertion was written, so the test kept
    # a claim the payload had stopped being able to satisfy. Normalising it out
    # keeps what SM339 actually needs - canonical ORDERING, so an operator
    # auditing a repair can diff two files and see only what changed - and stops
    # asserting something that is false by design.
    my $norm = sub {
        my ($json) = @_;
        $json =~ s/"generated":"[^"]*"/"generated":"<stamped>"/;
        return $json;
    };
    is( $norm->($second), $norm->($first),
        'the same content written twice is byte-identical, bar the timestamp' )
        or diag( 'Without canonical ordering an operator auditing a repair '
            . 'sees every line move and cannot tell a reordering from a '
            . 'change.' );

    # And the field really is there to move - asserted, so normalising it out
    # cannot quietly become normalising away a field that stopped being written.
    like( $first, qr/"generated":"\d{4}-\d{2}-\d{2}T/,
        'and the payload does carry the timestamp being normalised' );
};

subtest 'the recount reports before it writes' => sub {
    my $d = site();
    log_event( $d, $YEST + $_, "/p$_" ) for 1 .. 4;
    run( $d, '--export', '--window', 30 );

    my $dry = run( $d, '--recount' );
    ok( $dry->{ok},      'the dry run succeeds' );
    ok( $dry->{dry_run}, 'and says it is a dry run' );
    cmp_ok( $dry->{days_the_logs_cover}, '>=', 1,
        'it names how many days the retained logs can rebuild' );
    like( $dry->{note}, qr/Nothing was changed/,
        'and says plainly that it changed nothing' )
        or diag( 'This writes over the only durable record a site has. A verb '
            . 'that acts by default is the wrong shape however good the '
            . 'arithmetic is.' );
};

subtest 'the recount repairs a truncated day, and says what it changed' => sub {
    # The whole point, end to end: a day damaged by SM343 on an engine that had
    # the defect, then repaired by the verb.
    my $d = site();
    log_event( $d, $YEST + $_, "/p$_" ) for 1 .. 3;
    run( $d, '--export', '--window', 30 );

    # Freeze the file as the old engine would have left it, and add the rest of
    # the day to the log. The file is now short by seven.
    log_event( $d, $YEST + $_, "/p$_" ) for 4 .. 10;
    my $path   = "$d/lazysite/stats/daily/$YESTDAY.json";
    my $frozen = day_file( $d, $YESTDAY );
    is( $frozen->{pageviews}, 3, 'the file is short, as the old engine left it' );

    my $res = run( $d, '--recount', '--apply' );
    ok( $res->{ok} && $res->{applied}, 'the recount applied' ) or diag explain $res;
    is( day_file( $d, $YESTDAY )->{pageviews}, 10,
        'the repaired day holds the whole day' );

    cmp_ok( $res->{changed}, '>=', 1, 'and it reports the day as changed' );
    is( $res->{before}{$YESTDAY}{pageviews}, 3,  'reporting what it was' );
    is( $res->{after}{$YESTDAY}{pageviews},  10, 'and what it became' )
        or diag( '"It ran" is not a result. A repair over durable data has to '
            . 'say what it did to each day, or nobody can check it.' );
};

done_testing();
