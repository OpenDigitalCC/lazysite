package Lazysite::Odoo::Daemon;

# SM1164 (inbox L7 and its addendum, 2026-10-18): THE ODOO EXTENSION'S OOMD.
#
# "The Odoo extension starts and uses oomd, a resident OOM." The lab measured a
# cold read through the extension at 0.5-1 s against Odoo's own 55-85 ms, and
# SM1144's bench put module loading at about three quarters of an Odoo token
# request. oomd (OOM 0.31+) loads OOM, the operations, the sign-in, the TLS
# connection and the field definitions once and serves requests over a socket.
#
# THIS MODULE IS THE EXTENSION'S SIDE OF THAT, and only the parts that are not
# a process or a call:
#
#   * D1 the site's oomd.conf, from the extension's config, 0600, beside its
#     secrets. KEYS ARE NEVER IN IT: `credentials` carries labels and paths of
#     the key FILES (Lazysite::Odoo::Secret), and a request names a label.
#   * where the socket is: lazysite/run/oomd.sock when that path is under 104
#     bytes (the Unix socket limit), otherwise oomd's default directory with a
#     name of its own;
#   * the daemon's name, SIGHUP to the running service, and D4's status.
#
# The service that runs it is Lazysite::Daemon::Service::Oomd (D2); the call
# path is in Lazysite::Odoo (D3).
#
# THE THREE SETTINGS (SM1164's choices, 2026-10-18):
#   odoo_daemon          off (default) | on | required
#                        `on`: the daemon is used when it is running, and a
#                        site whose daemon is down falls back to the in-process
#                        path - a slower page, not a refused one - and records
#                        that. `required` turns the fallback off: a down daemon
#                        refuses the call with OOM's daemon-down code.
#   odoo_daemon_workers  default 4. The owner's ruling is to match Odoo's own
#                        workers, which the operator sets: lazysite cannot read
#                        Odoo's configuration.
use strict;
use warnings;
use Digest::SHA     ();
use File::Path      qw(make_path);
use Lazysite::Util  qw(log_event);
use Lazysite::Paths ();

our $SOCKET_LIMIT = 104;    # a Unix socket path must be shorter than this (bytes)
our $CACHE_TTL = 300; # oomd's cache_ttl_version: a module installed in Odoo is seen within this long

sub _lz { return Lazysite::Paths::lazysite_dir( $_[0] ) }

# --- the settings -------------------------------------------------------------------

# ( 'off' | 'on' | 'required', '' ) or ( undef, why ). A value this does not
# know is refused by name: a typo for `required` that quietly meant `off` would
# be a fallback the operator had asked not to have.
sub mode_from {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return ( 'off', '' ) if $v eq '';
    return ( lc $v, '' ) if $v =~ /\A(?:off|on|required)\z/i;
    return ( 'off', '' ) if $v =~ /\A(?:false|no|0)\z/i;
    return ( 'on',  '' ) if $v =~ /\A(?:true|yes|1)\z/i;
    return ( undef, "odoo_daemon must be off, on or required, not '$v'" );
}

sub workers_from {
    my ($v) = @_;
    return ( 4,     '' ) unless defined $v && length $v;
    return ( undef, 'odoo_daemon_workers must be a whole number from 1 to 64' )
        unless $v =~ /\A[0-9]{1,2}\z/ && $v >= 1 && $v <= 64;
    return ( 0 + $v, '' );
}

# --- the places ------------------------------------------------------------------------

sub conf_path { return _lz( $_[0] ) . '/odoo/oomd.conf' }
sub run_dir   { return _lz( $_[0] ) . '/run' }
sub runs_dir  { return _lz( $_[0] ) . '/odoo/runs' }
sub err_file  { return run_dir( $_[0] ) . '/oomd.err' }
sub log_file  { return run_dir( $_[0] ) . '/oomd.log' }

# The daemon's name keys its pid record, log and cache. The host's runtime conf
# names the instance (conventionally the domain, SM893); a site with none - a
# tarball, a test - is named by its directory and a short hash of the full path
# so two sites can never share one. No systemctl here: the CGI asks this on
# every call.
my %NAME;

