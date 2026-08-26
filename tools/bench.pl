#!/usr/bin/perl
# tools/bench.pl - lazysite performance benchmark + regression gate. Measures
# the hot paths - cache-hit serve, full render (cache miss) and credential
# verification - and compares to a committed baseline. Numbers are
# HOST-RELATIVE: re-capture on your CI/deploy host with --baseline (the
# baseline records host/perl/date provenance, and --check warns on a host
# mismatch). The gate fails on >2x the baseline by default; a per-op override
# may be set in the baseline's tolerances map.
#
#   perl tools/bench.pl            # run + print ms/op
#   perl tools/bench.pl --baseline # write dist/config/bench-baseline.json
#   perl tools/bench.pl --check    # compare to baseline; exit 1 on regression
use strict;
use warnings;
use Time::HiRes qw(time);
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use Sys::Hostname qw(hostname);
use POSIX         qw(strftime);

( my $ROOT = $FindBin::Bin ) =~ s{/tools$}{};
my $ITER = 20;
# SM327: 1.25, and the figure is DELIBERATE rather than merely tighter.
#
# It was 2.0. Every operation had drifted 9-26% slower than the 2026-07-02
# baseline on the same host, same Perl, same iteration count, and 2x passed all
# of it comfortably - on every release including four cut in one fortnight.
#
# The attribution said the drift arrives as ACCRETION rather than one step, so a
# 2x gate cannot ever catch it: nothing single is ever large enough. 1.25 would
# have caught the one real step and will catch the next, while staying well
# clear of a measured ~1.5% noise floor.
#
# NOT TIGHTER STILL, on purpose. A flaky gate gets ignored, which is worse than
# a wide one - and these are host-relative timings that SM342 deliberately
# reports rather than fails on, precisely because a busy host and a slower
# engine look identical in milliseconds.
my $TOLERANCE = 1.25;
my $BASELINE  = "$ROOT/dist/config/bench-baseline.json";
my $mode      = ( grep { $_ eq '--baseline' } @ARGV ) ? 'baseline'
    : ( grep { $_ eq '--check' } @ARGV ) ? 'check'
    :                                      'run';

my $utool = "$ROOT/tools/lazysite-users.pl";
my $proc  = "$ROOT/lazysite-processor.pl";
my $stats = "$ROOT/plugins/stats.pl";          # SM340

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
sub bench {
    my ( $n, $cb ) = @_;
    $cb->() for 1 .. 2;                         # warm up
    my $t0 = time();
    $cb->() for 1 .. $n;
    return ( ( time() - $t0 ) / $n ) * 1000;    # ms/op
}

# --- minimal site fixture ---
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Bench\n"; close $cf;
open my $ix, '>', "$d/index.md" or die $!;
print $ix "---\ntitle: Home\n---\n\n# Hello\n\nA page with **markdown**, a [link](/about), and a list:\n\n- one\n- two\n- three\n";
close $ix;
# SM340: first-party logs, so the statistics op below measures ingestion rather
# than the "no log configured" early return. An op pointed at an empty fixture
# reports a fast, stable, meaningless number - which is the shape of defect this
# suite exists to remove, and it would be a poor way to introduce coverage for a
# bug that was itself a control doing nothing.
#
# Thirty days of traffic, because the cost being guarded is linear in RETAINED
# log volume: the defect was that every call re-ingested all of it, so a
# single-day fixture would have shown almost nothing wrong.
make_path("$d/lazysite/logs");
{
    my $now = time();
    for my $back ( 0 .. 29 ) {
        my $when = $now - $back * 86400;
        my @lt   = localtime($when);
        my $name = sprintf '%04d%02d%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3];
        open my $lf, '>', "$d/lazysite/logs/access-$name.jsonl" or die $!;
        for my $i ( 1 .. 150 ) {
            print {$lf} encode_json( {
                    t => $when - $i,
                    p => ( $i % 5 == 0  ? '/assets/img/a.jpg' : "/page-" . ( $i % 20 ) ),
                    s => ( $i % 17 == 0 ? 404                 : 200 ),
                    b => 100,
                    u => 'Mozilla/5.0 Chrome/120',
                    v => 'visitor-' . ( $i % 40 ),
                    r => ( $i % 3 == 0 ? 'https://example.net/x' : '-' ),
            } ) . "\n";
        }
        close $lf;
    }
}
open my $sc, '>', "$d/lazysite/lazysite.conf" or die $!;
print $sc "site_name: Bench\nfirst_party: true\n";
close $sc;

