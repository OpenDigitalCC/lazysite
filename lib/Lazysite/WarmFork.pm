package Lazysite::WarmFork;

# SM1226 (SM1082 C3, R3; SM1164 D5): THE ODOO ENDPOINT, WARM-FORKED.
#
# The release manager, 2026-10-20: "D5 - yes - i cant see why we would not want to
# save 200ms." Every Odoo call started a fresh lazysite-odoo.pl: a perl, then the
# endpoint's modules compiled, then the work. This is a PARENT that has compiled
# the endpoint and its modules once and, for each request, forks a FRESH child
# that runs the endpoint exactly as the CGI does and then exits.
#
# WHAT THE PARENT HOLDS: CODE, AND NOTHING ELSE. It requires the endpoint script
# and the modules the endpoint loads (preload), binds its socket, and from then on
# does three things: accept a connection, fork, close its copy of the connection.
# It never reads a byte of a request - the child reads the parameters, the cookies
# and the body off the connection itself - so no visitor's session, token, Odoo
# session or password is ever in the parent to be inherited by the next child. It
# reads no configuration and no key: the child reads the site's config, as a CGI
# does, on each request. t/lint/272 classifies every file-scope variable of what
# the parent loads, and t/integration/325 reads the parent's memory after it has
# served signed-in requests and finds none of them in it.
#
# WHAT THE CHILD IS: CGI's isolation. %ENV is the request's parameters and only
# those (the CGI environment contract); the identity variables a front end could
# carry as parameters (the auth wrapper's sentinel, sid and passwordless flag, and
# the six trust headers) are cleared first, though the endpoint reads none of them:
# it verifies its own caller from the session cookie (SM411), as it does as a CGI.
# STDIN is the request's body, read from the connection only as far as the
# endpoint reads it (its own caps refuse a body before reading it, SM1162), STDOUT
# is collected and sent back. The random generator is reseeded (a forked child
# would otherwise repeat its siblings' rand()), and the Timing `load` phase starts
# at the fork. When the endpoint returns, the child exits; nothing it held
# survives into the next request, which is a different process.
#
# THE WIRE IS FastCGI's responder role, one request per connection
# (Lazysite::WarmFork::Wire), so a web server can connect as well as the pool's
# front door can.
#
# RESTARTED ON UPGRADE. Every few seconds the parent looks at the files it loaded;
# when one has changed and stayed changed for two seconds, it stops listening and
# exits 75, and its service (Lazysite::Daemon::Service::OdooEndpoint, under
# lazysited, as oomd is) starts a new one. Requests in flight finish in their own
# children. A parent whose service has gone (it is re-parented) exits too.
#
# RUN AS A PROGRAM by its service:
#   perl -I LIB lib/Lazysite/WarmFork.pm --docroot D --script S --socket P
use strict;
use warnings;
use Socket                   qw(AF_UNIX SOCK_STREAM SOMAXCONN sockaddr_un);
use IO::Select               ();
use POSIX                    ();
use Lazysite::WarmFork::Wire ();

our $VERSION = '0.1';

sub EXIT_UPGRADE () { return 75 }    # EX_TEMPFAIL: "start me again", never a failure

