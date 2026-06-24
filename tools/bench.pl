#!/usr/bin/perl
# tools/bench.pl - lazysite performance benchmark + regression gate (WP-3 /
# D3). Measures the hot paths - page render and credential verification - and
# compares to a committed baseline. Numbers are HOST-RELATIVE: re-capture on
# your CI/deploy host with --baseline. The gate (--check) fails only on a
# GROSS regression (default 3x the baseline) so it catches real slowdowns
# without flaking on host variance.
#
#   perl tools/bench.pl            # run + print ms/op
#   perl tools/bench.pl --baseline # write dist/config/bench-baseline.json
#   perl tools/bench.pl --check    # compare to baseline; exit 1 on regression
use strict;
use warnings;
use Time::HiRes qw(time);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;

( my $ROOT = $FindBin::Bin ) =~ s{/tools$}{};
my $ITER      = 20;
my $TOLERANCE = 3.0;
my $BASELINE  = "$ROOT/dist/config/bench-baseline.json";
my $mode = ( grep { $_ eq '--baseline' } @ARGV ) ? 'baseline'
         : ( grep { $_ eq '--check' }    @ARGV ) ? 'check'
         :                                          'run';

my $utool = "$ROOT/tools/lazysite-users.pl";
my $proc  = "$ROOT/lazysite-processor.pl";

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
    $cb->() for 1 .. 2;          # warm up
    my $t0 = time();
    $cb->() for 1 .. $n;
    return ( ( time() - $t0 ) / $n ) * 1000;   # ms/op
}

# --- minimal site fixture ---
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Bench\n"; close $cf;
open my $ix, '>', "$d/index.md" or die $!;
print $ix "---\ntitle: Home\n---\n\n# Hello\n\nA page with **markdown**, a [link](/about), and a list:\n\n- one\n- two\n- three\n";
close $ix;
uapi( $d, { action => 'add', username => 'pwuser',  password => 'benchpw' } );
uapi( $d, { action => 'add', username => 'tokuser', password => 'x' } );
my $token = uapi( $d, { action => 'token', username => 'tokuser' } )->{token};
die "bench setup failed (no token)\n" unless $token;

# --- ops ---
local %ENV = %ENV;
$ENV{DOCUMENT_ROOT} = $d; $ENV{REQUEST_METHOD} = 'GET'; $ENV{QUERY_STRING} = '';
my %result = (
    render_ms => bench( $ITER, sub {
        local $ENV{REDIRECT_URL} = '/index';
        qx($^X \Q$proc\E 2>/dev/null);
    } ),
    verify_token_ms => bench( $ITER, sub {
        uapi( $d, { action => 'verify-credential', username => 'tokuser', secret => $token } );
    } ),
    verify_password_ms => bench( $ITER, sub {
        uapi( $d, { action => 'verify-credential', username => 'pwuser', secret => 'benchpw' } );
    } ),
);

printf "%-22s %8.1f ms\n", $_, $result{$_} for sort keys %result;

if ( $mode eq 'baseline' ) {
    open my $b, '>', $BASELINE or die "$BASELINE: $!\n";
    print $b JSON::PP->new->canonical->pretty->encode( {
        _doc => "Host-relative perf baseline (ms/op). Re-capture on the CI/deploy host: tools/bench.pl --baseline. The gate (--check) fails only on >tolerance x regression.",
        tolerance  => $TOLERANCE,
        iterations => $ITER,
        ops        => { map { $_ => 0 + sprintf( '%.1f', $result{$_} ) } keys %result },
    } );
    close $b;
    print "wrote baseline: $BASELINE\n";
}

if ( $mode eq 'check' ) {
    die "no baseline ($BASELINE) - run --baseline first\n" unless -f $BASELINE;
    open my $b, '<', $BASELINE or die "$BASELINE: $!\n";
    my $base = decode_json( do { local $/; <$b> } ); close $b;
    my $tol = $base->{tolerance} || $TOLERANCE;
    my @fail;
    for my $op ( sort keys %result ) {
        my $b0 = $base->{ops}{$op} or next;
        push @fail, sprintf( "%s: %.1f ms exceeds %.1fx baseline (%.1f ms)", $op, $result{$op}, $tol, $b0 )
            if $result{$op} > $tol * $b0;
    }
    if (@fail) { print "PERF REGRESSION:\n", map { "  $_\n" } @fail; exit 1 }
    print "perf: all ops within ${tol}x of baseline\n";
}
