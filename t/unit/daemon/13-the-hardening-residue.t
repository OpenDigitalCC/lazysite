#!/usr/bin/perl
# SM792: the daemon hardening residue from the 0.13.8 security review.
#
# None of these is a live escalation - each sits on the same-uid or systemd
# boundary - and each was a place where the daemon trusted something it did not
# need to:
#
#   1. The stats job ran whatever LAZYSITE_STATS_TOOL named, first and
#      unconditionally. The seam existed for tests; production now looks only
#      where a deploy puts the plugin, and so do the tests.
#   2. ADOPT BY STOPPING trusted the pid and state files, which the site user can
#      write: a pid and a kernel start time copied from /proc made the supervisor
#      TERM and then KILL that process. An orphan it may stop is now also a copy
#      of this supervisor - its own uid, its own command line.
#   3. After KILL, a blocking waitpid: a child in uninterruptible sleep held the
#      supervisor's own shutdown. The wait is bounded and the stall is logged.
#   4. The gid drop was assigned and never checked, while the uid drop is checked
#      twice. A failed $) assignment is silent - as a non-root process shows,
#      asking for a group it is not in.
#
# Each was reproduced against the code before the fix.
use strict;
use warnings;
use Test::More;
use File::Basename ();
use FindBin;
use POSIX    ();
use JSON::PP ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                   qw(grant_caps add_account repo_root site_tempdir);
use Lazysite::Daemon::Supervisor ();
use Lazysite::Daemon::Service::Scheduler ();

my $ROOT = repo_root();

sub site {
    my $d = site_tempdir();    # <tmp>/site/public_html, so plugins/ can sit beside it
    my $t = File::Basename::dirname( File::Basename::dirname($d) );
    mkdir "$d/$_" for qw(lazysite lazysite/auth lazysite/daemon lazysite/logs lazysite/cache);
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: t\nplugins:\n  - plugins/daemon.pl\n";
    close $c;
    return ( $t, $d );
}

sub spit { my ( $p, $s ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $s; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $s = <$fh>; close $fh; return $s }

subtest 'the stats job runs the deploy\'s plugin, not whatever the environment names' => sub {
    my ( $t, $d ) = site();
    add_account( $d, 'jobs-stats' );
    grant_caps( $d, 'jobs-stats', qw(run_jobs analytics) );
    spit( "$d/lazysite/daemon.conf", "daemon_tick_seconds: 60\ndaemon_job_user: jobs-stats\n" );

    my $marker    = "$t/named-by-the-environment";
    my $elsewhere = "$t/anything.pl";
    spit( $elsewhere, "open my \$o, '>', '$marker' or die; close \$o; print '{\"ok\":true,\"days\":[]}';\n" );

    local $ENV{LAZYSITE_STATS_TOOL} = $elsewhere;
    local $0 = "$t/nowhere/lazysited.pl";    # no sibling plugins/ either
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $d );
    ok( !-e $marker, 'a script named by LAZYSITE_STATS_TOOL is not run' );

    # The real lookup still works: the Hestia layout, plugins/ beside the docroot.
    mkdir "$t/site/plugins";
    my $found = "$t/found-the-deploy-plugin";
    spit( "$t/site/plugins/stats.pl",
        "open my \$o, '>', '$found' or die; close \$o; print '{\"ok\":true,\"days\":[]}';\n" );
    unlink "$d/lazysite/daemon/scheduler-runs.json";
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $d );
    ok( -e $found, 'the plugin where a deploy puts it is the one that runs' );
};

