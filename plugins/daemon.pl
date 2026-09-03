#!/usr/bin/perl
# SM666 phase 1: the persistent runtime, declared as a plugin.
#
# THIS FILE IS THE DECLARATION, NOT THE DAEMON. The runtime itself is
# tools/lazysited.pl, supervised by systemd. What lives here is the ADR 0009
# contract: what the runtime owns, what it may be configured with, and - the
# load-bearing part - the `contract` key that makes it BORN DISABLED.
#
# WHY A PLUGIN AT ALL. The release manager's ruling: the runtime ships disabled
# and an operator turns it on deliberately, so an instance that upgrades gets
# nothing new running. ADR 0009 already provides exactly that shape, and SM409
# already made it real for contract plugins, so declaring the runtime here buys
# born-disabled, a real enabled state, backup participation and SBOM
# declaration without inventing any of them.
#
# WHAT "DISABLED" HAS TO MEAN HERE, and it is stronger than the ADR's own case.
# For a CGI plugin, off is enforced at dispatch: a request arrives and is
# refused. A DAEMON HAS NO DISPATCH TO REFUSE AT - nothing arrives; the process
# either exists or it does not. So conforming means the supervisor reads this
# plugin's enabled state and DECLINES TO START, rather than starting and
# refusing work. Lazysite::Daemon::Supervisor::should_run is that check, and
# t/unit/daemon/01 is what stops it rotting.
#
# TERMINOLOGY, settled 2026-09-03 and worth stating where both words appear in
# one file: LAZYSITE HAS PLUGINS; THE DAEMON HAS SERVICES. This file is a
# plugin. The scheduler it supervises is a service. Disabling this plugin stops
# the runtime and every service in it; disabling a service stops that one.
use strict;
use warnings;
use JSON::PP ();

sub describe {
    return {
        id          => 'daemon',
        name        => 'Persistent runtime',
        description => 'A supervised process that holds long-lived work the '
            . 'request path cannot: a scheduler that calls timed functions '
            . 'inside the stack, and later the transports that need something '
            . 'permanently connected. It owns no protocol of its own - each '
            . 'capability is a SERVICE running as its own child, so one '
            . 'service failing does not stop the others. Ships disabled: an '
            . 'operator turns it on deliberately, and until then no process '
            . 'runs at all.',
        version     => '0.1',
        config_file => 'lazysite/daemon.conf',

        # SM409 / ADR 0009. Born disabled, and really gated rather than
        # displayed. For this plugin the gate is not "refuse an action" but
        # "do not start a process", which the supervisor enforces.
        contract => 1,

        config_schema => [
            { key => 'daemon_tick_seconds',
                label   => 'How often the scheduler looks for due work',
                type    => 'text',
                default => '60',
                note    => 'The scheduler wakes on this interval and runs '
                    . 'whatever is due. It is a floor on how late a job can '
                    . 'be, not a promise about when one runs. Shorter costs '
                    . 'wakeups; longer costs punctuality.',
            },
            { key => 'daemon_job_user',
                label   => 'The account scheduled jobs run as',
                type    => 'text',
                default => '',
                note    => 'A job runs as a REAL user holding run_jobs, never '
                    . 'as system - a timer that can call anything is a second '
                    . 'write plane wearing a clock. A purpose-made account is '
                    . 'preferred over a person\'s: a person\'s rotates, '
                    . 'changes and eventually leaves, and a job inheriting '
                    . 'those rights either breaks when they go or keeps '
                    . 'working with the rights of somebody who has left. '
                    . 'Empty means no job runs.',
            },
            { key => 'daemon_restart_backoff',
                label   => 'Seconds to wait before restarting a failed service',
                type    => 'text',
                default => '5',
                note    => 'Doubles on each consecutive failure. A service '
                    . 'that keeps dying is reported as FAILED rather than '
                    . 'restarted forever - a flapping child reported as '
                    . 'healthy is the dishonesty this runtime exists to '
                    . 'avoid.',
            },
        ],

        # ADR 0009. Each list is consumed by something; a declaration nothing
        # reads is a comment with punctuation.
        owns => {
            config_keys =>
                [qw(daemon_tick_seconds daemon_job_user daemon_restart_backoff)],

            # Schedules, run records and service state. Declared so a content
            # backup and a site package carry them, rather than a restored
            # site arriving with no memory of what had already run.
            storage => ['lazysite/daemon/'],

            # NONE, and deliberately. Phase 1 has no socket: the scheduler
            # needs no way in, so it is given none. When phase 2 adds the
            # local socket, it is DECLARED here rather than discovered.
            endpoints => [],

            # The right to be the account a scheduled job runs as. Declared
            # here because t/lint/76 requires every capability to be core or
            # plugin-owned, and because holding it is what separates an
            # account that may carry a job from one that may not.
            capabilities => ['run_jobs'],

            # Core only in phase 1. An event loop (IO::Async) is a phase 2
            # question, when there is a socket to wait on; a tick loop needs
            # nothing.
            deps => [],
        },

        actions => [
            { id => 'status', label => 'Status', run => 'action' },
        ],
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1               if $argv[$i] eq '--describe';
        $opt{action}   = $argv[ $i + 1 ] if $argv[$i] eq '--action';
        $opt{docroot}  = $argv[ $i + 1 ] if $argv[$i] eq '--docroot';
    }

    if ( $opt{describe} ) {
        # PRETTY, and deliberately - every other plugin prints one compact
        # line. That difference found a real bug: t/lint/76 read a plugin's
        # description with `decode_json(`...`)`, and backticks in LIST context
        # return a list of LINES, so only the first reached the decoder. With
        # single-line output the first line is the whole document, so the bug
        # was invisible for as long as every plugin happened to be compact -
        # and a plugin that was not simply vanished from the capability
        # OWNERSHIP check without any test failing.
        #
        # The lint is fixed. This stays multi-line so that something real
        # exercises the fixed path: make it compact and nothing tests it again.
        print JSON::PP->new->canonical->pretty->encode( describe() );
        return 0;
    }

    if ( ( $opt{action} // '' ) eq 'status' ) {
        # Status is answered by the supervisor, which is the only thing that
        # knows whether a process exists. Reporting from here would be
        # reporting the CONFIGURATION and calling it the state, which is the
        # failure SM222 is about.
        require Lazysite::Daemon::Supervisor;
        my $st = Lazysite::Daemon::Supervisor::status( $opt{docroot} );
        print JSON::PP->new->canonical->pretty->encode($st);
        return 0;
    }

    print "usage: daemon.pl --describe | --action status [--docroot DIR]\n";
    return 1;
}

exit( run(@ARGV) ) unless caller;
1;
