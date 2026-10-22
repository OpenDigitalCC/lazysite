#!/usr/bin/perl
# SM1248: A CHANGE OF odoo_packs RELOADS oomd WITH NO GAP.
#
# Until OOM 0.39, oomd read the extra operation namespaces from ODOO_OPS_NAMESPACES at
# its start, so the service (Lazysite::Daemon::Service::Oomd) restarted it when
# odoo_packs changed. While it restarted there was no socket: with odoo_daemon
# `required` every call was refused as daemon-down, and with `on` it ran in-process
# (SM1211's "Checked and not the cause"). OOM 0.39 reads `namespaces` from oomd's
# config, and its `reload` verb builds the new workers first and swaps them in once
# each one answers. A request that arrives meanwhile waits (Odoo::Ops::Daemon, "Reload").
# lazysite now writes the namespaces into the conf (Lazysite::Odoo::Daemon), and on
# SIGHUP the service asks the verb (_reload) instead of restarting.
#
# THE REAL oomd, started as t/unit/odoo/61 starts it, with odoo_daemon `required`, so a
# gap would be a refused call and could not pass for an in-process one. The test's own
# environment names a pack the config does not: the config must be what oomd serves.
use strict;
use warnings;
use Test::More;
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip bind quiet fake_shop write_conf);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Odoo::Daemon ();
use Lazysite::Daemon::Service::Oomd ();

my $state = oomd_env();
my ( $A, $B ) = ( 'Odoo::Test::OomdOps', 'Odoo::Test::Ops' );
$ENV{ODOO_OPS_NAMESPACES} = "$A,$B";    # inherited by the service and so by oomd
my %SITE = ( odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
    odoo_allow_writes => 'true', odoo_daemon => 'required', odoo_daemon_workers => 2 );
my $d = oomd_site( %SITE, odoo_packs => $A );
$Lazysite::Odoo::DOCROOT = $d;
no warnings 'once';
$Lazysite::Odoo::TRANSPORT = fake_shop();

bind( $d, id => 'who', operation => 'oomd.pid', modes => 'public' );

sub run_b {
    my ($id) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.7' );
    } );
    return $r;
}
sub has_ns { my ( $h, $ns ) = @_; return scalar grep { $_ eq $ns } @{ $h->{namespaces} || [] } }
sub slurp  { open my $fh, '<', $_[0] or return ''; local $/; return <$fh> }

