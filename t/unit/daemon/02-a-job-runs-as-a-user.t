#!/usr/bin/perl
# SM666 phase 1: a scheduled job runs as a USER, never as system, and fails
# closed in every direction.
#
# This is the second security property of the runtime, after "disabled means no
# process". A timer that can call anything is a second write plane wearing a
# clock: `system:*` is how the CLI acts and the CLI is unconstrained, so a job
# running that way would bypass the capability model entirely - which is what
# the model exists to prevent.
#
# TWO GATES, and both are asserted here. The identity must hold `run_jobs`,
# which is what makes an account one that may CARRY a job at all. And the job's
# own action faces the ordinary capability gate, unchanged: no scheduled-work
# exemption and no widening, because the whole point is that a job is not a
# special kind of caller.
#
# The refusals are as important as the successes and are tested with the same
# weight. A job that silently does not run is indistinguishable from a job with
# nothing to do, and an operator reading "nothing happened" cannot tell which
# of the three ways it failed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                           qw(grant_caps);
use Lazysite::Daemon::Service::Scheduler ();

my $root = tempdir( CLEANUP => 1 );
mkdir "$root/lazysite";
mkdir "$root/lazysite/auth";
mkdir "$root/lazysite/daemon";

sub set_job_user {
    my ($user) = @_;
    open my $fh, '>', "$root/lazysite/daemon.conf" or die $!;
    print {$fh} "daemon_tick_seconds: 60\n";
    print {$fh} "daemon_job_user: " . ( defined $user ? $user : '' ) . "\n";
    close $fh;
    return;
}

sub reason_for {
    my ( undef, $why ) = Lazysite::Daemon::Service::Scheduler::resolve_job_user(
        docroot => $root );
    return $why;
}

subtest 'no configured account: nothing runs, and it says so' => sub {
    set_job_user('');
    my ( $user, $why )
        = Lazysite::Daemon::Service::Scheduler::resolve_job_user(
        docroot => $root );
    ok( !defined $user, 'no identity is resolved' );
    like( $why, qr/no daemon_job_user/, 'the reason names the missing setting' );
};

subtest 'a system identity is refused by name' => sub {
    # Refused explicitly rather than left to the capability lookup, because
    # `system:root` is not in the user store at all - so the capability check
    # would report "account does not exist", which is true and is the wrong
    # reason. An operator who wrote system:root deliberately needs to be told
    # that system identities are not allowed, not that they made a typo.
    set_job_user('system:root');
    my ( $user, $why )
        = Lazysite::Daemon::Service::Scheduler::resolve_job_user(
        docroot => $root );
    ok( !defined $user, 'a system identity never resolves' );
    like( $why, qr/system identities are unconstrained/,
        'and the refusal explains WHY, not just that it was refused' );
};

subtest 'an account without run_jobs may not carry a job' => sub {
    grant_caps( $root, 'nobody', qw(ui manage_content) );
    set_job_user('nobody');
    my ( $user, $why )
        = Lazysite::Daemon::Service::Scheduler::resolve_job_user(
        docroot => $root );
    ok( !defined $user, 'a capable account is still not a job account' );
    like( $why, qr/does not hold run_jobs/,
        'the refusal names the capability that is missing' );
};

subtest 'an account holding run_jobs resolves' => sub {
    grant_caps( $root, 'jobs-nightly', qw(run_jobs) );
    set_job_user('jobs-nightly');
    my ( $user, $why )
        = Lazysite::Daemon::Service::Scheduler::resolve_job_user(
        docroot => $root );
    is( $user, 'jobs-nightly', 'the purpose account resolves' );
    ok( !defined $why, 'with no refusal' );
};

subtest 'a tick with no usable identity RECORDS the refusal' => sub {
    # The failure that must not be silent. A job that does not run and says
    # nothing looks exactly like a job with nothing to do.
    set_job_user('');
    my $done = Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    ok( ref $done eq 'ARRAY' && @$done, 'the tick reports what it did' );
    is( $done->[0]{outcome}, 'refused', 'the job is refused, not skipped' );
    like( $done->[0]{reason}, qr/daemon_job_user/,
        'and the record carries the reason' );
};

subtest 'a tick with a proper identity runs the job and names the actor' => sub {
    set_job_user('jobs-nightly');
    my $done = Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    is( $done->[0]{outcome}, 'ok', 'the job runs' );

    # THE AUDIT POINT. Not 'scheduler', not 'system' - the real account, so a
    # row written at 03:00 answers the same question as one written by a person
    # at noon: who was this, and what were they allowed to do.
    is( $done->[0]{actor}, 'jobs-nightly',
        'and the record names the REAL user, not the scheduler' );
};

subtest 'a refusal is not a run, so fixing the config takes effect at once' => sub {
    # Found by the two subtests above, in the first version of the scheduler:
    # a refusal recorded last_run, so a job refused for want of an account had
    # CONSUMED its schedule slot. An operator who then configured the account
    # correctly waited a full interval for anything to happen, with nothing
    # saying why.
    #
    # The refusal is a statement about the configuration, not about the work,
    # and the work has not been done. So the next tick after a fix must run the
    # job immediately - which is what these two ticks, back to back with no
    # time passing, assert.
    my $fresh = tempdir( CLEANUP => 1 );
    mkdir "$fresh/lazysite";
    mkdir "$fresh/lazysite/auth";
    mkdir "$fresh/lazysite/daemon";

    open my $c, '>', "$fresh/lazysite/daemon.conf" or die $!;
    print {$c} "daemon_job_user:\n";
    close $c;

    my $r1 = Lazysite::Daemon::Service::Scheduler::tick( docroot => $fresh );
    is( $r1->[0]{outcome}, 'refused', 'first tick: refused, no account' );

    grant_caps( $fresh, 'jobs-fixed', qw(run_jobs) );
    open my $c2, '>', "$fresh/lazysite/daemon.conf" or die $!;
    print {$c2} "daemon_job_user: jobs-fixed\n";
    close $c2;

    my $r2 = Lazysite::Daemon::Service::Scheduler::tick( docroot => $fresh );
    is( $r2->[0]{outcome}, 'ok',
        'second tick, no time passed: the job runs - the refusal did not '
            . 'consume the slot' );
    is( $r2->[0]{actor}, 'jobs-fixed', 'as the newly configured account' );
};

subtest 'the job set is closed - configuration cannot add one' => sub {
    # A job is engine code. If a schedule were a configuration surface, "write
    # a schedule" would become "execute code on a timer", reachable by anyone
    # who can write configuration.
    my $jobs  = Lazysite::Daemon::Service::Scheduler::jobs();
    my @names = sort keys %$jobs;

    # Writing a job into the daemon's own config must not create one.
    open my $fh, '>>', "$root/lazysite/daemon.conf" or die $!;
    print {$fh} "job_evil: /bin/true\n";
    close $fh;

    is_deeply( [ sort keys %{ Lazysite::Daemon::Service::Scheduler::jobs() } ],
        \@names, 'the job set is unchanged by anything written to config' );
};

done_testing();
