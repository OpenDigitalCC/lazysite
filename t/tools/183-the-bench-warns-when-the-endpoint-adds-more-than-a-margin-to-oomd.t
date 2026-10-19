#!/usr/bin/perl
# SM1180: THE BENCH'S ADVISORY MARGIN CHECK.
#
# Inbox 2026-10-19: "lazysite adds at most ~10-20 ms to what oomd takes" and "a timing
# check for the endpoint against oomd for one fixed operation, failing above a set
# margin". tools/bench-surfaces.sh --odoo-margin prints a WARN line (and exits 0) when
# the endpoint adds more than the margin (default 20 ms; --margin-ms changes it). It is
# advisory and never in the suite, so what is asserted here is the VERDICT, driven by
# BENCH_MARGIN_STUB="endpoint_ms,direct_ms" in place of any timing: the WARN appears
# above the margin and not at or below it, the flag moves the margin, the exit is 0
# either way, and a default bench run does not carry the check.
use strict;
use warnings;
use Test::More;
use IPC::Open3 ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $sh = repo_root() . '/tools/bench-surfaces.sh';
plan skip_all => 'taskset is not installed on this host' unless grep { -x "$_/taskset" } split /:/, $ENV{PATH};

sub run {
    my ( $stub, @args ) = @_;
    local %ENV = %ENV;
    delete $ENV{BENCH_SURFACES_CONSTRAINED};
    $ENV{BENCH_MARGIN_STUB} = $stub if defined $stub;
    my $pid = IPC::Open3::open3( my $in, my $ph, undef, "/bin/bash", $sh, @args );
    close $in;
    my $out = do { local $/; <$ph> };
    waitpid $pid, 0;
    return ( $? >> 8, $out );
}

my ( $rc, $out ) = run( '100,70', '--odoo-margin' );
is( $rc, 0, 'above the margin the exit is still 0 (advisory)' );
like( $out, qr/endpoint 100\.0 ms, direct oomd client 70\.0 ms, the endpoint adds 30\.0 ms \(margin 20 ms\)/, 'the figures are said' );
like( $out, qr/^bench-margin: WARN .*30\.0 ms.*20 ms margin/m, 'a WARN line appears above the margin' );

( $rc, $out ) = run( '85,70', '--odoo-margin' );
is( $rc, 0, 'below the margin the exit is 0' );
like( $out, qr/adds 15\.0 ms/, 'the figures are said' );
unlike( $out, qr/WARN/, 'and there is no WARN below the margin' );

( $rc, $out ) = run( '90,70', '--odoo-margin' );
unlike( $out, qr/WARN/, 'exactly at the margin is not above it' );

( $rc, $out ) = run( '100,70', '--odoo-margin', '--margin-ms', '40' );
unlike( $out, qr/WARN/, 'a larger --margin-ms moves the margin' );
like( $out, qr/margin 40 ms/, '...and says it' );

( $rc, $out ) = run( '75,70', '--odoo-margin', '--margin-ms', '3' );
like( $out, qr/WARN/, 'a smaller --margin-ms warns on less' );

( $rc, $out ) = run( undef, '--odoo-margin' );
isnt( $rc, 0, 'without a site and a binding (and no stub) it refuses rather than guess' );
like( $out, qr/needs --margin-docroot/, '...and says what it needs' );

( $rc, $out ) = run( '100,70', '--n', '1', '--surface', 'page' );
is( $rc, 0, 'a plain bench run succeeds' );
unlike( $out, qr/bench-margin/, 'and carries no margin check unless asked' );

done_testing;
