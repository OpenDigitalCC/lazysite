#!/usr/bin/perl
# SM666 phase 1: disabled means the process never starts.
#
# THIS IS THE SECURITY PROPERTY OF THE WHOLE RUNTIME, so it is the first test.
#
# ADR 0009 says a disabled plugin executes nothing. For a CGI plugin that is
# enforced at dispatch: a request arrives and is refused. A DAEMON HAS NO
# DISPATCH TO REFUSE AT - nothing arrives, and the process either exists or it
# does not. So conforming means the supervisor reads the enabled state and
# declines to start at all.
#
# The difference matters because the failure modes are not comparable. An
# unintended CGI refusal is waste. An unintended long-lived process holding an
# instance's credentials is a different order of problem, and it is the one
# SM222 documents as today's behaviour for services: disabled, but still
# spawned, still reading config, refusing only at the end.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Daemon::Supervisor ();

my $root = tempdir( CLEANUP => 1 );
mkdir "$root/lazysite";

sub set_plugins {
    my (@names) = @_;
    open my $fh, '>', "$root/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: t\n";
    if (@names) {
        print {$fh} "plugins:\n";
        print {$fh} "  - $_\n" for @names;
    }
    close $fh;
    return;
}

subtest 'born disabled: no plugins list at all' => sub {
    set_plugins();
    is( Lazysite::Daemon::Supervisor::should_run($root), 0,
        'a site that has never enabled it does not run the daemon' );
};

subtest 'another plugin enabled is not this plugin enabled' => sub {
    # The gate must key on THIS plugin, not on "the plugins list exists".
    set_plugins('data.pl');
    is( Lazysite::Daemon::Supervisor::should_run($root), 0,
        'enabling a different plugin does not start the daemon' );
};

subtest 'enabled when, and only when, it is listed' => sub {
    set_plugins( 'data.pl', 'daemon.pl' );
    is( Lazysite::Daemon::Supervisor::should_run($root), 1,
        'listed alongside others - runs' );

    set_plugins('daemon.pl');
    is( Lazysite::Daemon::Supervisor::should_run($root), 1,
        'listed alone - runs' );
};

subtest 'run() on a disabled site starts nothing and touches nothing' => sub {
    set_plugins();

    my $rc = Lazysite::Daemon::Supervisor::run( docroot => $root );
    is( $rc, 0,
        'exits 0 - disabled is not an error, it is the operator\'s choice' );

    # THE ASSERTION THAT MATTERS. Not merely "did no work" but "left no trace":
    # a disabled runtime must not create its state directory, because doing so
    # is the first half of running.
    ok( !-d "$root/lazysite/daemon",
        'no state directory is created - it did not begin to start' );
};

subtest 'status reports desired and verdict separately' => sub {
    # SM222's split, and now SM222's contract - the debt this file's own
    # comments recorded is paid. `up`/`down` became `on`/`off` and the runtime
    # word became a VERDICT, because one vocabulary across every managed unit
    # is the point of having a contract at all.
    set_plugins();
    my $off = Lazysite::Daemon::Supervisor::status($root);
    is( $off->{desired}, 'off', 'disabled reads as desired: off' );
    is( $off->{verdict}, 'off', 'and the verdict agrees - nothing is wrong' );
    is( $off->{healthy}, 1,
        'off-because-you-turned-it-off is HEALTHY, not a problem to report' );
    like( $off->{message}, qr/disabled/, 'and says why, in words' );

    set_plugins('daemon.pl');
    my $on = Lazysite::Daemon::Supervisor::status($root);
    is( $on->{desired}, 'on', 'enabled reads as desired: on' );

    # THE DISAGREEMENT IS THE REPORTED FACT. Enabled and not running was
    # `not-started` - a word that describes the process. `inconsistent`
    # describes the RELATIONSHIP between what the config says and what is true,
    # which is what an operator is actually asking about when they wonder why
    # nothing is happening.
    is( $on->{verdict}, 'inconsistent',
        'enabled with no process is INCONSISTENT, not merely stopped' );
    is( $on->{healthy}, 0, 'and it is not healthy' );

    # SM750's class: a state without an action is half an answer. The field
    # met this exact state and had to ask what to do next.
    like( $on->{remedy}, qr/systemctl enable --now lazysited/,
        'the remedy names the command that resolves it' );

    is( $on->{services}[0]{verdict}, 'inconsistent',
        'and the service says the same' );
};

done_testing();
