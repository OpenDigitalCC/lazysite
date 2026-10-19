package Odoo::Ops::Daemon;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Errno qw(EINTR EAGAIN EWOULDBLOCK ENOENT ECONNREFUSED);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_APPEND);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use IO::Handle;
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP ();
use POSIX ();
use Socket qw(AF_UNIX SOCK_STREAM SOCK_DGRAM PF_UNSPEC SOL_SOCKET pack_sockaddr_un);
use Time::HiRes ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Config;
use Odoo::Ops::Daemon::Path;
use Odoo::Ops::Version;

our @ISA = ('Odoo::Ops::Daemon::Path');

=head1 NAME

Odoo::Ops::Daemon - oomd: a resident OOM that serves requests over a unix socket

=head1 SYNOPSIS

    Odoo::Ops::Daemon->start( name => 'site1', config => '/srv/site1/oomd.conf', foreground => 1 );
    my $health = Odoo::Ops::Daemon->health( name => 'site1' );
    my @running = Odoo::Ops::Daemon->status;

=head1 DESCRIPTION

The program is F<bin/oomd>; this is its library. A daemon is a host for the
operations that exist (L<Odoo::Ops::Service>): it adds no behaviour. A
request produces the report, plan or result C<oom-ops> produces in its own
process, through the same guard, plans, journals, audit and refusals.