uapi( $d, { action => 'add', username => 'pwuser',  password => 'benchpw' } );
uapi( $d, { action => 'add', username => 'tokuser', password => 'x' } );
my $token = uapi( $d, { action => 'token', username => 'tokuser' } )->{token};
die "bench setup failed (no token)\n" unless $token;

# --- ops ---
# Two render ops (eight-dimension review D4): the warm-up writes index.html,
# so a plain re-request is a CACHE HIT and never exercises the markdown/TT
# pipeline. render_miss_ms deletes the cache before each iteration to time the
# real render; render_cache_hit_ms times the serve-from-cache path (the one
# most visitors hit).
local %ENV = %ENV;
$ENV{DOCUMENT_ROOT} = $d; $ENV{REQUEST_METHOD} = 'GET'; $ENV{QUERY_STRING} = '';
my %result = (
    render_cache_hit_ms => bench( $ITER, sub {
            local $ENV{REDIRECT_URL} = '/index';
            qx($^X \Q$proc\E 2>/dev/null);
    } ),
    render_miss_ms => bench( $ITER, sub {
            unlink "$d/index.html";
            local $ENV{REDIRECT_URL} = '/index';
            qx($^X \Q$proc\E 2>/dev/null);
    } ),
    verify_token_ms => bench( $ITER, sub {
            uapi( $d, { action => 'verify-credential', username => 'tokuser', secret => $token } );
    } ),
    verify_password_ms => bench( $ITER, sub {
            uapi( $d, { action => 'verify-credential', username => 'pwuser', secret => 'benchpw' } );
    } ),

    # SM340: the statistics export. Added because it was the one hot path with
    # NO coverage here at all, and what hid there was a 3.5-second per-call cost
    # on the default surface - the export cache was written every run and never
    # read, so every call re-ingested the whole retained log. It was found by a
    # partner agent timing its own tool calls from outside, not by this gate.
    #
    # SM327 established that a 2x tolerance permits unbounded accretion. An op
    # that is not measured at all is the same argument with no tolerance to
    # argue about, so the remedy is coverage before it is a tighter number.
    #
    # THE CACHE IS LEFT IN PLACE between iterations deliberately. Clearing it
    # would time a cold rebuild every time, which is the broken behaviour, and
    # would have reported this defect as normal.
    stats_export_ms => bench( $ITER, sub {
            qx($^X \Q$stats\E --export --window 30 2>/dev/null);
    } ),
);

# SM342: WORK, alongside time.
#
# Time here is a number about this machine. The same export costs ~630 ms on
# this host and ~3.0 s of engine time on a real instance, and the gap is mostly
# contended storage - so a change that adds reads or writes is nearly free here
# and expensive in the field. A duration gate cannot see that coming.
#
# What DOES transfer is how much the operation did. "It re-read every retained
# log on every call" is the same statement on any disk, and it is what SM340
# turned out to be. So the export reports its own counters and they are recorded
# beside the timings - exact, host-independent, and comparable across machines
# in a way no millisecond figure is.
#
# TWO measurements, because one of them is the interesting one.
#
# COLD is a full ingest with no cache: how much a site's whole retained log
# costs to read. It scales with retention and is the size of the job.
#
# WARM is the next call, with nothing new in the log. It should be ZERO - the
# offsets say everything has been read, so there is nothing to do. That number
# is the SM340 detector: when the cache was never loaded, the warm read was the
# ENTIRE log, every call, on every site. A zero that becomes non-zero is that
# defect returning, and it reads the same on any disk.
#
# Not timed. This is a property of the call, not of the clock.
sub work_of {
    local $ENV{DOCUMENT_ROOT} = $d;
    my $json = qx($^X \Q$stats\E --export --window 30 2>/dev/null);
    my $r    = eval { decode_json($json) };
    return ( $r && ref $r->{work} eq 'HASH' ) ? $r->{work} : {};
}
unlink "$d/lazysite/cache/stats-export.json";
my $cold = work_of();
my $warm = work_of();

