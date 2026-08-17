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
my $ITER      = 20;
my $TOLERANCE = 2.0;
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

printf "%-22s %8.1f ms\n", $_, $result{$_} for sort keys %result;

if ( $mode eq 'baseline' ) {
    open my $b, '>', $BASELINE or die "$BASELINE: $!\n";
    print $b JSON::PP->new->canonical->pretty->encode( {
            _doc => "Host-relative perf baseline (ms/op). Re-capture on the CI/deploy host: tools/bench.pl --baseline. The gate (--check) fails on >tolerance x regression; a per-op override may live in tolerances{op}.",
            tolerance => $TOLERANCE,
            # SM-review D4: without this a figure cannot be interpreted. A run on a
            # loaded host and a genuinely slower engine look identical in the
            # numbers, and the 2x tolerance passes both - so nobody ever finds out
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
    close $b;
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
    my ( @fail, @unbaselined );
    for my $op ( sort keys %result ) {
        my $b0 = $base->{ops}{$op};

        # SM340: an op with no baseline used to `next` in silence, so adding an
        # op to this file LOOKED like coverage and was not compared to anything.
        # That is the defect this gate exists to catch, living in the gate: the
        # run prints a number, the check says all ops are within tolerance, and
        # one of them was never checked. Say so instead.
        if ( !defined $b0 ) { push @unbaselined, $op; next }

        my $op_tol = $base->{tolerances}{$op} // $tol;
        push @fail, sprintf( "%s: %.1f ms exceeds %.1fx baseline (%.1f ms)", $op, $result{$op}, $op_tol, $b0 )
            if $result{$op} > $op_tol * $b0;
    }
    if (@unbaselined) {
        printf "NOT CHECKED (no baseline figure): %s\n", join( ', ', @unbaselined );
        print "  Capture one before relying on this gate for that op.\n";
    }
    if (@fail) { print "PERF REGRESSION:\n", map { "  $_\n" } @fail; exit 1 }
    printf "perf: %d op(s) within tolerance of baseline%s\n",
        scalar( keys %result ) - scalar(@unbaselined),
        ( @unbaselined ? sprintf( ', %d not checked', scalar @unbaselined ) : '' );
}
