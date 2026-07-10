#!/usr/bin/perl
# tools/lazysite-pool.pl - per-site FastCGI pool launcher (SM139, packaging
# the SM142 persistent runtime).
#
# Why this exists: systemd cannot template User= from an instance name
# (%i is a domain, not an account), so lazysite@.service starts THIS
# launcher as root with the pool's identity loaded from
# /etc/lazysite/pools/%i.conf (EnvironmentFile: DOCROOT=, USER=, and
# optionally GROUP=, WORKERS=, MAX_REQUESTS=, SOCKET=). The launcher:
#
#   1. binds the unix listen socket (/run/lazysite/<instance>.sock),
#   2. chowns/chmods it so the web server group can connect,
#   3. drops privileges to USER (no root remains in the request path),
#   4. puts the listen socket on fd 0 - the spawn-fcgi convention the
#      processor's SM142 dual-mode dispatch detects - and execs
#      lazysite-processor.pl from the payload next to this script.
#
# Nothing here writes into the site tree (the SM139 principle); the only
# root actions are the bind and the privilege drop. Run unprivileged as
# the target USER it skips the drop, so a pool can be started by hand for
# debugging.
#
# Core-only Perl; no CPAN deps (FCGI/FCGI::ProcManager are loaded by the
# processor itself, lazily).

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use Getopt::Long   ();
use POSIX          ();
use Socket         qw(AF_UNIX SOCK_STREAM SOMAXCONN sockaddr_un);

my %opt = ( instance => '', socket => '', rundir => '/run/lazysite', help => 0 );
Getopt::Long::GetOptions(
    'instance=s' => \$opt{instance},
    'socket=s'   => \$opt{socket},
    'run-dir=s'  => \$opt{rundir},
    'help'       => \$opt{help},
) or usage(2);
usage(0) if $opt{help};