%result = (
    %result,
    work_cold_log_bytes    => ( $cold->{log_bytes_read}    // 0 ),
    work_cold_log_files    => ( $cold->{log_files_read}    // 0 ),
    work_warm_log_bytes    => ( $warm->{log_bytes_read}    // 0 ),
    work_warm_log_files    => ( $warm->{log_files_read}    // 0 ),
    work_warm_days_written => ( $warm->{day_files_written} // 0 )
);

for my $op ( sort grep { !/^work_/ } keys %result ) {
    printf "%-22s %8.1f ms\n", $op, $result{$op};
}
# SM342: printed apart from the timings, because they are a different kind of
# number. A millisecond figure is about this machine; a count is about the code.
for my $w ( sort grep { /^work_/ } keys %result ) {
    printf "%-22s %8d\n", $w, $result{$w};
}

# SM601: THE LOAD AT CAPTURE, which the baseline has claimed to record since
# 2026-08-15 and never could - the field was written into the encode and the
# function was never defined, so `--baseline` died at the point of writing and
# the mode has been dead ever since. Nobody noticed because re-capturing is the
# only thing that calls it, and nothing re-captured until the 0.11.0 stable
# prep.
#
# It exists because a run on a loaded host and a genuinely slower engine look
# identical in the numbers - the comment beside the field says exactly that.
sub _loadavg {
    open my $fh, '<', '/proc/loadavg' or return undef;
    my $l = <$fh>;
    close $fh;
    return undef unless defined $l;
    my @f = split ' ', $l;
    return @f >= 3 ? [ map { $_ + 0 } @f[ 0 .. 2 ] ] : undef;
}

if ( $mode eq 'baseline' ) {

    # SM327: RE-CAPTURING OVER A REGRESSION HAS TO BE SAID OUT LOUD.
    #
    # This is the whole filing. The baseline was dated 2026-07-02 and the
    # compliance gate warns it is stale at a stable cut, so re-capturing was the
    # queued housekeeping task. Doing it would have raised the baseline to the
    # current, slower numbers and removed any way to see the engine had got
    # slower: a warning clears, the gate goes green, and the regression becomes
    # the new definition of correct.
    #
    # That is the exact shape this project has spent a fortnight removing from
    # other people's code - a control reporting success because the bar moved -
    # and it must not be introduced into the perf gate to clear a housekeeping
    # warning.
    #
    # So a re-capture that would RAISE any op beyond tolerance refuses, and says
    # which ops and by how much. --accept-regression proceeds, and the point of
    # the flag is not to be hard to type: it is that somebody has to state that
    # these numbers are RIGHT rather than merely current, which is what a
    # baseline claims.
    if ( -f $BASELINE && !grep { $_ eq '--accept-regression' } @ARGV ) {
        my $old = eval {
            open my $of, '<', $BASELINE or die;
            local $/;
            JSON::PP->new->decode(<$of>);
        };
        my @worse;
        for my $op ( sort keys %{ $old->{ops} || {} } ) {
            next if $op =~ /^work_/;
            my $was = $old->{ops}{$op} or next;
            next unless defined $result{$op};
            my $ratio = $result{$op} / $was;
            push @worse, sprintf( '%s %.2fx (%.1f -> %.1f ms)',
                $op, $ratio, $was, $result{$op} )
                if $ratio >= ( $old->{tolerance} || $TOLERANCE );
        }
        if (@worse) {
            print {*STDERR} "bench: REFUSING to re-capture over a regression.\n";
            print {*STDERR} "bench:   $_\n" for @worse;
            print {*STDERR} "bench:\n";
            print {*STDERR} "bench: Writing this baseline would make the slower\n";
            print {*STDERR} "bench: numbers the new definition of correct, and the\n";
            print {*STDERR} "bench: stale-baseline warning would clear on the way.\n";
            print {*STDERR} "bench: Explain the drift first. If it is understood and\n";
            print {*STDERR} "bench: accepted, say so: --accept-regression\n";
            exit 1;
        }
    }

    # SM601: TEMP FILE AND RENAME, because `open '>'` truncates BEFORE the
    # encode runs - so when the encode died on the missing _loadavg it left a
    # zero-byte baseline behind. A failed capture destroyed the reference it was
    # meant to replace, and outside a git checkout that reference is simply
    # gone. The refusal path above is careful never to reach the write; this
    # makes the write itself as careful.
    my $tmp = "$BASELINE.tmp.$$";
    open my $b, '>', $tmp or die "$tmp: $!\n";
    print $b JSON::PP->new->canonical->pretty->encode( {
            _doc => "Host-relative perf baseline (ms/op). Re-capture on the CI/deploy host: tools/bench.pl --baseline. Timings are REPORTED against tolerance, never failed on (SM342); work counters fail. A per-op override may live in tolerances{op}. Re-capturing over a regression requires --accept-regression (SM327).",
            tolerance => $TOLERANCE,
            # SM-review D4: without this a figure cannot be interpreted. A run on a
            # loaded host and a genuinely slower engine look identical in the
            # numbers, and a wide tolerance passes both - so nobody ever finds out
            # which they are looking at.
            loadavg    => _loadavg(),
            iterations => $ITER,
            # Provenance (review D4): a baseline is only meaningful on the host
            # that captured it - record where/when so a cross-host comparison is
            # visible instead of silent.
            host        => hostname(),
            perl        => "$^V",
            captured_at => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
            ops => { map { $_ => 0 + sprintf( '%.1f', $result{$_} ) } keys %result },
    } );
    close $b or die "$tmp: $!\n";
    rename $tmp, $BASELINE or die "$BASELINE: $!\n";
    print "wrote baseline: $BASELINE\n";
}

if ( $mode eq 'check' ) {
    die "no baseline ($BASELINE) - run --baseline first\n" unless -f $BASELINE;
    open my $b, '<:raw', $BASELINE or die "$BASELINE: $!\n";
    my $base = decode_json( do { local $/; <$b> } ); close $b;
    my $tol  = $base->{tolerance} || $TOLERANCE;
    printf "baseline: captured %s on %s (perl %s)\n",
        $base->{captured_at} // 'unknown-date', $base->{host} // 'unknown-host',
        $base->{perl} // '?';
    print "WARNING: baseline host differs from this host (" . hostname() . ") - numbers are host-relative\n"
        if defined $base->{host} && $base->{host} ne hostname();
    # SM342: TIME IS REPORTED, WORK IS CHECKED.
    #
    # The release manager's instruction, and it is the right shape: this should
    # be comparative - to see whether work has increased, or an optimisation
    # actually landed - rather than a pass/fail on a duration.
    #
    # A duration measured here says little about a contended shared disk, and
    # SM327 established that a 2x tolerance permits unbounded accretion anyway.
    # So every op's time is printed WITH its ratio to the baseline, for a human
    # to read, and no timing failure is raised. A count is different: it is
    # exact, it is the same on any machine, and an increase means the code is
    # doing more than it did. That is what fails.
    my ( @fail, @unbaselined, @slower, @faster );
    for my $op ( sort keys %result ) {
        my $b0 = $base->{ops}{$op};

        # SM340: an op with no baseline used to `next` in silence, so adding an
        # op to this file LOOKED like coverage and was not compared to anything.
        # That is the defect this gate exists to catch, living in the gate: the
        # run prints a number, the check says all ops are within tolerance, and
        # one of them was never checked. Say so instead.
        if ( !defined $b0 ) { push @unbaselined, $op; next }

        # A work counter: exact, host-independent, and the thing that decides.
        if ( $op =~ /^work_/ ) {
            push @fail,
                sprintf( "%s: %d, was %d - the code is doing MORE than it did",
                $op, $result{$op}, $b0 )
                if $result{$op} > $b0;
            push @faster,
                sprintf( "%s: %d, was %d", $op, $result{$op}, $b0 )
                if $result{$op} < $b0;
            next;
        }

        # A duration: reported with its ratio, never failed on. See above.
        my $ratio = $b0 ? ( $result{$op} / $b0 ) : 0;
        my $line  = sprintf( "  %-22s %8.1f ms  baseline %8.1f  %.2fx",
            $op, $result{$op}, $b0, $ratio );
        my $op_tol = $base->{tolerances}{$op} // $tol;
        if    ( $ratio >= $op_tol ) { push @slower, "$line   <- beyond tolerance" }
        elsif ( $ratio >= 1.15 )    { push @slower, $line }
        elsif ( $ratio <= 0.85 )    { push @faster, $line }
    }
    if (@unbaselined) {
        printf "NOT CHECKED (no baseline figure): %s\n", join( ', ', @unbaselined );
        print "  Capture one before relying on this gate for that op.\n";
    }
    if (@faster) { print "FASTER / LESS WORK than baseline:\n", map { "$_\n" } @faster }
    if (@slower) { print "SLOWER than baseline (reported, not failed):\n", map { "$_\n" } @slower }

    if (@fail) {
        print "WORK REGRESSION - the code is doing more than it did:\n",
            map { "  $_\n" } @fail;
        print "  A count is host-independent, so this is not a slow machine.\n";
        exit 1;
    }
    my $timed = scalar( grep { !/^work_/ } keys %result );
    my $work  = scalar( grep { /^work_/ } keys %result );
    printf "perf: %d timing(s) reported, %d work counter(s) checked%s\n",
        $timed, $work,
        ( @unbaselined ? sprintf( ', %d not checked', scalar @unbaselined ) : '' );
}
