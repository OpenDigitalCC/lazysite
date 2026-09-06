#!/usr/bin/perl
# SM760: the runtime and the request path share one write plane, so they must
# be one unix user - and where they are not, every reader says so by name
# instead of turning a permissions fault into a capability answer.
#
# The field's first real run (0.13.3, 133E-01): www-data rewrote
# groups-settings.json 0660; the runtime, as the panel user, could not open
# it; read_group_settings returned {} in silence; every job was refused as
# "does not hold run_jobs" while the Groups page and the pre-flight checks -
# run by www-data - said the account held it. And Status, as www-data, read
# `kill 0` EPERM on the panel user's process as "not started".
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Daemon::Supervisor;
use Lazysite::Daemon::Service::Scheduler;
use Lazysite::Auth::Settings;

plan skip_all => 'root reads everything; the permission cases need an unprivileged user' if $> == 0;

my $d = site_tempdir();
make_path("$d/lazysite/auth");
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }
put( "$d/lazysite/lazysite.conf", "site_name: t\nplugins:\n  - plugins/daemon.pl\n" );
put( "$d/lazysite/daemon.conf",   "daemon_job_user: jobs\n" );
put( "$d/lazysite/auth/users",    "jobs:x\n" );
put( "$d/lazysite/auth/groups",   "runners: jobs\n" );
put( "$d/lazysite/auth/groups-settings.json", '{"runners":{"run_jobs":1}}' );

subtest 'readable stores: the account holds run_jobs' => sub {
    my ( $u, $why ) = Lazysite::Daemon::Service::Scheduler::resolve_job_user( docroot => $d );
    is( $u, 'jobs', 'resolves' ) or diag $why;
};

subtest 'an unreadable groups-settings.json is refused BY NAME, not as "does not hold"' => sub {
    chmod 0000, "$d/lazysite/auth/groups-settings.json";
    my ( $u, $why ) = Lazysite::Daemon::Service::Scheduler::resolve_job_user( docroot => $d );
    is( $u, undef, 'refused' );
    like( $why, qr/cannot read lazysite\/auth\/groups-settings\.json/, 'names the file' );
    like( $why, qr/unix user '[^']+'/,                                 'names the unix user the runtime runs as' );
    like( $why, qr/Permission denied/,                                 'and the error' );
    like( $why, qr/USER= in \/etc\/lazysite\/daemon/,                  'and where the fix goes' );
    unlike( $why, qr/does not hold run_jobs/, 'a permissions fault is not a capability answer' );

    # the reader itself says so in the log, rather than returning {} in silence
    local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
    my @log;
    no warnings 'redefine';
    local *Lazysite::Auth::Settings::log_event = sub { push @log, [@_] };
    is_deeply( Lazysite::Auth::Settings::read_group_settings(), {}, 'reads as empty' );
    ok( ( grep { $_->[0] eq 'WARN' && $_->[2] =~ /cannot read groups-settings/ } @log ), 'and WARNs, naming the file' )
        or diag explain \@log;
    chmod 0644, "$d/lazysite/auth/groups-settings.json";
};

subtest 'a process that exists but is not ours is ALIVE' => sub {
    ok( !kill( 0, 1 ) && $!{EPERM}, 'pid 1 answers EPERM to an unprivileged kill 0' )
        or plan skip_all => 'no EPERM case on this host';
    is( Lazysite::Daemon::Supervisor::_alive(1), 1, '_alive: EPERM means the process exists' );
    is( Lazysite::Daemon::Supervisor::_alive( 2**22 - 1 ), 0, 'and a pid nobody holds is dead' );
};

subtest 'Status compares the runtime user in the host conf with its own' => sub {
    my $etc = tempdir( CLEANUP => 1 );
    local $Lazysite::Daemon::Supervisor::DAEMON_ETC = $etc;
    my ($me) = getpwuid($>);
    put( "$etc/site.example.conf", "DOCROOT=$d\nUSER=somebody-else\nENGINE=$d\n" );
    my %c = map { $_->{check} => $_ } @{ Lazysite::Daemon::Supervisor::status($d)->{checks} };
    ok( !$c{runtime_user}{ok}, 'a different user: not ok' );
    like( $c{runtime_user}{message}, qr/runs as 'somebody-else' but the request path runs as '\Q$me\E'/, 'both users named' );
    like( $c{runtime_user}{remedy},  qr/USER=\Q$me\E in \Q$etc\E\/site\.example\.conf/,                'the remedy is the line to write' );
    like( $c{runtime_user}{remedy},  qr/systemctl restart lazysited\@site\.example/,                     'and the restart' );

    put( "$etc/site.example.conf", "DOCROOT=$d\nUSER=$me\nENGINE=$d\n" );
    %c = map { $_->{check} => $_ } @{ Lazysite::Daemon::Supervisor::status($d)->{checks} };
    ok( $c{runtime_user}{ok}, 'the same user: ok' );
    like( $c{runtime_user}{message}, qr/same unix user as the request path/, 'said as the rule' );
};

subtest 'the deploy and the domain tool write USER= from the request path, not the panel user' => sub {
    my $root   = "$FindBin::Bin/../../..";
    my $deploy = do { local ( @ARGV, $/ ) = "$root/installers/hestia/lazysite-hestia-deploy.sh"; <> };
    like( $deploy, qr/RUNTIME_USER="\$\{LAZYSITE_CGI_USER:-www-data\}"/, 'deploy: the CGI user by default' );
    like( $deploy, qr/POOL_CONF="\/etc\/lazysite\/pools\/\$DOMAIN\.conf"/, 'deploy: a pooled site takes the pool user' );
    like( $deploy, qr/echo "USER=\$RUNTIME_USER"/,                          'deploy: and that is what the conf gets' );
    unlike( $deploy, qr/echo "USER=\$U"/, 'deploy: the panel user is no longer written' );
    my $tool = do { local ( @ARGV, $/ ) = "$root/tools/lazysite-hestia-domain.pl"; <> };
    like( $tool, qr/my \$runtime_user = \$o\{fcgi\} \? \$user : \$WEB_USER;/, 'tool: pool user with --fcgi, web user otherwise' );
};

done_testing;
