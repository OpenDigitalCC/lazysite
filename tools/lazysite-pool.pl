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
#      processor's SM142 dual-mode dispatch detects - and execs THE SITE'S
#      OWN lazysite-processor.pl, from its cgi-bin (ruling 203), or answers
#      503 when the site's engine tree is missing.
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
  FRONT_DOOR=    1 = the worker routes every request (one vhost rule)
  CGIBIN=        the site's cgi-bin: the processor the pool runs and the
                 surfaces for relayed requests (default ../cgi-bin)
  RELAY_TIMEOUT= seconds a relayed surface may take (default 120)
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

# SM309: FRONT_DOOR is a declared boolean, so an unrecognised value is refused
# rather than guessed at - and refused HERE, beside the other configuration
# checks, before anything has been created.
#
# This was `length($ENV{FRONT_DOOR}) && $ENV{FRONT_DOOR} ne '0'` at the point of
# use, so every non-empty value except '0' enabled the mode: FRONT_DOOR=false,
# no and off all meant yes. That is the class 0.10.9 removed from the MCP
# surface, where an unrecognised value for a declared boolean is now refused
# outright instead of coerced - the fixture-E finding, where `draft` with an
# unrecognised value read as CLEAR and published protected content while
# returning ok:1. The pool conf is the one place an operator writes such a value
# BY HAND, into a file, with no validation and no feedback, so it has the
# strongest case for the same treatment.
#
# Validating at the point of USE was not enough: the launcher binds and chowns
# its socket first, so a bad value was not reported until after those side
# effects, and on a host where the socket setup itself failed it was never
# reported at all. Configuration is checked before anything is created.
#
# Defaulting silently to off would be a second version of the same defect - a
# control doing something other than what was written and saying nothing. A pool
# that refuses to start is visible; one running in a mode nobody chose is not,
# and the other half of SM309 exists because that state was undetectable from
# outside.
sub pool_bool {
    my ( $name, $raw ) = @_;
    return 0 unless defined $raw;
    my $v = lc $raw;
    $v =~ s/\A\s+|\s+\z//g;
    return 0 if $v eq '';
    return 1 if $v =~ /\A(?:1|true|yes|on)\z/;
    return 0 if $v =~ /\A(?:0|false|no|off)\z/;
    bail( "$name=$raw is not a yes/no value. Use 1, true, yes or on to switch "
            . 'it on; 0, false, no or off to switch it off. It is refused '
            . 'rather than guessed at, because guessing wrong here changes how '
            . 'every request is routed and nothing would say so.' );
}

my $front_door = pool_bool( 'FRONT_DOOR', $ENV{FRONT_DOOR} );

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

# SM294: front-door mode. With FRONT_DOOR=1 in the pool conf the worker routes
# every request itself, so the vhost needs one rule instead of a dozen - the
# arrangement SM248, SM268 H17 and SM283 each came out of. Off by default: an
# existing pool must behave exactly as it did.
#
# Everything set here is read ONCE by the worker at startup, because FCGI.pm
# replaces %ENV on every request with that request's parameters. t/lint/43 pins
# that, and it is why these are pool settings rather than per-request ones.
# SM309: the value was validated with the rest of the configuration, above.
$ENV{LAZYSITE_FRONT_DOOR} = 1 if $front_door;

