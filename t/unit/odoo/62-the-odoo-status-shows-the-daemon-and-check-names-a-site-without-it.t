#!/usr/bin/perl
# SM1164 D4: THE OPERATOR'S ODOO STATUS SHOWS THE DAEMON; `lazysite check` NAMES A
# SITE WITH odoo_daemon ON WHOSE DAEMON IS NOT RUNNING.
#
# The filing's D4: "name, health, OOM version, packs, workers, uptime; and `failed`
# with the supervisor's reason when it flaps. `lazysite check` names a site with
# `odoo_daemon: on` whose daemon is not running." The addendum's item 6: "The
# operator's status page: the daemon's health (name, version, packs, workers,
# uptime)." (The `failed` reason is held in t/unit/daemon/14, where the supervisor
# runs.) The real oomd answers here; nothing is stubbed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip write_conf);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::Odoo::Daemon ();
use Lazysite::Daemon::Service::Oomd ();

my $root = repo_root();
oomd_env();
my $d = oomd_site();
$Lazysite::Odoo::DOCROOT = $d;
my $name = Lazysite::Odoo::Daemon::name($d);

sub check_lines {
    my $out = `$^X $root/tools/lazysite-check.pl --docroot $d 2>&1`;
    return grep { /oomd/i } split /\n/, $out;
}
sub conf_write { write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps', odoo_daemon => 'on', odoo_daemon_workers => 2, @_ ) }

subtest 'not running: the status says so, and check names the site' => sub {
    my $s = Lazysite::Odoo::action_odoo_status()->{daemon};
    is( $s->{mode}, 'on', 'the mode' );
    is( $s->{name}, $name, 'the name' );
    is( $s->{running}, 0, 'not running' );
    is( $s->{installed}, 1, 'installed' );
    is( $s->{socket_in}, 'site', 'its socket is under the site' );
    my @l = check_lines();
    is( scalar @l, 2, 'check says it in a line and a hint' ) or diag explain \@l;
    like( $l[0] // '', qr/odoo_daemon: on and oomd \(\Q$name\E\) is not running/, 'and names the site\'s daemon' );
    like( $l[0] // '', qr/WARN|!|warn/i, 'as a warning' );
    like( join( "\n", check_lines() ), qr/under the site/, 'with where its socket should be' );
};

my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'oomd is up' ) or BAIL_OUT('no oomd');

subtest 'running: name, health, version, packs, workers and uptime' => sub {
    my $s = Lazysite::Odoo::action_odoo_status()->{daemon};
    is( $s->{running}, 1, 'running' );
    my $h = $s->{health};
    ok( $h, 'with its health' ) or diag explain $s;
    require Odoo::Ops::Version;
    is( $h->{version}, $Odoo::Ops::Version::VERSION, 'the OOM version' );
    is( $h->{workers}, 2, 'the workers' );
    ok( defined $h->{uptime} && $h->{uptime} >= 0, 'the uptime' );
    ok( exists $h->{packs}, 'the packs' );
    is( $h->{name}, $name, 'the name oomd reports' );
    my @l = check_lines();
    like( $l[0] // '', qr/oomd is running \(\Q$name\E, OOM \Q$h->{version}\E, 2 workers\)/, 'and check says it is fine' ) or diag explain \@l;
};

oomd_stop($svc);

subtest 'required and not running is a failure; off says nothing' => sub {
    conf_write( odoo_daemon => 'required' );
    my @l = check_lines();
    like( join( "\n", @l ), qr/odoo_daemon: required and oomd/, 'names it' );
    like( join( "\n", @l ), qr/FAIL|✗|fail/i, 'as a failure: every call is refused until it runs' );
    conf_write( odoo_daemon => 'off' );
    is_deeply( [ check_lines() ], [], 'with odoo_daemon off check says nothing of it' );
};

done_testing();
