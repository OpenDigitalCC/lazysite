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
    $opt{user}    = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--user';
    $opt{help}    = 1               if $ARGV[$i] =~ /\A(?:-h|--help)\z/;
}

if ( $opt{help} ) {
    print <<'USAGE';
lazysited - the lazysite persistent runtime (SM666)

  lazysited --docroot DIR [--user U]   run the supervisor (systemd runs this)
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

# --- drop privileges -------------------------------------------------------
#
# The unit starts this as root for ONE reason: systemd cannot template `User=`
# from an instance name, and the instance name is the site (normally its
# domain), which is not a Unix user. lazysite-pool.pl has the same problem and
# solves it the same way, so this follows that code rather than inventing a
# second privilege-drop.
#
# UNLIKE THE POOL, there is nothing here that NEEDS root - phase 1 binds no
# socket. Root exists only long enough to become the site's user, and this runs
# before the supervisor is even loaded, so no daemon code executes privileged.
#
# Started unprivileged AS the target user (an operator debugging by hand), it
# skips the drop. Started unprivileged as somebody ELSE it refuses, because
# running the site's jobs as the wrong account is exactly the confusion the
# capability model is trying to prevent one layer up.
if ( defined $opt{user} && length $opt{user} ) {
    my ( $uid, $gid ) = ( getpwnam $opt{user} )[ 2, 3 ];
    unless ( defined $uid ) {
        print STDERR "lazysited: USER $opt{user} does not exist\n";
        exit 2;
    }

    if ( $> == 0 ) {
        my $err = _drop_privileges( $uid, $gid );
        if ( defined $err ) {
            print STDERR "lazysited: $err\n";
            exit 2;
        }
    }
    elsif ( $> != $uid ) {
        my $me = getpwuid($>);
        printf STDERR
            "lazysited: started as %s but USER=%s; start as root (the unit "
            . "does) or as %s\n",
            ( defined $me ? $me : "uid$>" ), $opt{user}, $opt{user};
        exit 2;
    }
}
elsif ( $> == 0 ) {
    # No USER given and we are root. Refuse rather than run the site's
    # scheduled jobs as root - which would hand every job the one identity the
    # capability model cannot constrain.
    print STDERR
        "lazysited: refusing to run as root without --user; a job must not "
        . "run with root's privileges\n";
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

# Become $uid:$gid. Returns undef, or what failed.
#
# SM792: THE GID DROP IS CHECKED, AS THE UID DROP ALWAYS WAS. Assigning $) and
# $( fails silently - the variables simply keep their old values - so a drop
# that set the uid and not the group left the runtime in root's group with
# nothing said. Each assignment is read back: the effective group and the one
# supplementary group, then the real group, before the uid moves.
#
# Loads no Lazysite module: this runs as root, and the lib may be the site
# user's to write. t/unit/daemon/13 drives it.
sub _drop_privileges {
    my ( $uid, $gid ) = @_;
    $) = "$gid $gid";
    my @eff = split ' ', $);
    return "setgid $gid failed: the effective groups are $)"
        unless @eff && !grep { $_ != $gid } @eff;
    $( = $gid;
    return "setgid $gid failed: the real gid is $(" unless ( split ' ', $( )[0] == $gid;
    require POSIX;
    return "setuid $uid failed: $!" unless POSIX::setuid($uid);
    return 'privilege drop failed (still root)' if $> == 0 || $< == 0;
    return undef;
}
