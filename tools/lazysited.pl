#!/usr/bin/perl
# SM666 phase 1: the runtime's entry point - what systemd runs.
#
# It is deliberately thin. Everything that decides anything lives in
# Lazysite::Daemon::Supervisor, so that the decisions are testable without
# starting a process; this file resolves a docroot, loads the library and hands
# over.
#
# THE ONE THING IT MUST GET RIGHT: a disabled runtime exits without doing
# anything. Not "starts and refuses work" - exits. That is the whole of what
# "the process never starts" means, and it is the difference between an
# operator who turned the daemon off and an operator who turned it off and
# still has a long-lived process holding this instance's credentials.
#
# SUPERVISION IS systemd's JOB, per SM222, which explicitly declines to propose
# a process supervisor. This process supervises its own SERVICES; nothing
# supervises this process except the init system.
use strict;
use warnings;

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). No configuration needed.
    #
    # t/lint/59 requires this of every tool that loads a Lazysite module, and
    # it matters more here than for most: this one is started by systemd from a
    # unit file, with none of a shell's assumptions about where it is.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

my %opt;
for my $i ( 0 .. $#ARGV ) {
    $opt{docroot} = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--docroot';
    $opt{status}  = 1               if $ARGV[$i] eq '--status';
    $opt{help}    = 1               if $ARGV[$i] =~ /\A(?:-h|--help)\z/;
}

if ( $opt{help} ) {
    print <<'USAGE';
lazysited - the lazysite persistent runtime (SM666)

  lazysited --docroot DIR      run the supervisor (systemd runs this)
  lazysited --docroot DIR --status   report desired and runtime state
  lazysited --help

It exits immediately, doing nothing, when the daemon plugin is disabled.
That is not an error: it is what disabled means for a process.
USAGE
    exit 0;
}

my $docroot = $opt{docroot} // $ENV{LAZYSITE_DOCROOT} // $ENV{DOCUMENT_ROOT};
unless ( defined $docroot && length $docroot && -d $docroot ) {
    print STDERR "lazysited: no usable docroot (--docroot DIR)\n";
    exit 2;
}

require Lazysite::Daemon::Supervisor;

if ( $opt{status} ) {
    require JSON::PP;
    my $st = Lazysite::Daemon::Supervisor::status($docroot);
    print JSON::PP->new->canonical->pretty->encode($st);
    exit 0;
}

exit Lazysite::Daemon::Supervisor::run( docroot => $docroot );