# The packs changed and the service told, as a config save does (refresh, then SIGHUP).
# Calls are made from the signal until oomd's generation is $gen, and for two seconds
# at least, which spans the service's turn (0.2 s) and the reload; each must be the
# daemon's answer.
my $svc;
sub change_and_call {
    my ( $packs, $gen ) = @_;
    write_conf( $d, %SITE, odoo_packs => $packs );
    my $w = Lazysite::Odoo::Daemon::write_conf($d);
    my $t0 = Time::HiRes::time();
    kill 'HUP', $svc;
    my ( $n, @bad ) = (0);
    while ( Time::HiRes::time() < $t0 + 30 ) {
        my $r = run_b('who');
        $n++;
        push @bad, $r unless $r->{ok} && ( Lazysite::Odoo::last_via() // '' ) eq 'daemon';
        my $h = oomd_up($d);
        last if $h && ( $h->{generation} // 0 ) >= $gen && Time::HiRes::time() > $t0 + 2;
        Time::HiRes::sleep(0.025);    # a steady caller, not a load
    }
    return ( $w, $n, \@bad );
}

$svc = oomd_start( sub {
        open STDERR, '>>', "$state/service.log";
        Lazysite::Daemon::Service::Oomd::run( docroot => $d );
} );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'the real oomd is up' )
    or BAIL_OUT( 'oomd did not start: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );
my $h0 = oomd_up($d);
my $pid = $h0->{pid};

subtest 'the conf names the packs, and the environment does not reach oomd' => sub {
    like( slurp( Lazysite::Odoo::Daemon::conf_path($d) ), qr/^namespaces = \Q$A\E$/m, 'the conf names odoo_packs' );
    is( $h0->{generation}, 1, 'generation 1' );
    ok( has_ns( $h0, $A ), "oomd serves $A" );
    ok( !has_ns( $h0, $B ), "and not $B, which only the environment names" ) or diag explain $h0->{namespaces};
};

subtest 'a pack added is served by the same oomd, and no call meanwhile is refused' => sub {
    my ( $w, $n, $bad ) = change_and_call( "$A,$B", 2 );
    ok( $w->{ok} && $w->{changed}, 'the conf was rewritten' ) or diag explain $w;
    my $h = oomd_up($d);
    is( $h->{generation}, 2, 'oomd reloaded: generation 2' ) or diag slurp("$state/service.log");
    is( $h->{pid}, $pid, 'the same oomd: a reload, not a restart' );
    ok( has_ns( $h, $B ), "it serves $B now" );
    cmp_ok( $n, '>', 10, "calls were made all through the reload ($n)" );
    is( scalar @$bad, 0, 'and every one was answered by the daemon' ) or diag explain $bad;
    bind( $d, id => 'echo', operation => 'test.echo', modes => 'public' );
    my $r = run_b('echo');
    ok( $r->{ok}, "the operation of $B answers" ) or diag explain $r;
    is( Lazysite::Odoo::last_via(), 'daemon', 'through the daemon' );
    like( slurp("$state/service.log"), qr/oomd reloaded.*generation=2/, 'the service logs the reload' );
};

subtest 'a pack taken out is gone from oomd, though its environment names it' => sub {
    my ( undef, undef, $bad ) = change_and_call( $A, 3 );
    my $h = oomd_up($d);
    is( $h->{generation}, 3, 'generation 3' );
    is( $h->{pid}, $pid, 'still the same oomd' );
    ok( !has_ns( $h, $B ), "$B is gone" ) or diag explain $h->{namespaces};
    is( scalar @$bad, 0, 'no call was refused' ) or diag explain $bad;
};

subtest 'a reload oomd refuses leaves the workers it had serving, and says why' => sub {
    write_conf( $d, %SITE, odoo_packs => "$A,LazysiteTest::NoSuchPack" );
    Lazysite::Odoo::Daemon::write_conf($d);
    kill 'HUP', $svc;
    ok( wait_until( sub { slurp("$state/service.log") =~ /oomd did not reload/ }, 40 ), 'the service logs the refusal' )
        or diag slurp("$state/service.log");
    like( slurp("$state/service.log"), qr/did not reload.*NoSuchPack/, 'naming the namespace' );
    my $h = oomd_up($d);
    is( $h->{generation}, 3, 'the generation is unchanged' );
    is( $h->{pid}, $pid, 'the same oomd' );
    my $r = run_b('who');
    ok( $r->{ok}, 'and it answers' ) or diag explain $r;
    is( Lazysite::Odoo::last_via(), 'daemon', 'as the daemon' );
};

oomd_stop($svc);
ok( !oomd_up($d), 'stopped' );

# An OOM before 0.39 refuses a `namespaces` key and has no reload verb: the conf does
# not name them, oomd reads them from its environment at its start, and a change waits
# for its next start, which the service says.
subtest 'an OOM before 0.39 starts with its environment and is told the change waits' => sub {
    local $Lazysite::Daemon::Service::Oomd::INSTALLED_VERSION = sub { '0.38' };
    write_conf( $d, %SITE, odoo_packs => $A );
    Lazysite::Odoo::Daemon::write_conf($d);
    unlike( slurp( Lazysite::Odoo::Daemon::conf_path($d) ), qr/^namespaces/m, 'the conf does not name them' );
    unlink "$state/service.log";
    $svc = oomd_start( sub {
            open STDERR, '>>', "$state/service.log";
            Lazysite::Daemon::Service::Oomd::run( docroot => $d );
    } );
    ok( wait_until( sub { oomd_up($d) }, 30 ), 'up' );
    my $h = oomd_up($d);
    ok( has_ns( $h, $A ) && !has_ns( $h, $B ), 'its environment is odoo_packs' ) or diag explain $h->{namespaces};
    write_conf( $d, %SITE, odoo_packs => "$A,$B" );
    Lazysite::Odoo::Daemon::write_conf($d);
    kill 'HUP', $svc;
    ok( wait_until( sub { slurp("$state/service.log") =~ /takes them only when oomd starts/ }, 20 ), 'the service says the change waits' )
        or diag slurp("$state/service.log");
    is( oomd_up($d)->{pid}, $h->{pid}, 'and does not restart it' );
    oomd_stop($svc);
};

done_testing();
