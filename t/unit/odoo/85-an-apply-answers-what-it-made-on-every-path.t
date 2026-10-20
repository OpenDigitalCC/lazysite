#!/usr/bin/perl
# SM1214 / SM1215 (OOM Lab L-21, L-20, 2026-10-19): "An immediate write still
# returns no ids (`created: {}`)" and "whether a hold's `reason` reaches the page:
# the time-off agent saw it arrive, while the attendance agent reports only
# `counts` and `by_bucket`". SM1165 (created, written) and SM1171 (changes, with
# reason) are proved in-process by t/unit/odoo/51 and 52. This is the one test that
# says every path that answers a write agrees: immediate in-process, immediate
# through oomd, confirm in-process, confirm through oomd. Each answers the id a
# create made, and a held change's reason (in the plan view and in the answer).
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet shop_ready);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my $PACK  = 'LazysiteTest::OdooMade';    # quoted alone so tools/precheck-areas.pl sees the test use it
$ENV{ODOO_OPS_NAMESPACES} = $PACK;
$ENV{PERL5LIB} .= ':' . repo_root() . '/t/lib';

my %WHO = ( mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 },
    groups => ['staff'], ip => '192.0.2.7' );

sub call_b {
    my ( $id, $in ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in, %WHO );
    } );
    return $r;
}

sub confirm_p {
    my ($plan) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::confirm( $plan, %WHO ) } );
    return $r;
}

# The partner ids Odoo holds: the fake itself in-process, the state file oomd keeps.
sub partners {
    my ($fake) = @_;
    return $fake->all_ids('res.partner') if $fake;
    open my $fh, '<', "$state/state.json" or return [ 1, 2 ];    # the seed, before oomd has kept anything
    my $s = JSON::PP->new->decode( do { local $/; <$fh> } );
    return [ sort { $a <=> $b } keys %{ $s->{data}{'res.partner'} // {} } ];
}

sub check_created {
    my ( $label, $r, $fake, $before ) = @_;
    ok( $r->{applied}, "$label: applied" ) or diag explain $r;
    my %was = map { $_ => 1 } @$before;
    my @new = grep { !$was{$_} } @{ partners($fake) };
    is( scalar @new, 1, "$label: Odoo has one new partner" );
    is_deeply( $r->{result}{created}, { 'res.partner' => [@new] }, "$label: created names the id it made" )
        or diag explain $r->{result};
    return;
}

sub check_reason {
    my ( $label, $r ) = @_;
    my ($held) = grep { ( $_->{outcome} // '' ) eq 'held' } @{ $r->{result}{changes} || [] };
    ok( $held, "$label: the held change is listed" ) or return diag explain $r->{result};
    is( $held->{reason}, 'the sheet is locked', "$label: the hold's reason reaches the page" );
    return;
}

sub paths {
    my ( $via, $d, $fake ) = @_;
    bind( $d, id => 'make_now', operation => 'test.make', modes => 'authenticated', callers => 'staff',
        apply => 'immediate', params => 'name=name' );
    bind( $d, id => 'make_later', operation => 'test.make', modes => 'authenticated', callers => 'staff',
        params => 'name=name' );

    my $before = partners($fake);
    my $r      = call_b( 'make_now', { name => 'Imm' } );
    is( Lazysite::Odoo::last_via(), $via, "$via immediate: the path taken" );
    check_created( "$via immediate", $r, $fake, $before );
    check_reason( "$via immediate", $r );

    $before = partners($fake);
    my $p = call_b( 'make_later', { name => 'Conf' } );
    ok( $p->{planned}, "$via confirm: a plan" ) or diag explain $p;
    my ($ph) = grep { $_->{action} eq 'hold' } @{ $p->{preview}{changes} || [] };
    is( $ph->{reason}, 'the sheet is locked', "$via confirm: the plan shows the reason" );
    $r = confirm_p( $p->{plan} );
    is( Lazysite::Odoo::last_via(), $via, "$via confirm: the path taken" );
    check_created( "$via confirm", $r, $fake, $before );
    check_reason( "$via confirm", $r );
    return;
}

subtest 'in-process' => sub {
    my $fields = { name => { type => 'char', string => 'Name', portable_type => 'text' } };
    my ( $d, $fake ) = shop_ready(
        conf => { odoo_packs => $PACK },
        shop => { fake => { fields => { 'res.partner' => $fields }, records => { 'res.partner' => [ { name => 'Old' } ] } } } );
    paths( 'in-process', $d, $fake );
};

subtest 'through oomd' => sub {
    my $d = oomd_site( odoo_packs => $PACK );
    $Lazysite::Odoo::DOCROOT = $d;
    my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
    ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
        or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );
    paths( 'daemon', $d, undef );
    oomd_stop($svc);
};

done_testing;
