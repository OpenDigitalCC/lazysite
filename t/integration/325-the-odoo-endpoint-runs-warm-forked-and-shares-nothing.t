#!/usr/bin/perl
# SM1226 (SM1082 C3, R3; SM1164 D5): THE ODOO ENDPOINT RUNS WARM-FORKED, AND NO
# VISITOR'S IDENTITY OR CREDENTIAL REACHES THE NEXT REQUEST OR THE PARENT.
#
# The release manager, 2026-10-20: "D5 - yes - i cant see why we would not want to
# save 200ms." The trade-off note it answered: a preloaded parent forks a fresh
# child per request; "the parent must load code and configuration ONLY - no Odoo
# sessions, API keys or per-person data - enforced by a test".
#
# THE ARRANGEMENT is a production one, end to end: ONE pool worker with the front
# door on (the one-rule pool), the Odoo endpoint's warm-fork parent started by its
# lazysited service, and the real oomd from the vendored OOM against OOM's fake
# Odoo (SM1164; never a real Odoo, never the host's OOM). The cgi-bin's
# lazysite-odoo.pl is a shim that records each run and execs the real endpoint,
# so "warm" is read from what ran: a request the parent answered ran no CGI.
#
# What is held:
#   - the endpoint is answered by the parent's child, through the pool, with no
#     CGI run; with the parent stopped, by the CGI, as before (the fallback);
#   - one visitor after another (alice, an anonymous visitor, bob, alice) each see
#     only themselves - the SM1169 / SM1181 T1 shape;
#   - identity cannot be forged into the child: X-Remote-User and the wrapper's
#     sentinel, sid and flag sent as FastCGI parameters (SM1181 S2/S4's cases),
#     with no cookie and with another account's, through the pool and straight to
#     the parent's socket;
#   - the PARENT'S MEMORY, read from /proc after it has served those requests,
#     holds none of the site's secrets, the Odoo key, a session cookie's
#     signature, a token it handed out or a parameter a visitor sent - and does
#     hold the docroot it was started with, so the reading is a reading.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough grant_caps);
use MiniFcgi   qw(fcgi_request);
use OdooTest   qw(oom_or_skip bind set_key);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };
BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Odoo ();
use Lazysite::WarmFork::Wire                ();
use Lazysite::Daemon::Service::Oomd         ();
use Lazysite::Daemon::Service::OdooEndpoint ();

my $root = repo_root();
oomd_env();
my $d = oomd_site();
( my $base = $d ) =~ s{/public_html\z}{};
my $LZ = "$d/lazysite";

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }
sub hex_marker { my ($tag) = @_; return $tag . join( '', map { ( 0 .. 9, 'a' .. 'f' )[ rand 16 ] } 1 .. 24 ) }

# THE MARKERS: values that are in the site's files or in requests, and that the
# parent must never hold.
my $SECRET   = hex_marker('SITESECRET') x 2;
my $ODOO_KEY = hex_marker('ODOOKEY');
my $ECHO     = hex_marker('ECHOPARAM');
set_key( $d, $ODOO_KEY );
spit( "$LZ/auth/.secret", "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", "alice:x\nbob:x\n" );
grant_caps( $d, 'alice' ); # each in a group of their own, which the members' binding names
grant_caps( $d, 'bob' );
open my $conf, '>>', "$LZ/lazysite.conf" or die;
print {$conf} "server_timing: on\n";
close $conf;

$Lazysite::Odoo::DOCROOT = $d;
bind( $d, id => 'who', operation => 'oomd.pid', modes => 'public', params => 'e=echo' );
bind( $d, id => 'members', operation => 'oomd.pid', modes => 'authenticated', callers => 'role-alice,role-bob',
    params => 'e=echo' );

sub sid_for { return substr( hmac_sha256_hex( "sid-$_[0]", 'y' ), 0, 16 ) }
my %COOKIE;    # one per account for the whole file: the cookie sent is the one looked for

sub cookie_for {
    my ($user) = @_;
    return $COOKIE{$user} //= do {
        my $payload = join ':', $user, time(), sid_for($user), '';
        "lazysite_auth=$payload:" . hmac_sha256_hex( $payload, $SECRET );
    };
}
sub csrf_for { return hmac_sha256_hex( 'csrf:' . $_[0] . ':' . int( time() / 3600 ), $SECRET ) }