# Where the other surfaces live, for the requests the worker cannot answer as
# itself (another surface, or anything needing the auth wrapper). The
# conventional layout is cgi-bin beside the docroot, which is what every shipped
# installer produces; CGIBIN= overrides it. SM1226: in both modes, because the
# split templates send the Odoo endpoint to the pool too, and a worker with no
# warm-fork parent to hand it to runs it from here.
$ENV{LAZYSITE_CGIBIN} =
    length( $ENV{CGIBIN} // '' )
    ? $ENV{CGIBIN}
    : dirname($docroot) . '/cgi-bin';
$ENV{LAZYSITE_RELAY_TIMEOUT} = $ENV{RELAY_TIMEOUT}
    if length( $ENV{RELAY_TIMEOUT} // '' );

# --- which engine serves this site (ruling 203) ---
#
# The pool runs THE SITE'S OWN ENGINE: the processor in its cgi-bin (the same
# directory the relays above use, and the copy the manager, auth and DAV CGIs
# run) and the lib beside its docroot, where install.pl lays it. It used to exec
# the package's processor beside this launcher, so after a package upgrade the
# site had not yet taken, the pool rendered with the new engine and every other
# surface with the old one: one site, two engine versions. Now a site moves to
# a new engine through its own `upgrade`, and only then.
#
# A site whose tree is missing or unreadable is a fault (ruling 206). The pool
# refuses it, answering 503 and logging what is missing, and never falls back
# to the package's engine: that is the skew this exists to remove. `lazysite
# check` names the same fault and its remedy. Checked after the privilege
# drop, so "readable" means readable by the account that runs it.
#
# The one exception is a shared read-only engine (SM1361, rulings 200-202): a
# container whose image is the engine and whose site holds no engine copy. The
# image marks its engine root with SHARED-ENGINE (the name
# Lazysite::Extensions::$SHARED_MARK reads); on such an engine the engine's own
# processor IS the site's, as before. It is read from this launcher's own tree,
# never from the site's, so a site cannot plant it.
my $engine_root = dirname( dirname( abs_path($0) ) );
my $shared_mark = "$engine_root/SHARED-ENGINE";
my $processor;
if ( -f $shared_mark && !-l $shared_mark ) {
    $processor = "$engine_root/lazysite-processor.pl";
    bail("processor not found at $processor") unless -f $processor;
}
else {
    $processor = "$ENV{LAZYSITE_CGIBIN}/lazysite-processor.pl";
    my $parts = "$ENV{LAZYSITE_CGIBIN}/lazysite-processor";
    my $lib   = dirname($docroot) . '/lib/Lazysite';
    my @missing;
    push @missing, $processor unless -f $processor && -r _;
    push @missing, "$parts/"  unless -d $parts     && -r _ && -x _;
    push @missing, "$lib/"    unless -d $lib       && -r _ && -x _;
    refuse_site(@missing) if @missing;
}

# --- fd 0 = listen socket (spawn-fcgi convention), exec the processor ---
open STDIN, '<&', $sock
    or bail("dup listen socket to fd 0: $!");
exec( $^X, $processor ) or bail("exec $processor: $!");

# The site's engine tree is missing or unreadable: answer every request 503 and
# say why in the log, once, at start. The visitor is told only that the site is
# unavailable; the paths are the sysop's. FCGI.pm is what the worker itself
# needs, so a host that has none cannot run a pool either way.
sub refuse_site {
    my (@missing) = @_;
    print {*STDERR} "lazysite-pool: $opt{instance}: the site's own engine is missing or "
        . 'unreadable (' . join( ', ', @missing ) . '). Refusing every request with 503; '
        . "the package's engine is never used for a site (ruling 203). Repair: lazysite "
        . "reinstall --docroot $docroot (or upgrade, if the site is behind), then "
        . "systemctl restart lazysite\@$opt{instance}. lazysite check names this too.\n";
    open STDIN, '<&', $sock
        or bail("dup listen socket to fd 0: $!");
    my $req = eval { require FCGI; FCGI::Request() }
        or bail('FCGI.pm is not installed, so the pool cannot answer at all');
    while ( $req->Accept() >= 0 ) {
        print "Status: 503 Service Unavailable\r\n"
            . "Content-Type: text/plain; charset=utf-8\r\n"
            . "Retry-After: 300\r\n\r\n"
            . "This site is unavailable while its installation is repaired.\n";
    }
    exit 0;
}

__END__

=head1 NAME

lazysite-pool.pl - per-site FastCGI pool launcher for lazysite

=head1 SYNOPSIS

  lazysite-pool.pl --instance example.com [--socket PATH] [--run-dir DIR]

=head1 DESCRIPTION

Started (normally by the C<lazysite@.service> systemd template unit, as
root) with the pool's identity in the environment, it binds the unix
listen socket, makes it connectable by the web server group, drops
privileges to the site user and execs the site's own
C<lazysite-processor.pl> (from C<CGIBIN>, with the lib beside the
docroot) with the socket on fd 0 - the spawn-fcgi convention the
processor's SM142 dual-mode dispatch detects. The processor then services
requests from a persistent accept loop (one pool per site, the PHP-FPM
model). The package's processor is never run for a site: a site whose
engine tree is missing or unreadable is answered 503 and logged until it
is repaired.

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