sub usage {
    my ($rc) = @_;
    print <<'USAGE';
Usage: lazysite-pool.pl --instance NAME [--socket PATH] [--run-dir DIR]

Bind a FastCGI listen socket, drop privileges, exec the lazysite
processor with the socket on fd 0. Pool identity comes from the
environment (systemd EnvironmentFile=/etc/lazysite/pools/NAME.conf):

  DOCROOT=       site public_html (required)
  USER=          account the pool runs as (required)
  GROUP=         group that may connect to the socket (default www-data)
  WORKERS=       FCGI::ProcManager prefork size (default 2)
  MAX_REQUESTS=  worker recycles after N requests (default 500)
  SOCKET=        socket path (default RUNDIR/NAME.sock)
USAGE
    exit( $rc // 0 );
}

sub bail {
    my ($msg) = @_;
    print {*STDERR} "lazysite-pool: $msg\n";
    exit 1;
}

bail('--instance NAME is required') unless length $opt{instance};
bail('instance name must be [A-Za-z0-9._-]')
    if $opt{instance} !~ /^[A-Za-z0-9._-]+$/;

my $docroot = $ENV{DOCROOT};
my $user    = $ENV{USER};
my $group   = length( $ENV{GROUP} // '' ) ? $ENV{GROUP} : 'www-data';
bail('DOCROOT= not set (missing/incomplete /etc/lazysite/pools/*.conf?)')
    unless length( $docroot // '' );
bail("DOCROOT $docroot is not a directory") unless -d $docroot;
bail('USER= not set (missing/incomplete /etc/lazysite/pools/*.conf?)')
    unless length( $user // '' );
bail('USER=root refused: lazysite pools never run as root (SM139)')
    if $user eq 'root';

my ( $uid, $gid ) = ( getpwnam $user )[ 2, 3 ];
bail("USER $user does not exist") unless defined $uid;
my $sock_gid = getgrnam($group);
$sock_gid = $gid unless defined $sock_gid;

# --socket wins, then the pool conf's SOCKET= (documented in the unit and
# in usage above - it was advertised but never read before SM139 i4), then
# the /run/lazysite/<instance>.sock convention the vhost templates encode.
my $sock_path
    = length $opt{socket}          ? $opt{socket}
    : length( $ENV{SOCKET} // '' ) ? $ENV{SOCKET}
    :                                "$opt{rundir}/$opt{instance}.sock";

# The unit's RuntimeDirectory= creates /run/lazysite; cover the by-hand
# case too.
my $sock_dir = dirname($sock_path);
make_path($sock_dir) unless -d $sock_dir;

# --- bind the listen socket (as whoever we started as) ---
unlink $sock_path if -S $sock_path;    # stale socket from a previous run
socket( my $sock, AF_UNIX, SOCK_STREAM, 0 )
    or bail("socket: $!");
bind( $sock, sockaddr_un($sock_path) )
    or bail("bind $sock_path: $!");
listen( $sock, SOMAXCONN )
    or bail("listen $sock_path: $!");

# Web server connects via group access: USER:GROUP 0660.
if ( $> == 0 ) {
    chown $uid, $sock_gid, $sock_path
        or bail("chown $sock_path: $!");
}
chmod 0660, $sock_path
    or bail("chmod $sock_path: $!");

# --- drop privileges ---
if ( $> == 0 ) {
    # Real+effective gid first (supplementary groups collapse to the
    # site user's primary group), then uid; verify the drop stuck.
    $) = "$gid $gid";
    $( = $gid;
    POSIX::setuid($uid) or bail("setuid $uid: $!");
    bail('privilege drop failed (still root after setuid)') if $> == 0 || $< == 0;
}
else {
    my $me = getpwuid($>);
    bail( 'started as '
            . ( defined $me ? $me : "uid$>" )
            . " but USER=$user; start as root (the unit does) or as $user" )
        if !defined $me || $me ne $user;
}

# --- environment for the worker (SM142 knobs) ---
$ENV{DOCUMENT_ROOT}         = $docroot;
$ENV{LAZYSITE_FCGI_WORKERS} = length( $ENV{WORKERS} // '' )           ? $ENV{WORKERS} : 2;
$ENV{LAZYSITE_FCGI_MAX_REQUESTS} = length( $ENV{MAX_REQUESTS} // '' ) ? $ENV{MAX_REQUESTS} : 500;

# --- fd 0 = listen socket (spawn-fcgi convention), exec the processor ---
my $processor = dirname( dirname( abs_path($0) ) ) . '/lazysite-processor.pl';
bail("processor not found at $processor") unless -f $processor;
open STDIN, '<&', $sock
    or bail("dup listen socket to fd 0: $!");
exec( $^X, $processor ) or bail("exec $processor: $!");

__END__

=head1 NAME

lazysite-pool.pl - per-site FastCGI pool launcher for lazysite

=head1 SYNOPSIS

  lazysite-pool.pl --instance example.com [--socket PATH] [--run-dir DIR]

=head1 DESCRIPTION

Started (normally by the C<lazysite@.service> systemd template unit, as
root) with the pool's identity in the environment, it binds the unix
listen socket, makes it connectable by the web server group, drops
privileges to the site user and execs C<lazysite-processor.pl> with the
socket on fd 0 - the spawn-fcgi convention the processor's SM142
dual-mode dispatch detects. The processor then services requests from a
persistent accept loop (one pool per site, the PHP-FPM model).

systemd cannot set C<User=> from a template instance name, which is why
the drop happens here rather than in the unit; see the comments in
C<lazysite@.service> and F<README.Debian> in the C<lazysite-common>
package.

=head1 ENVIRONMENT

C<DOCROOT> (required), C<USER> (required, never C<root>), C<GROUP>
(socket group, default C<www-data>), C<WORKERS> (default 2),
C<MAX_REQUESTS> (default 500), C<SOCKET> (socket path, default
RUNDIR/NAME.sock; C<--socket> wins over it), all normally from
F</etc/lazysite/pools/E<lt>instanceE<gt>.conf> via the unit's
C<EnvironmentFile=>.

=head1 SEE ALSO

lazysite(1), and C<docs/architecture/performance.md> for the SM142
FastCGI design and measurements.

=cut
