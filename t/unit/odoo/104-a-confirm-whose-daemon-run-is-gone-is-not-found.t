#!/usr/bin/perl
# SM1261 (release manager, 2026-10-22): A CONFIRM WHOSE DAEMON RUN IS GONE IS NOT-FOUND.
#
# A plan the daemon made is confirmed by its run id (Lazysite::Odoo _confirm_daemon).
# The daemon finds the plan by path, lazysite/odoo/runs/<run_id>/plan.json
# (Odoo::Ops::Service _plan_path), so when that folder or file is gone OOM fails in
# Plan->load with "cannot read plan ...", kind `config`. The page was told "the Odoo
# connection is not configured correctly" (503), which is not what happened, and
# nothing told the visitor what to do. It now answers `not-found` (404), as a plan
# lazysite does not hold does, saying to make the plan again, and naming no path.
# THE REAL oomd, as t/unit/odoo/77 runs it.
use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet fake_shop);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Manager::Common ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my $d     = oomd_site( odoo_packs => 'Odoo::Test::Ops,Odoo::Test::OomdOps' );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'later', operation => 'test.fail', modes => 'authenticated', callers => 'staff',
    params => 'why=why' );
my %WHO = ( mode => 'authenticated', actor => 'alice', caps => { manage_connectors => 1 }, groups => ['staff'], ip => '192.0.2.7' );

sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return <$fh> }

sub plan_it {
    my ( undef, $p ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('later');
            Lazysite::Odoo::call( $b, { why => 'never sent' }, %WHO );
    } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    is( Lazysite::Odoo::last_via(), 'daemon', 'by the daemon' );
    my $meta = decode_json( slurp( Lazysite::Odoo::plans_dir() . "/$p->{plan}/meta.json" ) );
    my $run  = "$d/lazysite/odoo/runs/$meta->{run_id}";
    ok( $meta->{run_id} && -e "$run/plan.json", 'the daemon holds the run' );
    return ( $p->{plan}, $run );
}

sub confirm_gone {
    my ($pid) = @_;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $pid, %WHO ) } );
    ok( !$c->{ok} && !$c->{applied}, 'nothing applied' ) or diag explain $c;
    is( $c->{kind}, 'not-found', 'not-found, not config' ) or diag explain $c;
    like( $c->{error}, qr/make the plan again/, 'the sentence says what to do' );
    unlike( $c->{error}, qr{/|runs}, 'and names no path' );
    is( Lazysite::Manager::Common::refusal_status( $c->{kind} ), '404 Not Found', 'the endpoint answers 404' );
    my $rec = ( Lazysite::Odoo::read_calls() || [] )->[0] || {};
    is( $rec->{kind},    'not-found', 'the call record says not-found' );
    is( $rec->{outcome}, 'refused',   'as a refusal' );
    return $c;
}

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );

subtest 'the run folder is gone' => sub {
    my ( $pid, $run ) = plan_it();
    remove_tree($run);
    confirm_gone($pid);
};

subtest 'the run folder is there and its plan file is gone' => sub {
    my ( $pid, $run ) = plan_it();
    unlink "$run/plan.json";
    confirm_gone($pid);
};

subtest 'a run that is there still confirms' => sub {
    my ($pid) = plan_it();
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $pid, %WHO ) } );
    is( $c->{kind}, 'apply-incomplete', 'it applied (test.fail refuses its change, as in 77)' ) or diag explain $c;
};

oomd_stop($svc);
done_testing();
