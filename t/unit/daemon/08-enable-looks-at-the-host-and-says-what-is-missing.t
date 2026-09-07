#!/usr/bin/perl
# SM757: pressing Enable on the daemon plugin runs its Status action, and Status
# now LOOKS AT THE HOST - is there a runtime conf naming this docroot, is its
# timer enabled - and at the job account, and says in one sentence what a sysop
# must still arrange. The manager has no root; what it can do is tell.
#
# The release manager's ruling: "when plugin enable pressed, this should be
# checked and operator advised if there are any problems".
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                   qw(site_tempdir grant_caps add_account repo_root);
use Lazysite::Daemon::Supervisor ();

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/daemon" );
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }
put( "$d/lazysite/lazysite.conf", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" );

# a private /etc/lazysite/daemon for the test
my $etc = tempdir( CLEANUP => 1 );
local $Lazysite::Daemon::Supervisor::DAEMON_ETC = $etc;

sub summary_of { return Lazysite::Daemon::Supervisor::status($d)->{summary} }
sub checks_of { my %c = map { $_->{check} => $_ } @{ Lazysite::Daemon::Supervisor::status($d)->{checks} }; return \%c }

subtest 'enabled, nothing provisioned, no job account: three things named' => sub {
    put( "$d/lazysite/daemon.conf", "daemon_job_user:\n" );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    is( $st->{desired}, 'on',           'desired on' );
    is( $st->{verdict}, 'inconsistent', 'not running' );
    like( $st->{remedy}, qr/no runtime provisioned/, 'the remedy says the host has not provisioned it' );
    like( $st->{remedy}, qr/lazysite-hestia-deploy\.sh|--daemon/, 'and names how it gets provisioned' );
    my $c = checks_of();
    ok( !$c->{host_conf}{ok},   'check: no host conf' );
    ok( !$c->{job_account}{ok}, 'check: no job account' );
    like( $c->{job_account}{remedy}, qr/daemon_job_user/, 'with the setting to fill in' );
    like( summary_of(), qr/no runtime provisioned/, 'the one-line summary carries the host problem' );
    unlike( summary_of(), qr/systemctl enable --now lazysited\@<domain>/, 'and no longer a command for a unit that does not exist' );
};

subtest 'the host conf exists and the timer is enabled: the remedy is "wait five minutes"' => sub {
    put( "$etc/site.example.conf", "DOCROOT=$d\nUSER=nobody\nENGINE=/x\n" );
    no warnings 'redefine';
    # systemctl is not ours to run here; pretend the timer is enabled
    local *Lazysite::Daemon::Supervisor::host_provisioning = sub {
        return { conf => "$etc/site.example.conf", instance => 'site.example', timer => 'enabled', service => 'inactive' };
    };
    my $st = Lazysite::Daemon::Supervisor::status($d);
    like( $st->{remedy}, qr/starts it within five minutes/, 'the timer will start it' );
    # SM766: waiting for an armed timer is 'starting', not 'inconsistent' - the
    # field read the strong word on every enable for a normal self-clearing wait.
    is( $st->{verdict}, 'starting', 'and the verdict is starting, not inconsistent' );
    like( $st->{message}, qr/waiting for the host timer/, 'the line says it is waiting for the timer' );
    is( $st->{services}[0]{verdict}, 'starting', 'the service too' );
    my $c = checks_of();
    ok( $c->{host_conf}{ok},  'check: conf found' );
    ok( $c->{host_timer}{ok}, 'check: timer enabled' );
    like( $c->{host_timer}{message}, qr/lazysited\@site\.example\.timer/, 'naming the instance' );
};

subtest 'the host conf exists but the timer is not enabled: the command is the remedy' => sub {
    no warnings 'redefine';
    local *Lazysite::Daemon::Supervisor::host_provisioning = sub {
        return { conf => "$etc/site.example.conf", instance => 'site.example', timer => 'disabled', service => 'inactive' };
    };
    my $st = Lazysite::Daemon::Supervisor::status($d);
    like( $st->{remedy}, qr/systemctl enable --now lazysited\@site\.example\.timer/, 'the exact command, for the exact instance' );
};

subtest 'host_provisioning finds the conf by DOCROOT, not by name' => sub {
    put( "$etc/other.conf", "DOCROOT=/nowhere/else\nUSER=nobody\n" );
    my $h = Lazysite::Daemon::Supervisor::host_provisioning($d);
    is( $h->{instance}, 'site.example', 'the conf whose DOCROOT is this docroot' );
    is( $h->{conf},     "$etc/site.example.conf", 'by path' );
    my $none = Lazysite::Daemon::Supervisor::host_provisioning("$d/nope");
    ok( !defined $none->{conf}, 'and nothing for a docroot no conf names' );
};

subtest 'the job account checks say which job will be refused, before it is' => sub {
    add_account( $d, 'jobs' );
    grant_caps( $d, 'jobs', qw(run_jobs analytics manage_connectors) );    # not manage_users
    put( "$d/lazysite/daemon.conf", "daemon_job_user: jobs\n" );
    my $c = checks_of();
    ok( $c->{job_account}{ok},           'the account resolves' );
    ok( $c->{'job:stats-rollup'}{ok},    'stats-rollup may run' );
    ok( !$c->{'job:sessions-sweep'}{ok}, 'sessions-sweep will be refused' );
    like( $c->{'job:sessions-sweep'}{remedy}, qr/grant manage_users/, 'and the remedy is the grant' );
    like( summary_of(), qr/Also: sessions-sweep will be refused/, 'the summary carries the first failing check' );
};

subtest 'the plugin runs Status on Enable and the toggle line gets the summary' => sub {
    my $src = do { local ( @ARGV, $/ ) = "$root/plugins/daemon.pl"; <> };
    like( $src, qr/on_enable\s*=>\s*'status'/, 'on_enable names the status action' );
    like( $src, qr/\$st->\{message\} = \$st->\{summary\}/, 'and the action puts the summary where the toggle line reads' );
    my $plugins = do { local ( @ARGV, $/ ) = "$root/starter/manager/plugins.md"; <> };
    like( $plugins, qr/if \(h && h\.message\) \{ warn\(name \+ ': ' \+ h\.message\); \}/, 'which is h.message on the Plugin Manager page' );
};

# SM759: the field's list of the states the line must distinguish, and the
# rule they all share - a state that is not "running" names a next step.
# Every subtest above is one of those states; this one adds the two the
# field reached and could not act on: disabled (which reads no remedy at
# all), and the run record, which no remote grant can read.
subtest 'disabled: the line says so and says what to do' => sub {
    put( "$d/lazysite/lazysite.conf", "site_name: t\n" );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    is( $st->{desired}, 'off', 'desired off' );
    like( $st->{message}, qr/plugin is disabled/, 'the state' );
    # 'off' is a healthy verdict by the lifecycle contract (desired off, not
    # running), so it carries no remedy field; the next step is in the line.
    like( summary_of(), qr/disabled and the runtime is stopped.*enable it on the Plugin Manager/, 'the state and the next step, in the one line' );
    put( "$d/lazysite/lazysite.conf", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" );
};

subtest 'every state that is not running carries a remedy' => sub {
    for my $conf ( "site_name: t\n", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" ) {
        put( "$d/lazysite/lazysite.conf", $conf );
        my $st = Lazysite::Daemon::Supervisor::status($d);
        next if $st->{verdict} eq 'on';
        ok( length( $st->{remedy} // '' ) || $st->{summary} =~ / - /, "verdict '$st->{verdict}': a next step is named" )
            or diag explain $st;
        for my $c ( grep { !$_->{ok} } @{ $st->{checks} } ) {
            ok( length( $c->{remedy} // '' ), "failing check '$c->{check}': a remedy is named" );
        }
    }
};

# SM760: the field's "one more row" - running. Status holds a live pid and
# the run records it wrote, and used to say "has not been started" because
# `kill 0` from another unix user answers EPERM. A running runtime is
# reported running, healthy, with no remedy and the runs beside it.
subtest 'running: said so, healthy, no remedy' => sub {
    put( "$d/lazysite/lazysite.conf", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" );
    Lazysite::Daemon::Supervisor::_write_pid( $d, 'scheduler', $$ );
    Lazysite::Daemon::Supervisor::_write_state( $d, 'scheduler',
        { fails => 0, started => time, start_ticks => Lazysite::Daemon::Supervisor::_start_ticks($$) } );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    is( $st->{verdict}, 'on', 'verdict on' );
    is( $st->{healthy}, 1,    'healthy' );
    ok( !defined $st->{remedy}, 'no remedy - nothing to do' ) or diag $st->{remedy};
    like( $st->{summary}, qr/running/, 'the line says running' );
    my %c = map { $_->{check} => $_ } @{ $st->{checks} };
    ok( $c{runtime}{ok}, 'the runtime check is ok' );

    # and Disable says whether it stopped: still our own pid here, so "still stopping"
    put( "$d/lazysite/lazysite.conf", "site_name: t\n" );
    my $off = Lazysite::Daemon::Supervisor::status( $d, settle => 1 );
    like( $off->{summary}, qr/disabled and the runtime is still stopping \(pid $$\)/, 'disabled with a live process: still stopping, with the pid' );
    unlink Lazysite::Daemon::Supervisor::_pid_file( $d, 'scheduler' ), Lazysite::Daemon::Supervisor::_state_file( $d, 'scheduler' );
    $off = Lazysite::Daemon::Supervisor::status($d);
    like( $off->{summary}, qr/disabled and the runtime is stopped/, 'disabled with no process: stopped' );
    put( "$d/lazysite/lazysite.conf", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" );
};

subtest 'Status carries the run record, which no remote grant can read' => sub {
    put( "$d/lazysite/daemon/scheduler-runs.json",
        '{"stats-rollup":{"last_run":1700000000,"outcome":"ok","actor":"jobs"},"sessions-sweep":{"outcome":"refused","refusal_reason":"jobs does not hold manage_users"}}' );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    is( $st->{runs}{'stats-rollup'}{outcome},          'ok',      'per job: the outcome' );
    is( $st->{runs}{'stats-rollup'}{actor},            'jobs',    'and the actor' );
    is( $st->{runs}{'sessions-sweep'}{refusal_reason}, 'jobs does not hold manage_users', 'and a refusal says why' );
    unlink "$d/lazysite/daemon/scheduler-runs.json";
    is_deeply( Lazysite::Daemon::Supervisor::status($d)->{runs}, {}, 'no record yet: an empty map, not an absence' );
};

done_testing();
