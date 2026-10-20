#!/usr/bin/perl
# SM1226 (ruled 2026-10-20): THE WARM-FORK PARENT RUNS ONLY WHERE A FRONT END USES IT.
#
# The release manager: "the parent runs ONLY where a front end uses it - no parent
# (and no 54 MB) on a site whose front end never hands it a call (e.g. plain CGI);
# decide from what the site's front end is". Every front end that hands the Odoo
# endpoint to the parent does it through the site's pool: the one-rule pool's
# front door, and the split templates' location for the endpoint, which goes to the
# pool's socket. A pool is /etc/lazysite/pools/<instance>.conf naming the docroot,
# the conf lazysite@.service reads and `lazysite check` reports as "pool: yes"; a
# plain-CGI site has none. So that is the fact the service's gate reads
# (Lazysite::Paths::pool_conf_for), and no setting was added.
#
# Held through the real supervisor (Lazysite::Daemon::Supervisor::run), with the
# daemon and Odoo extensions enabled: with no pool conf for the docroot it starts
# no odoo-endpoint service and Status lists none; when a pool conf names the
# docroot it starts one, whose parent answers on the site's socket; when the conf
# goes, the parent is stopped. A conf naming another docroot does not count.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip);

BEGIN { oom_or_skip() }
use OdooDaemonTest               qw(oomd_site oomd_env oomd_start oomd_stop wait_until);
use Lazysite::Paths              ();
use Lazysite::WarmFork::Wire     ();
use Lazysite::Daemon::Supervisor ();
use Lazysite::Daemon::Service::OdooEndpoint ();

my $root = repo_root();
oomd_env();
my $d = oomd_site( odoo_daemon => 'off' );    # oomd is not this test's
( my $base = $d ) =~ s{/public_html\z}{};
my $pools = "$base/pools";
make_path($pools);
$ENV{LAZYSITE_POOLS_DIR} = $pools;            # the host's /etc/lazysite/pools, stood in

no warnings 'once';
$Lazysite::Daemon::Supervisor::SERVICE_GATE_EVERY = 1;
$Lazysite::Daemon::Supervisor::GATE_EVERY         = 1;
$Lazysite::Daemon::Service::OdooEndpoint::SCRIPT  = "$root/lazysite-odoo.pl";

my ($sock) = Lazysite::WarmFork::Wire::socket_for( Lazysite::Paths::lazysite_dir($d) );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub parent_up {
    return 0 unless -S $sock;
    socket( my $s, AF_UNIX, SOCK_STREAM, 0 ) or return 0;
    return connect( $s, sockaddr_un($sock) ) ? 1 : 0;
}
sub listed { return grep { $_->{unit} eq 'odoo-endpoint' } @{ Lazysite::Daemon::Supervisor::status($d)->{services} || [] } }

subtest 'the gate reads the pool conf for this docroot' => sub {
    ok( !defined Lazysite::Paths::pool_conf_for($d),          'no pool conf: plain CGI' );
    ok( !Lazysite::Daemon::Service::OdooEndpoint::wanted($d), '...so no parent is wanted' );
    spit( "$pools/other.conf", "DOCROOT=$base/elsewhere\nUSER=nobody\n" );
    ok( !Lazysite::Daemon::Service::OdooEndpoint::wanted($d), 'a pool conf for another docroot does not count' );
    spit( "$pools/site.conf", "DOCROOT=\"$d\"\nUSER=nobody\nFRONT_DOOR=1\n" );
    is( Lazysite::Paths::pool_conf_for($d), "$pools/site.conf", 'a pool conf naming this docroot is found' );
    ok( Lazysite::Daemon::Service::OdooEndpoint::wanted($d), '...and the parent is wanted' );
    unlink "$pools/site.conf";
};

my $sup = oomd_start( sub { Lazysite::Daemon::Supervisor::run( docroot => $d ) } );

subtest 'a plain-CGI site\'s supervisor starts no odoo-endpoint service' => sub {
    ok( wait_until( sub { defined Lazysite::Daemon::Supervisor::service_pid( $d, q{scheduler} ) }, 30 ),
        'the supervisor runs (its scheduler is up)' );
    sleep 4;    # several gate readings
    ok( !parent_up(), 'no parent answers on the site\'s socket' );
    ok( !-e $sock,    'and there is no socket' );
    is( scalar( listed() ), 0, 'Status lists no odoo-endpoint service' );
    ok( !defined Lazysite::Daemon::Supervisor::service_pid( $d, 'odoo-endpoint' ), 'and no pid stands for one' );
};

subtest 'a pooled site\'s supervisor starts one, and its parent answers' => sub {
    spit( "$pools/site.conf", "DOCROOT=$d\nUSER=nobody\n" );
    ok( wait_until( \&parent_up, 40 ), 'the parent answers on the site\'s socket' );
    ok( scalar( listed() ),            'Status lists the odoo-endpoint service' );
};

subtest 'when the pool conf goes, the parent is stopped' => sub {
    unlink "$pools/site.conf";
    ok( wait_until( sub { !parent_up() && !-e $sock }, 40 ), 'the parent and its socket are gone' );
};

is( oomd_stop($sup), 0, 'the supervisor stops cleanly' );
done_testing;
