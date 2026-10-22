#!/usr/bin/perl
# SM1256: `lazysite-hestia-domain add ... --channel certified` IS ACCEPTED.
#
# ADR 0010 put a fourth rung on the update ladder, and `lazysite provision`,
# install.pl and `lazysite channel` take it. The Hestia integrator passes its
# --channel straight on to provision, but checked the value first against the
# three-rung list, so a Hestia site could not be provisioned on `certified`
# (reported from the lazysite.io content check, 2026-10-22, D-6).
#
# Without root the verb stops at require_root, which runs AFTER the option
# checks - so a value the checks accept reaches the root refusal, and one they
# refuse never does. That ordering is what this reads.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

plan skip_all => 'run as root, the verb goes on to change the host' if $> == 0;

my $ROOT = repo_root();
my $TOOL = "$ROOT/tools/lazysite-hestia-domain.pl";

sub run_tool {
    my (@args) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for qw(LAZYSITE_HESTIA_HOME LAZYSITE_REGISTRY_DIR LAZYSITE_POOLS_DIR
        LAZYSITE_DAEMON_DIR LAZYSITE_WEB_GROUP);
    my $cmd = join ' ', map {quotemeta} $^X, $TOOL, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

for my $ch (qw(edge beta stable certified)) {
    my ( $rc, $out ) = run_tool( 'add', 'someuser', 'example.test', '--channel', $ch );
    isnt( $rc, 0, "--channel $ch: stops without root" );
    unlike( $out, qr/--channel must be/, "--channel $ch: the value is accepted" );
    like( $out, qr/must run as root/, "--channel $ch: and the run reaches the root check" );
}

my ( $rc, $out ) = run_tool( 'add', 'someuser', 'example.test', '--channel', 'gold' );
isnt( $rc, 0, 'an unknown channel is refused' );
like( $out, qr/--channel must be 'edge', 'beta', 'stable' or 'certified'/,
    'naming the four the ladder has' );

my ( undef, $help ) = run_tool('--help');
like( $help, qr/--channel edge\|beta\|stable\|certified/, 'the usage lists certified' );

done_testing();