# A test replaces these.
our $MAX_CHILDREN = 32;              # requests at once; past it the backlog waits
# Seconds a child may take: the endpoint's work, an oomd or Odoo call included, as the
# pool's RELAY_TIMEOUT bounds a relayed one. Longer under Devel::Cover (SM763), which
# makes the child's own work several times slower.
our $REQUEST_TIMEOUT = ( ( $ENV{PERL5OPT} // '' ) =~ /Devel::Cover/ ) ? 600 : 120;
our $CHECK_EVERY = 5;        # seconds between looks at the loaded files
our $SETTLE      = 2;        # a change must hold this long (an upgrade copies many files)
our $MAX_PARAMS  = 1_048_576;

# THE OOM CLIENT the endpoint's daemon path uses (SM1164 D3), and what it reads a
# binding's declaration with. Code only; each is skipped when absent (the in-process
# path, or no OOM at all).
our @OOM_PRELOAD = qw(
    Odoo::Ops
    Odoo::Ops::Version
    Odoo::Ops::Client::Daemon
    Odoo::Ops::Registry
    Odoo::Ops::Operation
    Odoo::Ops::Context
    Odoo::Ops::Config
);

# --- the parent's code ----------------------------------------------------------

# Loaded first and always: what the CHILD calls before the endpoint runs (the
# identity clear, the Timing fork mark) and the log line. A child that cannot call
# them dies before it answers, so a missing module fails closed.
our @ALWAYS = qw(Lazysite::Auth::Identity Lazysite::Timing Lazysite::Util);

# The endpoint and every Lazysite:: module it names, and those modules' own, by
# `use` or `require`, read from the source: what a request would load on its way,
# loaded here once. Nothing is called: requiring a module compiles it and runs its
# file-scope initialisers, which t/lint/272 holds to constants. Returns
# ( \@loaded, \@skipped, $error ), $error when the endpoint itself did not compile.
sub preload {
    my ($script) = @_;
    my ( @loaded, @skipped );
    {
        package main;    ## no critic (Modules::ProhibitMultiplePackages)
        local $@;
        eval { require $script; 1 } or return ( [], [], "$script: $@" );
    }
    my @queue = ( @ALWAYS, _names( _slurp($script) ) );
    my %seen;
    while ( defined( my $m = shift @queue ) ) {
        next if $seen{$m}++;
        ( my $f = "$m.pm" ) =~ s{::}{/}g;
        local $@;
        if ( eval { require $f; 1 } ) { push @loaded, $m; push @queue, _names( _slurp( $INC{$f} ) ) }
        else                          { push @skipped, $m }
    }
    for my $m (@OOM_PRELOAD) {
        ( my $f = "$m.pm" ) =~ s{::}{/}g;
        local $@;
        if   ( eval { require $f; 1 } ) { push @loaded,  $m }
        else                            { push @skipped, $m }
    }
    return ( \@loaded, \@skipped, undef );
}

sub _slurp {
    my ($f) = @_;
    return '' unless defined $f && open my $fh, '<:raw', $f;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

# The Lazysite:: modules a source names by `use` or `require`, comments and pod
# aside.
sub _names {
    my ($t) = @_;
    $t        =~ s/^__END__.*//ms;
    $t        =~ s/^=\w+.*?^=cut\s*$//msg;
    $t        =~ s/^\s*#.*$//mg;
    return $t =~ /\b(?:use|require)\s+(Lazysite::[\w:]+)/g;
}

# What the parent compiled, as it is on disk now: a change is an upgrade.
sub code_signature {
    my (@extra) = @_;
    my %f = map { $_ => 1 } grep { defined && !ref && m{\A/} } ( values %INC, @extra );
    return join ';', map { my @s = stat $_; @s ? "$_:$s[1]:$s[7]:$s[9]" : "$_:-" } sort keys %f;
}

# --- the parent's loop ----------------------------------------------------------

sub _log {
    my ( $level, $msg, %kv ) = @_;
    if ( defined &Lazysite::Util::log_event ) { Lazysite::Util::log_event( $level, 'warm-fork', $msg, %kv ); return }
    print STDERR "[warm-fork] $level $msg " . join( ' ', map { "$_=$kv{$_}" } sort keys %kv ) . "\n";
    return;
}

sub _listen {
    my ($path) = @_;
    if ( -e $path ) {
        # a parent that still answers on it is another parent, not a stale file
        if ( socket( my $t, AF_UNIX, SOCK_STREAM, 0 ) ) {
            return ( undef, 'another warm-fork parent answers on the socket' ) if connect( $t, sockaddr_un($path) );
        }
        unlink $path or return ( undef, "cannot remove the stale socket: $!" );
    }
    socket( my $l, AF_UNIX, SOCK_STREAM, 0 ) or return ( undef, "socket: $!" );
    my $um = umask 077;
    my $ok = bind( $l, sockaddr_un($path) );
    umask $um;
    return ( undef, "bind $path: $!" ) unless $ok;
    chmod 0600, $path;
    listen( $l, SOMAXCONN ) or return ( undef, "listen: $!" );
    return ($l);
}

sub serve {
    my (%o) = @_;
    my ( $script, $path ) = @o{qw(script socket)};
    my ( $loaded, $skipped, $error ) = preload($script);
    return _fail("the endpoint did not load: $error") if defined $error;
    _log( 'INFO', 'preload skipped a module that did not load', modules => join( ',', @$skipped ) ) if @$skipped;

    my ( $l, $why ) = _listen($path);
    return _fail($why) unless $l;
    my $ino = ( stat $path )[1];

    my ( $term, %kids ) = (0);
    local $SIG{TERM} = sub { $term = 1 };
    local $SIG{INT}  = sub { $term = 1 };
    local $SIG{HUP}  = 'IGNORE';    # nothing to reload: the child reads the config
    local $SIG{PIPE} = 'IGNORE';
    local $SIG{CHLD} = 'DEFAULT';

    my $sig     = code_signature($script);
    my $ppid    = getppid();
    my $checked = time;
    my ( $changed, $changed_at );
    $| = 1;
    print STDOUT "lazysite-warm-fork ready $path\n";
    _log( 'INFO', 'warm-fork parent ready', socket => $path, modules => scalar @$loaded );

    my $sel = IO::Select->new($l);
    my $rc  = 0;
    while ( !$term ) {
        while ( ( my $k = waitpid( -1, POSIX::WNOHANG() ) ) > 0 ) { delete $kids{$k} }
        if ( getppid() != $ppid ) { _log( 'WARN', 'the service that started this parent is gone; stopping' ); last }
        if ( time - $checked >= $CHECK_EVERY ) {
            $checked = time;
            my $now = code_signature($script);
            if ( $now eq $sig ) { $changed = undef }
            elsif ( !defined $changed || $now ne $changed ) { ( $changed, $changed_at ) = ( $now, time ) }
            elsif ( time - $changed_at >= $SETTLE ) {
                _log( 'INFO', 'the engine changed on disk; restarting the warm-fork parent' );
                $rc = EXIT_UPGRADE;
                last;
            }
        }
        if ( keys %kids >= $MAX_CHILDREN ) { select undef, undef, undef, 0.02; next } ## no critic (ProhibitSleepViaSelect)
        next unless $sel->can_read(1);
        accept( my $c, $l ) or next;
        my $pid = fork();
        if ( !defined $pid ) { _log( 'ERROR', 'fork failed', error => "$!" ); close $c; next }
        if ( $pid == 0 ) {
            close $l;
            _child($c);    # never returns
        }
        $kids{$pid} = 1;
        close $c;          # the parent's copy: the child owns the connection
    }
    close $l;
    unlink $path if ( ( stat $path )[1] // -1 ) == $ino;
    _log( 'INFO', 'warm-fork parent stopped', ( $rc ? ( exit => $rc ) : () ) );
    return $rc;
}

sub _fail {
    my ($why) = @_;
    _log( 'ERROR', 'warm-fork parent not started', reason => $why );
    print STDERR "lazysite-warm-fork: $why\n";
    return 1;
}

# --- the child ------------------------------------------------------------------
#
# Everything below runs only in a forked child, after the fork, and ends with
# _exit: no END block, no buffer and no destructor of the parent runs here.

sub _read_exact {
    my ( $c, $n ) = @_;
    my $buf = '';
    while ( length $buf < $n ) {
        my $r = sysread( $c, $buf, $n - length $buf, length $buf );
        return undef unless $r;
    }
    return $buf;
}

# ( type, content, id ) or () at the end of the connection.
sub read_record {
    my ($c) = @_;
    my $h = _read_exact( $c, 8 ) // return;
    my ( $ver, $type, $id, $clen, $plen ) = unpack 'CCnnC', $h;
    return unless $ver == 1;
    my $body = _read_exact( $c, $clen + $plen ) // return;
    return ( $type, substr( $body, 0, $clen ), $id );
}

sub _send {
    my ( $c, $data ) = @_;
    my $o = 0;
    while ( $o < length $data ) {
        my $n = syswrite( $c, $data, length($data) - $o, $o );
        return 0 unless $n;
        $o += $n;
    }
    return 1;
}

sub _end {
    my ( $c, $id, $status ) = @_;
    _send( $c, Lazysite::WarmFork::Wire::record( Lazysite::WarmFork::Wire::FCGI_END_REQUEST(),
            pack( 'NCx3', 0, $status // Lazysite::WarmFork::Wire::FCGI_REQUEST_COMPLETE() ), $id ) );
    return;
}

sub _child {
    my ($c) = @_;
    binmode $c;
    srand();    # a fresh random sequence: a fork repeats its parent's
    Lazysite::Timing::worker_started();
    $SIG{$_} = 'DEFAULT' for qw(TERM INT HUP CHLD PIPE);
    $SIG{ALRM} = sub { POSIX::_exit(1) };
    alarm $REQUEST_TIMEOUT;
    my $W = 'Lazysite::WarmFork::Wire';

    # BEGIN_REQUEST, then the parameters to their empty record. A management
    # record (id 0) is answered as having nothing; any other role is refused.
    my ( $id, $params ) = ( undef, '' );
    while (1) {
        my ( $type, $content, $rid ) = read_record($c);
        POSIX::_exit(0) unless defined $type;
        if ( $rid == 0 ) {
            _send( $c, $W->can('record')->( $type == $W->FCGI_GET_VALUES ? $W->FCGI_GET_VALUES_RESULT : $W->FCGI_UNKNOWN_TYPE,
                    $type == $W->FCGI_GET_VALUES ? '' : pack( 'Cx7', $type ), 0 ) );
            next;
        }
        if ( $type == $W->FCGI_BEGIN_REQUEST ) {
            my ($role) = unpack 'n', $content;
            if ( $role != $W->FCGI_RESPONDER ) { _end( $c, $rid, $W->FCGI_UNKNOWN_ROLE ); POSIX::_exit(0) }
            $id = $rid;
            next;
        }
        POSIX::_exit(0) if $type == $W->FCGI_ABORT_REQUEST || !defined $id;
        next unless $type == $W->FCGI_PARAMS;
        last unless length $content;
        $params .= $content;
        POSIX::_exit(1) if length $params > $MAX_PARAMS;
    }
    my ($env) = Lazysite::WarmFork::Wire::parse_nv($params);
    POSIX::_exit(1) unless $env;

    # THE CGI CONTRACT: the environment is the request's, and only the request's.
    %ENV = %$env;
    Lazysite::Auth::Identity::clear_identity_env(undef); # dies, so answers nothing, if it is absent

    my $out = '';
    my $ok;
    {
        local *STDIN;
        tie *STDIN, 'Lazysite::WarmFork::Stdin', $c, $id;
        local *STDOUT;
        open STDOUT, '>', \$out or POSIX::_exit(1);
        $ok = eval { main::main(); 1 };
        my $err = $@;
        close STDOUT;
        untie *STDIN;
        if ( !$ok ) {
            _log( 'ERROR', 'the endpoint died', error => ( split /\n/, $err // '' )[0] // '' );
        }
    }
    $out = "Status: 500 Internal Server Error\r\nContent-Type: application/json; charset=utf-8\r\n"
        . "Cache-Control: no-store\r\n\r\n" . '{"error":"the endpoint failed","ok":0}'
        unless length $out;
    _send( $c, Lazysite::WarmFork::Wire::stream( $W->FCGI_STDOUT, $out, $id ) );
    _end( $c, $id );
    close $c;
    POSIX::_exit(0);
}

# STDIN in the child: the request's FCGI_STDIN stream, read off the connection as
# the endpoint reads it.
package Lazysite::WarmFork::Stdin;    ## no critic (Modules::ProhibitMultiplePackages)

sub TIEHANDLE { my ( $class, $c, $id ) = @_; return bless { c => $c, id => $id, buf => '', eof => 0 }, $class }

sub _fill {
    my ( $s, $want ) = @_;
    while ( !$s->{eof} && ( !defined $want || length $s->{buf} < $want ) ) {
        my ( $type, $content ) = Lazysite::WarmFork::read_record( $s->{c} );
        if ( !defined $type ) { $s->{eof} = 1; last }
        POSIX::_exit(0) if $type == Lazysite::WarmFork::Wire::FCGI_ABORT_REQUEST();
        next unless $type == Lazysite::WarmFork::Wire::FCGI_STDIN();
        if ( length $content ) { $s->{buf} .= $content }
        else                   { $s->{eof} = 1 }
    }
    return;
}

sub READ {
    my ( $s, undef, $len, $off ) = @_;
    $off //= 0;
    $s->_fill($len);
    my $chunk = substr( $s->{buf}, 0, $len, '' );
    my $ref   = \$_[1];
    $$ref = '' unless defined $$ref;
    $$ref .= "\0" x ( $off - length $$ref ) if $off > length $$ref;
    substr( $$ref, $off, length($$ref) - $off, $chunk );
    return length $chunk;
}

sub READLINE {
    my ($s) = @_;
    if ( !defined $/ ) { $s->_fill(undef); my $all = $s->{buf}; $s->{buf} = ''; return length $all ? $all : undef }
    while (1) {
        my $i = index( $s->{buf}, $/ );
        return substr( $s->{buf}, 0, $i + length $/, '' ) if $i >= 0;
        last                                              if $s->{eof};
        $s->_fill( length( $s->{buf} ) + 1 );
    }
    my $rest = $s->{buf};
    $s->{buf} = '';
    return length $rest ? $rest : undef;
}

sub EOF     { my ($s) = @_; $s->_fill(1); return length $s->{buf} ? 0 : 1 }
sub BINMODE { return 1 }
sub CLOSE   { return 1 }
sub FILENO  { return undef }

package Lazysite::WarmFork;    ## no critic (Modules::ProhibitMultiplePackages)

# --- as a program -----------------------------------------------------------------

sub main {
    my (@argv) = @_;
    my %o;
    for ( my $i = 0; $i < @argv; $i++ ) {
        $o{$1} = $argv[ ++$i ] if $argv[$i] =~ /\A--(docroot|script|socket|check-every|settle)\z/;
    }
    # a test's: how often the loaded files are looked at, and how long a change must hold
    $CHECK_EVERY = $o{'check-every'} if ( $o{'check-every'} // '' ) =~ /\A\d+\z/;
    $SETTLE      = $o{settle}        if ( $o{settle}        // '' ) =~ /\A\d+\z/;
    for (qw(docroot script socket)) {
        next if defined $o{$_} && length $o{$_};
        print STDERR "lazysite-warm-fork: --$_ is required\n";
        return 2;
    }
    # The docroot is the site's, the same for every request, and is what the
    # endpoint's lib search reads at compile time (as a CGI's environment has it).
    $ENV{DOCUMENT_ROOT} = $o{docroot};
    return serve(%o);
}

exit main(@ARGV) unless caller;

1;