A daemon has a name, and the name keys everything it owns: the socket
(C<$XDG_RUNTIME_DIR/oomd/NAME.sock>, else C</tmp/oomd-UID/NAME.sock>, in a
directory only its owner can enter; or the config's C<socket>), the pid file,
the log and the cache directory. It serves the one Odoo database its config
names and refuses a request for another. Any number of daemons, each with its
own config, user and name, may serve the same instance; none holds a lock or
state another needs.

The master process accepts connections and hands each request line to an idle
worker over a socketpair. The workers are forked at start (a prefork pool),
each synchronous and running the existing code; a worker is replaced after
C<max_requests> requests, and one that dies is replaced and the request it held
answered with a C<transport> fault naming the daemon. The master never runs an
operation and never writes a secret: its log holds the request id, the
operation, the outcome and the milliseconds, nothing else.

=head2 Protocol

One JSON object per line, one response per request.

    {"v":1, "op":"core.get", "phase":"run", "params":{...},
     "credential":{"label":"conn"} | {"session":"<id>"}, "actor":"...",
     "plan":"<path or run id>", "id":"<the caller's request id>"}
    {"v":1, "verb":"health"}

    {"id":..., "ok":true,  "result":{...}}
    {"id":..., "ok":false, "error":{"kind","code","message","fix"}}

C<phase> is C<run>, C<check>, C<apply>, C<revert>, C<resume> or C<approve>
(L<Odoo::Ops::Service>). A key is never sent: a request names a C<label> of the
C<credentials> the daemon's config lists, and a session id is used for that
request only.

=head2 Config

An ops config (L<Odoo::Ops::Config>) with these keys besides; an unknown key
is refused.

    workers            worker processes, default 4
    max_requests       requests a worker serves before it is replaced, default 500
    shutdown_deadline  seconds SIGTERM waits for requests in hand, default 30
    socket             the socket path, default as above
    log                the log path, default $XDG_STATE_HOME/oomd/NAME.log
    credentials        label:/path/to/key-file, ... (label:login:/path when the key
                       is another login's); the label C<conn> without an entry is the
                       config's own api_key_file
    act_as             the label of one of those credentials (or conn): the service credential an
                       operation that declares acts_for writes with (docs/OPS.md, Acting for a person)

=cut

my %KEYS = map { $_ => 1 } qw(workers max_requests shutdown_deadline socket log credentials act_as);
my $MAX_LINE   = 64 * 1024 * 1024;
my $MAX_QUEUE  = 1024;
my $CLIENT_IDLE = 120;

# ---- names and places ------------------------------------------------------------------------

=head2 Names and places

The rules for a name, the places a daemon keeps its files and the two ways of asking
one are in L<Odoo::Ops::Daemon::Path>, which this class inherits: C<valid_name>,
C<runtime_dir>, C<state_dir>, C<cache_dir>, C<paths>, C<socket_for>, C<ask>,
C<health> and C<status>.

=cut

# a directory that only its owner can enter, made if it is not there
sub _private_dir ($dir, $what) {
    if ( !-d $dir ) {
        my $old = umask 077;
        eval { make_path( $dir, { mode => 0700 } ) };
        umask $old;
    }
    my @st = lstat $dir;
    Odoo::Error->throw( kind => 'config', message => "cannot make the $what directory $dir: $!" ) if !@st || !-d _;
    Odoo::Error->throw( kind => 'config', message => "the $what directory $dir is not ours (owner uid $st[4])", fix => 'remove it, or set XDG_RUNTIME_DIR to a directory of your own' )
        if $st[4] != $<;
    chmod 0700, $dir if $st[2] & 077;
    return $dir;
}

# ---- the config ------------------------------------------------------------------------------

sub load_config ($class, $name, $path) {
    $class->_need_name($name);
    Odoo::Error->throw( kind => 'usage', message => 'oomd needs --config FILE', fix => 'oomd --name NAME --config FILE' ) if !defined $path || !length $path;
    my ( $config, $x ) = Odoo::Ops::Config->load_with_extra( $path, sort keys %KEYS );
    my $int = sub ($key, $default, $min, $max) {
        my $v = $x->{$key} // $default;
        Odoo::Error->throw( kind => 'config', message => "$key must be a whole number from $min to $max, not '$v'" )
            if $v !~ /\A\d+\z/ || $v < $min || $v > $max;
        return 0 + $v;
    };
    my %c = (
        config       => $config,
        name         => $name,
        path         => $path,
        workers      => $int->( 'workers', 4, 1, 64 ),
        max_requests => $int->( 'max_requests', 500, 1, 1_000_000 ),
        deadline     => $int->( 'shutdown_deadline', 30, 1, 3600 ),
        credentials  => {},
    );
    for my $k (qw(socket log)) {
        next if !defined $x->{$k};
        Odoo::Error->throw( kind => 'config', message => "$k must be an absolute path, not '$x->{$k}'" ) if $x->{$k} !~ m{\A/};
        $c{$k} = $x->{$k};
    }
    if ( defined $x->{credentials} ) {
        for my $item ( grep { length } map { s/^\s+|\s+\z//gr } split /,/, $x->{credentials} ) {
            my ( $label, $rest ) = $item =~ /\A([A-Za-z][\w.-]{0,31})\s*[:=]\s*(.+)\z/
                or Odoo::Error->throw( kind => 'config', message => "credentials: '$item' is not label:/path/to/key-file" );
            my ( $login, $file ) = $rest =~ m{\A(?:(.+?):)?(/.*)\z}
                or Odoo::Error->throw( kind => 'config', message => "credential '$label' is a path to a key file, never a key" );
            my @st = stat $file;
            Odoo::Error->throw( kind => 'config', message => "credential '$label': cannot read $file: $!" ) if !@st;
            Odoo::Error->throw( kind => 'config', message => sprintf( "credential '%s': %s is mode %04o; it must deny group and other (chmod 600)", $label, $file, $st[2] & 07777 ) )
                if $st[2] & 077;
            $c{credentials}{$label} = { path => $file, ( defined $login ? ( login => $login ) : () ) };
        }
    }
    if ( defined $x->{act_as} ) {
        my $l = $x->{act_as};
        Odoo::Error->throw( kind => 'config', message => "act_as must be a credential label, not '$l'" ) if $l !~ /\A[A-Za-z][\w.-]{0,31}\z/;
        Odoo::Error->throw( kind => 'config', message => "act_as names '$l', which is not a label this config holds (conn or one of credentials)" )
            if $l ne 'conn' && !$c{credentials}{$l};
        $c{act_as} = $l;
    }
    $config->{cache_dir} //= $class->cache_dir($name);
    return \%c;
}

# ---- starting -----------------------------------------------------------------------------------

=head2 start(name =E<gt> N, config =E<gt> F, foreground =E<gt> 0|1)

Starts the daemon. Prints C<oomd NAME ready SOCKET> on standard output when the
socket accepts. Without C<foreground> it forks into the background after the
checks, once the daemon is ready, and the parent exits 0. A second daemon of a
name that is running is refused, naming its pid. Returns the exit status.

=cut

sub start ($class, %o) {
    my $self = bless { name => $o{name}, conf_path => ( defined $o{config} ? File::Spec->rel2abs($o{config}) : undef ), foreground => $o{foreground} ? 1 : 0 }, $class;
    $self->{conf} = $class->load_config( $o{name}, $self->{conf_path} );
    my $p = $self->{paths} = $class->paths( $o{name}, map { defined $self->{conf}{$_} ? ( $_ => $self->{conf}{$_} ) : () } qw(socket log) );
    _private_dir( $p->{run}, 'runtime' );
    _private_dir( dirname( $p->{log} ), 'log' ) if !defined $self->{conf}{log};
    $self->_refuse_if_running;
    $self->_bind;
    # modules every worker needs are compiled once here, so a worker is a fork, not a start
    require Odoo::Ops::Service;
    require Odoo::Ops::Registry;
    require Odoo::Ops::Pack;
    if ( !$self->{foreground} ) {
        pipe( my $r, my $w ) or Odoo::Error->throw( kind => 'fault', message => "oomd: pipe: $!" );
        my $pid = fork;
        Odoo::Error->throw( kind => 'fault', message => "oomd: cannot fork: $!" ) if !defined $pid;
        if ($pid) {
            close $w;
            my $got = <$r>;
            waitpid( $pid, POSIX::WNOHANG() );
            if ( defined $got && $got =~ /\Aready\n/ ) {
                STDOUT->autoflush(1);
                print "oomd $o{name} ready $p->{socket}\n";
                return 0;
            }
            print STDERR "oomd: $o{name} did not start; see $p->{log}\n";
            return 1;
        }
        close $r;
        POSIX::setsid();
        $self->{ready_fd} = $w;
        $self->_detach;
    }
    return $self->_serve;
}

sub _alive ($pid) { return $pid && $pid =~ /\A\d+\z/ && ( kill( 0, $pid ) || $!{EPERM} ) ? 1 : 0 }

sub _refuse_if_running ($self) {
    my $p = $self->{paths};
    if ( open my $fh, '<', $p->{pid} ) {
        my @l = <$fh>;
        close $fh;
        chomp @l;
        Odoo::Error->throw( kind => 'refused', code => 'exists', message => "oomd $self->{name} is already running (pid $l[0])",
            fix => "stop it first, or give this daemon another name" )
            if _alive( $l[0] );
        unlink $p->{pid};
    }
    if ( -S $p->{socket} ) {
        my $probe = IO::Socket::UNIX->new( Peer => $p->{socket}, Type => SOCK_STREAM );
        Odoo::Error->throw( kind => 'refused', code => 'exists', message => "oomd $self->{name} is already running (its socket $p->{socket} answers)",
            fix => "stop it first, or give this daemon another name" )
            if $probe;
        unlink $p->{socket};
    }
    elsif ( -e $p->{socket} ) {
        Odoo::Error->throw( kind => 'config', message => "$p->{socket} exists and is not a socket" );
    }
    return;
}

sub _bind ($self) {
    my $p = $self->{paths};
    Odoo::Error->throw( kind => 'config', message => "the socket path $p->{socket} is too long for a unix socket (108 bytes at most)", fix => 'give a shorter socket = path, or a shorter name' )
        if length $p->{socket} >= 104;
    my $dir = dirname( $p->{socket} );
    Odoo::Error->throw( kind => 'config', message => "the socket directory $dir does not exist" ) if !-d $dir;
    my $old = umask 077;
    my $l = IO::Socket::UNIX->new( Local => $p->{socket}, Type => SOCK_STREAM, Listen => 128 );
    my $err = $!;
    umask $old;
    Odoo::Error->throw( kind => 'config', message => "cannot listen on $p->{socket}: $err" ) if !$l;
    chmod 0600, $p->{socket};
    $l->blocking(0);
    $self->{listen} = $l;
    return;
}

# a background daemon: standard streams go to /dev/null and the log, the pid file is its own
sub _detach ($self) {
    open STDIN, '<', '/dev/null';
    $self->_open_log;
    open STDOUT, '>>&', $self->{logfh};
    open STDERR, '>>&', $self->{logfh};
    return;
}

sub _open_log ($self) {
    my $path = $self->{paths}{log};
    my $old = umask 077;
    my $ok = sysopen( my $fh, $path, O_WRONLY | O_CREAT | O_APPEND, 0600 );
    umask $old;
    Odoo::Error->throw( kind => 'config', message => "cannot open the log $path: $!" ) if !$ok;
    chmod 0600, $path;
    $fh->autoflush(1);
    $self->{logfh} = $fh;
    return;
}

sub _claim_pid ($self) {
    my $p = $self->{paths};
    for ( 1 .. 3 ) {
        my $old = umask 077;
        my $ok = sysopen( my $fh, $p->{pid}, O_WRONLY | O_CREAT | O_EXCL, 0600 );
        umask $old;
        if ($ok) {
            print {$fh} "$$\n$p->{socket}\n$self->{name}\n";
            close $fh;
            $self->{pid_file} = $p->{pid};
            return;
        }
        if ( open my $fh2, '<', $p->{pid} ) {
            my @l = <$fh2>;
            close $fh2;
            chomp @l;
            Odoo::Error->throw( kind => 'refused', code => 'exists', message => "oomd $self->{name} is already running (pid $l[0])" ) if _alive( $l[0] ) && $l[0] != $$;
        }
        unlink $p->{pid};
    }
    Odoo::Error->throw( kind => 'config', message => "cannot write the pid file $p->{pid}" );
}

sub _log ($self, $text) {
    my $fh = $self->{logfh} or return;
    my $t = Odoo::Ops::iso_time( time );
    syswrite( $fh, "$t $text\n" );
    return;
}

sub _clean ($v) {
    return '-' if !defined $v || ref $v;
    return $v =~ /\A[\w.:\/@=-]{1,80}\z/ ? $v : '-';
}

# ---- the master loop -----------------------------------------------------------------------------------

sub _serve ($self) {
    my $p = $self->{paths};
    $self->_open_log if !$self->{logfh};
    $self->_claim_pid;
    $self->{t0}      = time;
    $self->{clients} = {};
    $self->{workers} = [];
    $self->{queue}   = [];
    $self->{stats}   = { served => 0, crashed => 0, recycled => 0 };
    $self->{deaths}  = [];
    my ( $TERM, $HUP ) = ( 0, 0 );
    local $SIG{TERM} = sub { $TERM = 1 };
    local $SIG{INT}  = sub { $TERM = 1 };
    local $SIG{HUP}  = sub { $HUP = 1 };
    local $SIG{PIPE} = 'IGNORE';
    local $SIG{CHLD} = 'DEFAULT';
    $self->_log( "start name=$self->{name} pid=$$ workers=$self->{conf}{workers} version=$Odoo::Ops::Version::VERSION" );
    $self->_spawn while @{ $self->{workers} } < $self->{conf}{workers};
    if ( $self->{ready_fd} ) {
        syswrite( $self->{ready_fd}, "ready\n" );
        close $self->{ready_fd};
        delete $self->{ready_fd};
    }
    else {
        STDOUT->autoflush(1);
        print "oomd $self->{name} ready $p->{socket}\n";
    }
    $self->_notify("READY=1\nMAINPID=$$\n");
    my $stop_at;
    while (1) {
        if ($HUP) { $HUP = 0; $self->_reload }
        if ( $TERM && !$self->{stopping} ) {
            $self->{stopping} = 1;
            $stop_at = Odoo::Ops::Daemon::_now() + $self->{conf}{deadline};
            $self->_begin_stop;
        }
        $self->_reap;
        $self->_dispatch;
        if ( $self->{stopping} ) {
            my $busy = grep { $_->{busy} } @{ $self->{workers} };
            my $pending = grep { length $_->{out} } values %{ $self->{clients} };
            last if !$busy && !$pending;
            if ( Odoo::Ops::Daemon::_now() > $stop_at ) {
                $self->_log('stop deadline passed; the requests still in hand are answered with a fault');
                $self->_kill_busy;
                $self->_flush_all;
                last;
            }
        }
        $self->_select_once;
    }
    $self->_finish;
    return 0;
}

sub _now () { Time::HiRes::time() }

sub _select_once ($self) {
    my ( $rin, $win ) = ( '', '' );
    my $l = $self->{listen};
    vec( $rin, fileno $l, 1 ) = 1 if $l && !$self->{stopping};
    for my $c ( values %{ $self->{clients} } ) {
        next if $c->{closed};
        vec( $rin, fileno $c->{sock}, 1 ) = 1 if !$c->{waiting} && !length $c->{out} && !$c->{eof};
        vec( $win, fileno $c->{sock}, 1 ) = 1 if length $c->{out};
    }
    for my $w ( @{ $self->{workers} } ) {
        vec( $rin, fileno $w->{sock}, 1 ) = 1;
        vec( $win, fileno $w->{sock}, 1 ) = 1 if length $w->{out};
    }
    my $n = select( my $rout = $rin, my $wout = $win, undef, 0.2 );
    return if !defined $n || $n <= 0;
    if ( $l && !$self->{stopping} && vec( $rout, fileno $l, 1 ) ) { $self->_accept }
    for my $w ( @{ $self->{workers} } ) {
        $self->_worker_write($w) if vec( $wout, fileno $w->{sock}, 1 ) && length $w->{out};
    }
    for my $w ( @{ $self->{workers} } ) {
        $self->_worker_read($w) if vec( $rout, fileno $w->{sock}, 1 );
    }
    for my $c ( values %{ $self->{clients} } ) {
        next if $c->{closed};
        $self->_client_write($c) if length $c->{out} && vec( $wout, fileno $c->{sock}, 1 );
        $self->_client_read($c)  if !$c->{waiting} && !length $c->{out} && !$c->{eof} && vec( $rout, fileno $c->{sock}, 1 );
    }
    # idle clients are let go; closed ones forgotten
    my $now = time;
    for my $k ( keys %{ $self->{clients} } ) {
        my $c = $self->{clients}{$k};
        if ( !$c->{closed} && !$c->{waiting} && !length $c->{out} && $now - $c->{last} > $CLIENT_IDLE ) { $c->{closed} = 1 }
        if ( ( $c->{closed} || ( $c->{eof} && $c->{in} !~ /\n/ ) ) && !$c->{waiting} && !length $c->{out} ) { close $c->{sock}; delete $self->{clients}{$k} }
    }
    return;
}

=head2 The peer

C<peer_uid($socket)> is the uid of the process at the other end of a connected
unix socket, read with C<getsockopt> and C<SO_PEERCRED> (core C<Socket>; Linux),
or undef where the platform gives no such option. The daemon refuses a peer whose
uid is not its own. The socket's file mode and directory already keep other users
out; this checks that nothing went wrong with them. It does not separate two
programs of the same user: they can open the socket and read the key files alike,
so the boundary between sites that must be kept apart is a different Unix user.

=cut

sub peer_uid ($class, $sock) {
    my $opt = eval { Socket::SO_PEERCRED() };
    return undef if !defined $opt;
    my $v = getsockopt( $sock, SOL_SOCKET, $opt );
    return undef if !defined $v || length $v < 12;
    my ( $pid, $uid ) = unpack 'iII', $v;
    return $uid;
}

# a peer of another uid is let go; where the uid cannot be read the file mode is the guard
sub _peer_ok ($self, $sock) {
    my $uid = $self->peer_uid($sock);
    return 1 if !defined $uid;
    return 1 if $uid == ( $self->{own_uid} // $< );
    $self->_log("refused a connection from uid $uid");
    $self->{stats}{refused_peers}++ if $self->{stats};
    return 0;
}

sub _accept ($self) {
    for ( 1 .. 32 ) {
        my $s = $self->{listen}->accept or last;
        if ( !$self->_peer_ok($s) ) { close $s; next }
        $s->blocking(0);
        $self->{clients}{ fileno $s } = { sock => $s, in => '', out => '', waiting => 0, closed => 0, last => time };
    }
    return;
}

sub _client_read ($self, $c) {
    my $n = sysread( $c->{sock}, $c->{in}, 1 << 20, length $c->{in} );
    if ( !defined $n ) { return if $! == EAGAIN || $! == EINTR; $c->{closed} = 1; return }
    if ( $n == 0 ) { $c->{eof} = 1; return }
    $c->{last} = time;
    if ( length $c->{in} > $MAX_LINE && $c->{in} !~ /\n/ ) {
        $self->_reply( $c, { id => undef, ok => JSON::PP::false, error => { kind => 'usage', code => 'usage', message => 'the request line is too long', fix => 'a request is one line of at most 64 MiB' } }, 'usage', undef, undef );
        $c->{in} = '';
        return;
    }
    $self->_take_request($c) if $c->{in} =~ /\n/;
    return;
}

sub _take_request ($self, $c) {
    $c->{in} =~ s/\A([^\n]*)\n// or return;
    my $line = $1;
    $c->{t0} = _now();
    my $req = eval { Odoo::Ops::json()->decode($line) };
    if ( ref $req ne 'HASH' ) {
        $self->_reply( $c, { id => undef, ok => JSON::PP::false, error => { kind => 'usage', code => 'usage', message => 'the request is not one JSON object', fix => 'send one JSON object per line' } }, 'usage', undef, undef );
        return;
    }
    $c->{id} = _clean( $req->{id} );
    $c->{req_id} = ref $req->{id} ? undef : $req->{id};
    $c->{op} = _clean( $req->{verb} // $req->{op} );
    if ( defined $req->{verb} ) {
        return $self->_reply( $c, { id => $req->{id}, ok => JSON::PP::true, result => $self->_health }, 'ok', $req->{id}, 'health' ) if $req->{verb} eq 'health';
        return $self->_reply( $c, { id => $req->{id}, ok => JSON::PP::false, error => { kind => 'usage', code => 'usage', message => "unknown verb '" . ( ref $req->{verb} ? '?' : $req->{verb} ) . "'", fix => 'the verb is health' } }, 'usage', $req->{id}, 'verb' );
    }
    if ( $self->{stopping} || @{ $self->{queue} } >= $MAX_QUEUE ) {
        my $why = $self->{stopping} ? "oomd $self->{name} is stopping" : "oomd $self->{name} has too many requests waiting";
        return $self->_reply( $c, { id => $req->{id}, ok => JSON::PP::false, error => { kind => 'transport', code => 'transport', message => $why, fix => 'try again shortly' } }, 'transport', $req->{id}, $req->{op} );
    }
    $c->{waiting} = 1;
    push @{ $self->{queue} }, { client => $c, line => $line };
    return;
}

# answer a client from the master itself (health, refusals before a worker)
sub _reply ($self, $c, $res, $outcome, $id, $op) {
    $c->{out} .= Odoo::Ops::json()->encode($res) . "\n";
    $c->{waiting} = 0;
    $self->_log_request( $c, $outcome );
    $self->_client_write($c);
    return;
}

sub _log_request ($self, $c, $outcome) {
    my $ms = int( ( _now() - ( $c->{t0} // _now() ) ) * 1000 );
    $self->_log( 'req=' . ( $c->{id} // '-' ) . ' op=' . ( $c->{op} // '-' ) . ' outcome=' . _clean($outcome) . " ms=$ms" );
    $self->{stats}{served}++;
    return;
}

sub _client_write ($self, $c) {
    return if !length $c->{out};
    my $n = syswrite( $c->{sock}, $c->{out}, length $c->{out} );
    if ( !defined $n ) { return if $! == EAGAIN || $! == EINTR; $c->{closed} = 1; $c->{out} = ''; return }
    substr( $c->{out}, 0, $n ) = '';
    $c->{last} = time;
    # a client that sent two requests in a row has its second taken once the first is answered
    $self->_take_request($c) if !length $c->{out} && $c->{in} =~ /\n/ && !$c->{closed};
    return;
}

sub _flush_all ($self) {
    for my $c ( values %{ $self->{clients} } ) {
        next if !length $c->{out};
        for ( 1 .. 50 ) { $self->_client_write($c); last if !length $c->{out} || $c->{closed}; Time::HiRes::sleep(0.01) }
    }
    return;
}

# ---- workers ---------------------------------------------------------------------------------------------

sub _spawn ($self) {
    socketpair( my $m, my $w, AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or Odoo::Error->throw( kind => 'fault', message => "oomd: socketpair: $!" );
    my $pid = fork;
    Odoo::Error->throw( kind => 'fault', message => "oomd: cannot fork a worker: $!" ) if !defined $pid;
    if ( !$pid ) {
        close $m;
        $self->_worker_main($w);
        POSIX::_exit(0);
    }
    close $w;
    $m->blocking(0);
    push @{ $self->{workers} }, { pid => $pid, sock => $m, in => '', out => '', busy => 0, retiring => 0, client => undef, born => time };
    return;
}

sub _worker_main ($self, $sock) {
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = 'IGNORE';
    $SIG{PIPE} = 'IGNORE';
    $SIG{CHLD} = 'DEFAULT';
    delete $ENV{NOTIFY_SOCKET};
    # the master's other handles are not this worker's
    close $self->{listen} if $self->{listen};
    for my $c ( values %{ $self->{clients} } ) { close $c->{sock} }
    for my $w ( @{ $self->{workers} } ) { close $w->{sock} }
    close $self->{logfh} if $self->{logfh};
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>',  '/dev/null';
    # a worker says nothing outside the protocol: a warning may hold a value
    open STDERR, '>',  '/dev/null';
    srand();
    require Odoo::Ops::Service;
    my $svc = Odoo::Ops::Service->new( config => $self->{conf}{config}, mode => 'daemon', credentials => $self->{conf}{credentials}, name => $self->{name}, act_as => $self->{conf}{act_as} );
    $sock->autoflush(1);
    my $served = 0;
    my $max    = $self->{conf}{max_requests};
    while ( defined( my $line = <$sock> ) ) {
        chomp $line;
        my ( $resp, $outcome ) = eval { $svc->serve_line($line) };
        if ( !defined $resp ) {
            $outcome = 'fault';
            $resp = Odoo::Ops::json()->encode( { id => undef, ok => JSON::PP::false, error => { kind => 'fault', code => 'fault', message => 'the worker could not answer', fix => undef } } );
        }
        undef $line;
        $served++;
        my $retire = $served >= $max ? 1 : 0;
        $outcome =~ s/[\t\n]/ /g;
        my $out = "$outcome\t$retire\t$resp\n";
        my $off = 0;
        while ( $off < length $out ) {
            my $n = syswrite( $sock, $out, length($out) - $off, $off );
            if ( !defined $n ) { next if $! == EINTR; POSIX::_exit(1) }
            $off += $n;
        }
        last if $retire;
    }
    POSIX::_exit(0);
}

sub _worker_write ($self, $w) {
    my $n = syswrite( $w->{sock}, $w->{out}, length $w->{out} );
    if ( !defined $n ) { return if $! == EAGAIN || $! == EINTR; return $self->_worker_gone($w) }
    substr( $w->{out}, 0, $n ) = '';
    return;
}

sub _worker_read ($self, $w) {
    my $n = sysread( $w->{sock}, $w->{in}, 1 << 20, length $w->{in} );
    if ( !defined $n ) { return if $! == EAGAIN || $! == EINTR; return $self->_worker_gone($w) }
    return $self->_worker_gone($w) if $n == 0;
    while ( $w->{in} =~ s/\A([^\t\n]*)\t([01])\t([^\n]*)\n// ) {
        my ( $outcome, $retire, $resp ) = ( $1, $2, $3 );
        my $c = delete $w->{client};
        $w->{busy} = 0;
        $w->{retiring} = 1 if $retire;
        if ( $c && !$c->{closed} ) {
            $c->{out} .= "$resp\n";
            $c->{waiting} = 0;
            $self->_log_request( $c, $outcome );
            $self->_client_write($c);
        }
        elsif ($c) {
            $c->{waiting} = 0;
            $self->_log_request( $c, $outcome );
        }
        $w->{served}++;
        $self->_retire_idle($w) if $w->{retiring} && !$w->{busy};
    }
    return;
}

# a worker that will serve no more: its end is closed, it exits, a new one takes its place
sub _retire_idle ($self, $w) {
    close $w->{sock};
    $w->{closed} = 1;
    $self->_remove_worker( $w, 'recycled' );
    return;
}

sub _worker_gone ($self, $w) {
    return if $w->{closed};
    close $w->{sock};
    $w->{closed} = 1;
    my $busy = $w->{busy};
    my $died = $busy || !$w->{retiring};
    if ( !$busy && $died ) {
        $self->{stats}{crashed}++;
        $self->_log("worker pid=$w->{pid} died");
    }
    if ($busy) {
        my $c = delete $w->{client};
        $self->{stats}{crashed}++;
        $self->_log("worker pid=$w->{pid} died with a request in hand");
        if ( $c && !$c->{closed} ) {
            my $res = { id => ( $c->{req_id} // undef ), ok => JSON::PP::false,
                error => { kind => 'transport', code => 'transport', message => "oomd $self->{name}: the worker that held this request died; the request may or may not have been done", fix => 'read what is true (oom-ops runs, show) before asking again' } };
            $c->{out} .= Odoo::Ops::json()->encode($res) . "\n";
            $c->{waiting} = 0;
            $self->_log_request( $c, 'transport' );
            $self->_client_write($c);
        }
        elsif ($c) { $c->{waiting} = 0 }
    }
    $self->_remove_worker( $w, $died ? 'crashed' : 'recycled' );
    return;
}

sub _remove_worker ($self, $w, $why) {
    $self->{workers} = [ grep { $_ != $w } @{ $self->{workers} } ];
    $self->{stats}{recycled}++ if $why eq 'recycled';
    return if $self->{stopping};
    my $now = time;
    $self->{deaths} = [ grep { $now - $_ < 5 } @{ $self->{deaths} }, ( $why eq 'crashed' ? $now : () ) ];
    if ( @{ $self->{deaths} } > 10 ) {
        $self->_log('workers are dying faster than they start; waiting before replacing them');
        Time::HiRes::sleep(1);
        $self->{deaths} = [];
    }
    $self->_spawn while grep( { !$_->{retiring} } @{ $self->{workers} } ) < $self->{conf}{workers};
    return;
}

sub _reap ($self) {
    while ( ( my $pid = waitpid( -1, POSIX::WNOHANG() ) ) > 0 ) {
        # the exit is accounted for where the socket shows it, after the last answer has been read
    }
    return;
}

sub _dispatch ($self) {
    while ( @{ $self->{queue} } ) {
        my ($w) = grep { !$_->{busy} && !$_->{retiring} && !$_->{closed} } @{ $self->{workers} };
        last if !$w;
        my $job = shift @{ $self->{queue} };
        my $c = $job->{client};
        next if $c->{closed} && do { $c->{waiting} = 0; 1 };
        $w->{busy}   = 1;
        $w->{client} = $c;
        $w->{out}   .= "$job->{line}\n";
        $self->_worker_write($w);
        $job->{line} = '';
    }
    return;
}

sub _kill_busy ($self) {
    for my $w ( grep { $_->{busy} } @{ $self->{workers} } ) {
        kill 'KILL', $w->{pid};
        waitpid( $w->{pid}, 0 );
        $self->_worker_gone($w);
    }
    return;
}

# ---- reload, stop, health ------------------------------------------------------------------------------------

sub _reload ($self) {
    my $new = eval { ref($self)->load_config( $self->{name}, $self->{conf_path} ) };
    if ( !$new ) {
        $self->_log( 'reload refused: ' . ( "$@" =~ s/\s+\z//r ) );
        return;
    }
    my ( $a, $b ) = ( $self->{conf}{config}, $new->{config} );
    if ( ( $a->get('url') =~ s{/+\z}{}r ) ne ( $b->get('url') =~ s{/+\z}{}r ) || $a->get('db') ne $b->get('db') ) {
        $self->_log('reload refused: a daemon serves one instance; start another daemon for a different one');
        return;
    }
    $self->_log('the socket cannot change on a reload; restart for that') if ( $new->{socket} // '' ) ne ( $self->{conf}{socket} // '' );
    $new->{socket} = $self->{conf}{socket};
    $new->{log}    = $self->{conf}{log};
    $self->{conf}  = $new;
    # new workers read the new config and the packs as they now are; the old ones finish what they hold
    for my $w ( @{ $self->{workers} } ) {
        $w->{retiring} = 1;
        $self->_retire_idle($w) if !$w->{busy};
    }
    $self->_spawn while grep( { !$_->{retiring} } @{ $self->{workers} } ) < $self->{conf}{workers};
    $self->_log("reloaded workers=$new->{workers}");
    return;
}

# systemd's sd_notify, in the few lines it needs and with no module: a supervisor that set NOTIFY_SOCKET is told
# when the socket accepts and when the daemon begins to stop
sub _notify ($self, $text) {
    my $path = $ENV{NOTIFY_SOCKET};
    return if !defined $path || !length $path || $path !~ m{\A[/@]};
    $path =~ s/\A@/\0/;
    socket( my $s, AF_UNIX, SOCK_DGRAM, 0 ) or return;
    send( $s, $text, 0, pack_sockaddr_un($path) );
    close $s;
    return;
}

sub _begin_stop ($self) {
    $self->_log('stopping');
    $self->_notify("STOPPING=1\n");
    my $p = $self->{paths};
    close $self->{listen} if $self->{listen};
    delete $self->{listen};
    unlink $p->{socket};
    # requests not yet with a worker are told, not dropped
    for my $job ( @{ $self->{queue} } ) {
        my $c = $job->{client};
        $c->{out} .= Odoo::Ops::json()->encode( { id => undef, ok => JSON::PP::false, error => { kind => 'transport', code => 'transport', message => "oomd $self->{name} is stopping", fix => 'try again when it is back' } } ) . "\n";
        $c->{waiting} = 0;
        $self->_log_request( $c, 'transport' );
        $self->_client_write($c);
    }
    $self->{queue} = [];
    for my $w ( @{ $self->{workers} } ) {
        $w->{retiring} = 1;
        $self->_retire_idle($w) if !$w->{busy};
    }
    return;
}

sub _finish ($self) {
    my $p = $self->{paths};
    for my $w ( @{ $self->{workers} } ) { close $w->{sock} unless $w->{closed}; $w->{closed} = 1 }
    my $until = _now() + 3;
    while ( _now() < $until ) {
        my $any = 0;
        for my $w ( @{ $self->{workers} } ) { $any++ if waitpid( $w->{pid}, POSIX::WNOHANG() ) == 0 }
        last if !$any;
        Time::HiRes::sleep(0.05);
    }
    for my $w ( @{ $self->{workers} } ) { if ( kill( 0, $w->{pid} ) ) { kill 'KILL', $w->{pid}; waitpid( $w->{pid}, 0 ) } }
    unlink $p->{socket} if -S $p->{socket};
    unlink $p->{pid};
    $self->_log("stopped served=$self->{stats}{served}");
    return;
}

sub _health ($self) {
    my @w = @{ $self->{workers} };
    my %packs;
    my @refused;
    my $d = eval { Odoo::Ops::Pack->discover( [ $self->{conf}{config}->pack_dirs ], only => [ $self->{conf}{config}->pack_only ] ) };
    if ($d) {
        $packs{$_} = { version => $d->{packs}{$_}{version}, oom_min => $d->{packs}{$_}{oom_min} } for keys %{ $d->{packs} };
        @refused = map { $_->{name} } @{ $d->{refused} };
    }
    my $c = $self->{conf}{config};
    return {
        name      => $self->{name},
        version   => $Odoo::Ops::Version::VERSION,
        pid       => $$,
        uptime    => time - $self->{t0},
        instance  => { url => ( $c->get('url') =~ s{/+\z}{}r ), db => $c->get('db') },
        socket    => $self->{paths}{socket},
        workers   => { total => scalar @w, busy => scalar( grep { $_->{busy} } @w ), idle => scalar( grep { !$_->{busy} } @w ),
            pids => [ sort { $a <=> $b } map { $_->{pid} } @w ], max_requests => $self->{conf}{max_requests} },
        requests  => { %{ $self->{stats} } },
        packs     => \%packs,
        packs_refused => \@refused,
        credentials => [ 'conn', sort grep { $_ ne 'conn' } keys %{ $self->{conf}{credentials} } ],
    };
}

1;