subtest 'a forged service record cannot make the supervisor kill another process' => sub {
    my ( $t, $d ) = site();

    # A same-uid process that is not a lazysite service, whose pid and kernel
    # start time are copied into the records - which is all the files let a
    # writer do.
    my $victim = fork();
    die "fork: $!" unless defined $victim;
    if ( $victim == 0 ) { exec 'sleep', '60' or POSIX::_exit(127) }
    select( undef, undef, undef, 0.3 );
    my $ticks = Lazysite::Daemon::Supervisor::_start_ticks($victim);
    ok( defined $ticks, 'the canary: its start time is readable from /proc' ) or return;
    spit( "$d/lazysite/daemon/lives.pid", "$victim\n" );
    spit( "$d/lazysite/daemon/lives.state.json", JSON::PP::encode_json( { fails => 0, start_ticks => $ticks } ) );

    my $log = "$t/supervisor.log";
    my $sup = fork();
    die "fork: $!" unless defined $sup;
    if ( $sup == 0 ) {
        no warnings 'redefine';
        *Lazysite::Daemon::Supervisor::services = sub {
            return ( { name => 'lives', start => sub { my $go = 1; local $SIG{TERM} = sub { $go = 0 }; sleep 1 while $go; 0 } } );
        };
        open STDERR, '>', $log or die $!;
        exit Lazysite::Daemon::Supervisor::run( docroot => $d );
    }
    sleep 2;

    # Reaped, not `kill 0`: the victim is this test's child, and a killed child
    # is a zombie that `kill 0` still finds.
    is( waitpid( $victim, POSIX::WNOHANG() ), 0, 'the other process is still running' );
    like( slurp($log), qr/not a service of this supervisor/, 'and the log says why it was left alone' );

    kill 'TERM', $sup;
    waitpid $sup, 0;
    kill 'KILL', $victim;
    waitpid $victim, 0;
};

subtest 'a child that does not die on KILL does not hold the supervisor\'s shutdown' => sub {
    my ( $t, $d ) = site();

    # A child in uninterruptible sleep ignores KILL until it wakes, and that
    # cannot be arranged without root. So a separate perl withholds KILL: its
    # kill is overridden before the supervisor is compiled, TERM and 0 go
    # through, KILL does not. The child ignores TERM and sleeps, so it is still
    # there when the stop reaches the wait that follows the KILL.
    my $log    = "$t/stop.log";
    my $script = "$t/stop.pl";
    spit( $script, <<"PL" );
use strict; use warnings;
BEGIN {
    *CORE::GLOBAL::kill = sub {
        my ( \$sig, \@pids ) = \@_;
        return scalar \@pids if \$sig eq 'KILL' || \$sig eq '9';
        return CORE::kill( \$sig, \@pids );
    };
}
use lib '$ROOT/lib';
use Lazysite::Daemon::Supervisor ();
\$SIG{TERM} = 'IGNORE';    # before the fork, so the child never has a moment without it
my \$child = fork();
die "fork: \$!" unless defined \$child;
if ( \$child == 0 ) { sleep 30; POSIX::_exit(0) }
\$Lazysite::Daemon::Supervisor::STOP_DEADLINE = 1;
open STDERR, '>', '$log' or die \$!;
Lazysite::Daemon::Supervisor::_stop_children( { stuck => \$child }, '$d' );
CORE::kill( 'KILL', \$child );
exit 0;
PL
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) { exec $^X, $script or POSIX::_exit(127) }
    my $done = 0;
    for ( 1 .. 50 ) {
        if ( waitpid( $pid, POSIX::WNOHANG() ) > 0 ) { $done = 1; last }
        select( undef, undef, undef, 0.2 );
    }
    ok( $done, 'the stop returns within 10 s' ) or do { kill 'KILL', $pid; waitpid $pid, 0 };
    like( slurp($log), qr/still there after KILL/, 'and says which service did not go' );
};

subtest 'the gid drop is checked, as the uid drop is' => sub {
    my $src = slurp("$ROOT/tools/lazysited.pl");
    my ($block) = $src =~ m{\nsub _drop_privileges \{\n(.*?)\n\}\n}s;
    ok( $block, 'the drop is one sub in lazysited.pl, so it can be driven' ) or return;
    unlike( $block, qr/Lazysite::/, 'and loads no module - it runs as root, before anything site-writable' );

SKIP: {
        skip 'as root every group assignment succeeds', 2 if $> == 0;
        my %mine      = map  { $_ => 1 } split ' ', $);
        my ($foreign) = grep { !$mine{$_} } 1 .. 65000;
        ## no critic (BuiltinFunctions::ProhibitStringyEval)
        my $drop = eval "sub { $block\n }" or die $@;
        my $err  = $drop->( $<, $foreign );
        ok( defined $err && length $err, 'asking for a group this process cannot take is refused' );
        like( $err // '', qr/gid/, 'and the refusal names the gid' );
    }
};

done_testing();