sub name {
    my ($root) = @_;
    return $NAME{$root} if exists $NAME{$root};
    require Cwd;
    my $real = Cwd::realpath($root) // $root;
    my $inst;
    require Lazysite::Daemon::Supervisor;
    if ( opendir my $dh, $Lazysite::Daemon::Supervisor::DAEMON_ETC ) {
        for my $f ( sort grep { /\.conf\z/ } readdir $dh ) {
            open my $fh, '<', "$Lazysite::Daemon::Supervisor::DAEMON_ETC/$f" or next;
            my ($doc) = map { /^DOCROOT=(.*)$/ ? $1 : () } <$fh>;
            close $fh;
            next unless defined $doc;
            my $d = Cwd::realpath($doc) // $doc;
            if ( $d eq $real ) { ( $inst = $f ) =~ s/\.conf\z//; last }
        }
        closedir $dh;
    }
    my $n = $inst;
    unless ( defined $n && $n =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/ ) {
        my @p    = grep { length } split m{/}, $real;
        my $last = $p[-1] // 'site';
        $last = $p[-2] if $last =~ /\A(?:public_html|htdocs|html|www|site)\z/ && @p > 1;
        $last =~ s/[^A-Za-z0-9_.-]/-/g;
        $last =~ s/\A[^A-Za-z0-9]+//;
        $last = 'site' unless length $last;
        $n = substr( $last, 0, 50 ) . '-' . substr( Digest::SHA::sha1_hex($real), 0, 8 );
    }
    return $NAME{$root} = $n;
}

# ( $path, 'site' | 'default' ). lazysite names which, in `lazysite check`.
sub socket_for {
    my ($root) = @_;
    my $own = run_dir($root) . '/oomd.sock';
    return ( $own, 'site' ) if length $own < $SOCKET_LIMIT;

    # Too long for a Unix socket: oomd's own default directory, which is
    # /tmp/oomd-<uid> (0700, owner only) when there is no per-user runtime
    # directory, named for the site. Stated as a path and not left to oomd,
    # because the service and the CGI must agree on it whatever each one's
    # environment says, and the supervisor creates the directory.
    return ( "/tmp/oomd-$</" . name($root) . '.sock', 'default' );
}

# --- D1: the conf -------------------------------------------------------------------------

# The account labels and the key files behind them: `conn` is the connection
# user's, `grant-<hash>` an MCP grant's own Odoo account, `sched-<hash>` a
# scheduled binding's own login (SM1161). Only a key that exists is named - oomd
# refuses a config whose credential file it cannot read, which would be every
# call refused for one grant's missing key.
sub _credentials {
    my ($conn) = @_;
    require Lazysite::Odoo;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $Lazysite::Odoo::DOCROOT;
    my @c;
    my $add = sub {
        my ( $account, $login, $label ) = @_;
        my $p = Lazysite::Odoo::Secret::key_path($account) // return;
        return unless -f $p;
        $label //= $account;  # a grant's and a schedule's label is its key account's name
        push @c, defined $login ? "$label:$login:$p" : "$label:$p";
    };
    $add->( $Lazysite::Odoo::ACCOUNT, undef, 'conn' );
    for my $map ( Lazysite::Odoo::read_grants(), Lazysite::Odoo::read_scheduled() ) {
        next unless ref $map eq 'HASH';
        for my $k ( sort keys %$map ) {
            my $g = $map->{$k};
            next unless ref $g eq 'HASH' && length( $g->{id} // '' ) && length( $g->{login} // '' );
            $add->( $g->{id}, $g->{login} );
        }
    }
    return @c;
}

# ( $text, '' ) or ( undef, why ). Labels and paths, never a key.
sub render_conf {
    my ($root) = @_;
    require Lazysite::Odoo;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $root;
    my ( $c, $why ) = Lazysite::Odoo::connection();
    return ( undef, $why ) unless $c;
    my ($sock) = socket_for($root);
    my @l = (
        '# Written by lazysite from the Odoo extension\'s config (SM1164). Labels and paths only; no key is ever here.',
        "url = $c->{url}",
        "db = $c->{db}",
        "login = $c->{login}",
        "timeout = $c->{timeout}",
        'max_response_bytes = ' . ( $c->{max_kb} * 1024 ),
        'allow_writes = ' . ( $c->{allow_writes} ? 1 : 0 ),
        ( $c->{ca_file} ? "ssl_ca_file = $c->{ca_file}" : () ),
        'runs_dir = ' . runs_dir($root),
        'record_reads = 0', # a read leaves no run folder: the in-process path leaves none either
        'cache_dir = ' . _lz($root) . '/odoo/cache',
        "cache_ttl_version = $CACHE_TTL",
        ( @{ $c->{pack_dirs} || [] } ? 'pack_dirs = ' . join( ':', @{ $c->{pack_dirs} } ) : () ),
        "workers = $c->{daemon_workers}",
        "socket = $sock",
        'log = ' . log_file($root),
    );
    my @cred = _credentials($c);
    push @l, 'credentials = ' . join( ', ', @cred ) if @cred;
    return ( join( "\n", @l ) . "\n", '' );
}

# Writes the conf 0600 (a temporary file made under umask 077, renamed over it,
# so there is no instant it is readable by anyone else). Returns { ok, changed,
# path } or { ok => 0, error }. With the daemon off the file is REMOVED: a conf
# that names key paths has no reason to stay.
sub write_conf {
    my ($root) = @_;
    my $path = conf_path($root);
    require Lazysite::Odoo;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $root;
    my ( $c, $cwhy ) = Lazysite::Odoo::connection();
    if ( $c && $c->{daemon} eq 'off' ) {
        my $had = -e $path ? 1 : 0;
        unlink $path;
        return { ok => 1, changed => $had, removed => $had, path => $path };
    }
    my ( $text, $why ) = render_conf($root);
    return { ok => 0, error => $why // $cwhy } unless defined $text;
    my $old;
    if ( open my $ofh, '<:raw', $path ) { local $/; $old = <$ofh>; close $ofh }
    return { ok => 1, changed => 0, path => $path } if defined $old && $old eq $text;
    make_path( _lz($root) . '/odoo' );
    my $tmp = "$path.tmp.$$";
    my $um  = umask 077;
    my $ok  = open my $out, '>:raw', $tmp;
    umask $um;
    return { ok => 0, error => "cannot write the oomd config: $!" } unless $ok;
    print  {$out} $text;
    unless ( close $out ) { unlink $tmp; return { ok => 0, error => "cannot write the oomd config: $!" } }
    chmod 0600, $tmp;
    unless ( rename $tmp, $path ) { unlink $tmp; return { ok => 0, error => "cannot write the oomd config: $!" } }
    return { ok => 1, changed => 1, path => $path };
}

# The conf rewritten and the service told: what a config save, and a key set or
# cleared (a new label), do. SIGHUP reloads the config and the packs and keeps
# the socket; a change of odoo_packs (OOM reads those from its environment, set
# when the service starts) is the service's to notice and restart for.
sub refresh {
    my ($root) = @_;
    my $w = write_conf($root);
    $w->{signalled} = signal( $root, 'HUP' ) if $w->{ok};
    return $w;
}

# The service's pid, when the supervisor started it and it is still ours.
sub signal {
    my ( $root, $sig ) = @_;
    require Lazysite::Daemon::Supervisor;
    my $pid = Lazysite::Daemon::Supervisor::service_pid( $root, 'oomd' ) or return 0;
    return kill( $sig, $pid ) ? 1 : 0;
}

# --- D3: the client --------------------------------------------------------------------------

# The OOM client for this site's daemon, or ( undef, why ) when it cannot be
# made (OOM older than 0.31). fallback => 0 ALWAYS: the extension decides what
# a down daemon means (Lazysite::Odoo), because the in-process path it falls
# back to is its own, with the site's packs and the session transport, and one
# implementation of it is better than two.
sub client {
    my ( $root, $conn ) = @_;
    my $ok = eval { require Odoo::Ops::Client::Daemon; 1 };
    return ( undef, 'OOM 0.31 or later (the daemon client) is not installed' ) unless $ok;
    my ($sock) = socket_for($root);
    return ( Odoo::Ops::Client::Daemon->new(
            socket   => $sock,
            fallback => 0,
            timeout  => ( $conn->{timeout} // 30 ) + 15,
    ), '' );
}

# --- D4: what the operator sees -----------------------------------------------------------------

# { mode, name, socket, socket_in, installed, running, health => { ... },
# failed, reason } for the Odoo status and `lazysite check`. Never dies; a
# daemon that does not answer is `running => 0`, not an error.
sub status {
    my ($root) = @_;
    require Lazysite::Odoo;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $root;
    my $kv = Lazysite::Odoo::read_conf() || {};
    my ($mode) = mode_from( $kv->{odoo_daemon} );
    $mode //= 'off';
    my ( $sock, $in ) = socket_for($root);
    require Lazysite::Daemon::Service::Oomd;
    my %s = ( mode => $mode, name => name($root), socket => $sock, socket_in => $in,
        installed => Lazysite::Daemon::Service::Oomd::installed() ? 1 : 0, running => 0 );
    return \%s if $mode eq 'off';
    my $h = eval {
        require Odoo::Ops::Daemon::Path;
        Odoo::Ops::Daemon::Path->health( socket => $sock, timeout => 3 );
    };
    if ( ref $h eq 'HASH' ) {
        $s{running} = 1;
        my $w = ref $h->{workers} eq 'HASH' ? $h->{workers} : {};
        $s{health} = {
            name    => $h->{name},
            version => $h->{version},
            packs   => $h->{packs},
            workers => ( $w->{total} // $h->{workers} ),
            uptime  => $h->{uptime},
        };
    }
    require Lazysite::Daemon::Supervisor;
    my $st = Lazysite::Daemon::Supervisor::service_state( $root, 'oomd' );
    if ( $st->{failed} ) {
        $s{failed} = 1;
        $s{reason} = Lazysite::Daemon::Service::Oomd::failure_reason($root);
    }
    return \%s;
}

1;