# --- the cgi-bin: a shim for the endpoint, so a CGI run is seen ---------------------
my $cgibin = "$base/cgi-bin";
my $RAN    = "$base/odoo-cgi-ran.log";
spit( "$cgibin/lazysite-odoo.pl", <<"PERL" );
#!/usr/bin/perl
open my \$fh, '>>', '$RAN' or die;
print {\$fh} ( \$ENV{QUERY_STRING} // '-' ), "\\n";
close \$fh;
exec \$^X, '$root/lazysite-odoo.pl';
PERL
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";

# --- oomd, the warm-fork parent, the pool -------------------------------------------
my $oomd = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
ok( wait_until( sub { oomd_up($d) }, 30 ), 'oomd is up' ) or BAIL_OUT('oomd did not start');

no warnings 'once';
$Lazysite::Daemon::Service::OdooEndpoint::SCRIPT = "$root/lazysite-odoo.pl";
my ($warm_sock) = Lazysite::WarmFork::Wire::socket_for($LZ);
sub warm_up {
    return 0 unless -S $warm_sock;
    socket( my $s, AF_UNIX, SOCK_STREAM, 0 ) or return 0;
    return connect( $s, sockaddr_un($warm_sock) ) ? 1 : 0;
}
my $warm = oomd_start( sub { Lazysite::Daemon::Service::OdooEndpoint::run( docroot => $d ) } );
ok( wait_until( \&warm_up, 30 ), 'the warm-fork parent is up, started by its service' )
    or BAIL_OUT('the warm-fork parent did not start');

my $sock = "$base/pool.sock";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
CORE::bind( $lsock, sockaddr_un($sock) ) or die "bind: $!"; # OdooTest exports its own bind
listen( $lsock, 5 )                      or die "listen: $!";
my $pool = fork() // die "fork: $!";
if ( $pool == 0 ) {
    %ENV = ( env_passthrough(), PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, LAZYSITE_FCGI_WORKERS => 1,
        LAZYSITE_FCGI_MAX_REQUESTS => 500, LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin );
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', "$base/worker-stderr.log" or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;
END { if ($pool) { kill 'TERM', $pool; waitpid $pool, 0 } }

# The server's environment the CGI fallback needs to find the vendored OOM, sent as
# parameters (a pool worker's environment is the request's).
my %OOM = map { $_ => $ENV{$_} } grep { defined $ENV{$_} }
    qw(PERL5LIB ODOO_OOM_PACK_DIRS ODOO_OOM_SHARE XDG_RUNTIME_DIR XDG_STATE_HOME XDG_CACHE_HOME);

# One endpoint request. Returns ( decoded body, raw response, the CGI runs it caused ).
sub odoo {
    my (%p)    = @_;
    my $to     = delete $p{to} // $sock;
    my $body   = delete $p{body};
    my $q      = delete $p{query} // 'csrf=1';
    my $ran0   = length slurp($RAN);
    my %params = ( %OOM,
        REQUEST_METHOD => ( defined $body ? 'POST'       : 'GET' ),
        CONTENT_LENGTH => ( defined $body ? length $body : 0 ),
        CONTENT_TYPE   => 'application/json',
        REMOTE_ADDR    => '198.51.100.1',
        HTTP_HOST      => 'site.test',
        DOCUMENT_ROOT  => $d,
        SCRIPT_NAME    => '/cgi-bin/lazysite-odoo.pl',
        REDIRECT_URL   => '/cgi-bin/lazysite-odoo.pl',
        REQUEST_URI    => "/cgi-bin/lazysite-odoo.pl?$q",
        QUERY_STRING   => $q,
        %p );
    my $out;
    if ( $to eq $sock ) { $out = fcgi_request( $sock, \%params, $body )->{stdout} // '' }
    else { $out = Lazysite::WarmFork::Wire::request( $to, \%params, $body, timeout => 30 )->{out} // '' }
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( ( eval { decode_json( $jb // '' ) } || {} ), $out, substr( slurp($RAN), $ran0 ) );
}
sub status_of { my ($raw) = @_; return ( $raw =~ /\AStatus:\s*(\d+)/ )[0] // 0 }

my @HANDED;    # tokens the endpoint handed out: none may be in the parent

subtest 'the endpoint is answered by the warm-fork parent, through the pool, with no CGI run' => sub {
    my ( $r, $raw, $ran ) = odoo();
    is( status_of($raw), 200, '?csrf=1 is answered' ) or diag $raw;
    ok( length( $r->{visitor_token} // '' ), 'with a visitor token' );
    is( $ran, '', 'and no CGI ran' );
    push @HANDED, $r->{visitor_token};
    ( $r, $raw, $ran ) = odoo( query => "binding=who&e=$ECHO" );
    ok( $r->{ok}, 'a binding call is answered' ) or diag $raw;
    is( $r->{report}{rows}[0]{echo}, $ECHO, '...by the operation, through oomd' );
    is( $ran,                        '',    '...with no CGI run' );
    like( $raw, qr/^Server-Timing:.*call;desc="oomd"/m, 'the call phase says oomd' );
    ( $r, $raw ) = odoo( query => "binding=who&e=second" );
    my $calls = Lazysite::Odoo::read_calls() || [];
    my %ids   = map { $_->{call_id} => 1 } grep { defined $_->{call_id} } @$calls[ 0, 1 ];
    is( scalar keys %ids, 2, 'two calls from two children record two different call ids' );
};

subtest 'one visitor after another: each sees only themselves' => sub {
    my @seq = ( [ alice => cookie_for('alice') ], [ anon => '' ], [ bob => cookie_for('bob') ], [ alice => cookie_for('alice') ] );
    for my $s (@seq) {
        my ( $who, $cookie ) = @$s;
        my ( $r,   $raw ) = odoo( ( length $cookie ? ( HTTP_COOKIE => $cookie ) : () ) );
        if ( $who eq 'anon' ) {
            ok( !exists $r->{token}, 'the anonymous visitor is given no session token' ) or diag $raw;
        }
        else {
            is( $r->{token}, csrf_for($who), "$who is given $who\'s own token" ) or diag $raw;
            push @HANDED, $r->{token};
        }
        my ( $m, $mraw ) = odoo( query => "binding=members&e=$who", ( length $cookie ? ( HTTP_COOKIE => $cookie ) : () ) );
        if ( $who eq 'anon' ) { ok( !$m->{ok}, 'and is refused the members\' binding' ) or diag $mraw }
        else { ok( $m->{ok}, "and $who may run the members' binding" ) or diag $mraw }
    }
};

my %FORGED = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins', LAZYSITE_AUTH_TRUSTED => 1,
    LAZYSITE_AUTH_SID => sid_for('alice'), LAZYSITE_AUTH_NO_PASSWORD => 1 );

for my $path ( [ 'through the pool' => $sock ], [ 'straight to the parent\'s socket' => $warm_sock ] ) {
    my ( $label, $to ) = @$path;
    subtest "a forged identity is nobody in the child ($label)" => sub {
        my ( $r, $raw, $ran ) = odoo( to => $to, %FORGED );
        is( status_of($raw), 200, 'the request is answered' ) or diag $raw;
        ok( !exists $r->{token}, 'X-Remote-User and the sentinel as parameters, no cookie: no session token' );
        my ($m) = odoo( to => $to, query => 'binding=members&e=x', %FORGED );
        ok( !$m->{ok}, '...and the members\' binding is refused' );
        my ($b) = odoo( to => $to, %FORGED, HTTP_COOKIE => cookie_for('bob') );
        is( $b->{token}, csrf_for('bob'), 'with bob\'s cookie it is bob, whatever the parameters say' );
        is( $ran, '',                     'no CGI ran' );
    };
}

# --- the parent's memory -------------------------------------------------------------
sub parent_pid {
    opendir my $p, '/proc' or return undef;
    for my $pid ( grep { /\A\d+\z/ } readdir $p ) {
        my $cmd = slurp("/proc/$pid/cmdline");
        return $pid if index( $cmd, 'Lazysite/WarmFork.pm' ) >= 0 && index( $cmd, "\0$d\0" ) >= 0;
    }
    return undef;
}

# The readable, writable mappings of a process: where a value it read or was given lives.
sub memory_holds {
    my ( $pid, @needles ) = @_;
    my %found;
    open my $maps, '<',     "/proc/$pid/maps" or return undef;
    open my $mem,  '<:raw', "/proc/$pid/mem"  or return undef;
    while ( my $l = <$maps> ) {
        my ( $from, $to, $perm ) = $l =~ /\A([0-9a-f]+)-([0-9a-f]+)\s+(\S+)/ or next;
        next unless $perm =~ /\Arw/;
        my ( $a, $b ) = ( hex $from, hex $to );
        next if $b - $a > 1 << 30;
        sysseek( $mem, $a, 0 ) or next;
        my $buf = '';
        my $n   = sysread( $mem, $buf, $b - $a );
        next unless $n;
        for my $x (@needles) { $found{$x} = 1 if index( $buf, $x ) >= 0 }
    }
    return \%found;
}

subtest 'the parent holds none of the secrets, keys, cookies, tokens or parameters it has seen pass' => sub {
    plan skip_all => 'this host does not let a process read its child\'s memory (ptrace_scope)'
        unless ( slurp('/proc/sys/kernel/yama/ptrace_scope') || '0' ) =~ /\A[01]/;
    my $pid = parent_pid();
    ok( $pid, 'the warm-fork parent is found' ) or return;
    my $alice_sig = ( cookie_for('alice') =~ /:([0-9a-f]{64})\z/ )[0];
    my %needles   = (
        'the docroot it was started with (the control)' => "$d",
        'the site\'s session secret'                    => $SECRET,
        'the Odoo connection key'                       => $ODOO_KEY,
        'a parameter a visitor sent'                    => $ECHO,
        'alice\'s cookie signature'                     => substr( $alice_sig, 0, 32 ),
        map { ( "a token it handed out ($_)" => $HANDED[$_] ) } grep { length( $HANDED[$_] // '' ) } 0 .. $#HANDED,
    );
    my $found = memory_holds( $pid, values %needles );
    ok( $found, 'its memory is read' ) or return;
    for my $what ( sort keys %needles ) {
        if ( $what =~ /control/ ) { ok( $found->{ $needles{$what} }, "it holds $what" ) }
        else { ok( !$found->{ $needles{$what} }, "it does not hold $what" ) }
    }
};

subtest 'with the parent stopped, the CGI answers as before' => sub {
    oomd_stop($warm);
    ok( wait_until( sub { !-e $warm_sock }, 10 ), 'the parent is gone' );
    my ( $r, $raw, $ran ) = odoo( HTTP_COOKIE => cookie_for('alice') );
    is( $r->{token}, csrf_for('alice'), 'alice is still alice' ) or diag $raw;
    like( $ran, qr/csrf=1/, 'answered by the CGI' );
};

oomd_stop($oomd);
done_testing;
