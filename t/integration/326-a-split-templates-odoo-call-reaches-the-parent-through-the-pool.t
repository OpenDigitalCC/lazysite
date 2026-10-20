#!/usr/bin/perl
# SM1226 S2 (ruled 2026-10-20, option a): ON THE SPLIT FASTCGI TEMPLATES THE ODOO
# ENDPOINT GOES TO THE POOL, AND THE POOL HANDS IT TO THE WARM-FORK PARENT.
#
# The release manager: "send /cgi-bin/lazysite-odoo.pl to the pool's socket and let
# the pool hand it to the warm-fork parent (nginx and Apache vhost-fcgi, the Hestia
# fcgi templates; plain CGI unchanged)." The split templates run no front door: the
# worker renders pages and nothing else, and every cgi-bin script went to fcgiwrap.
#
# THE ARRANGEMENT is t/integration/325's with the front door OFF, as a split
# template's pool runs: ONE pool worker, the endpoint's warm-fork parent started by
# its service, the real oomd from the vendored OOM against OOM's fake Odoo, and a
# cgi-bin shim for the endpoint that records every CGI run. Requests come in the
# two shapes the templates give them: nginx's (REDIRECT_URL is the path) and
# Apache's proxy handler (no REDIRECT_URL; REQUEST_URI with its query).
#
# What is held:
#   - each shipped split template routes the endpoint, and only it, to the pool;
#   - such a request is answered by the parent's child: no CGI ran;
#   - identity rules hold on that path: X-Remote-User and the wrapper's sentinel,
#     sid and flag as parameters are nobody, and a cookie is its own account;
#   - a page through the same worker still renders as a page;
#   - with the parent down, the worker runs the CGI and it answers.
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
        LAZYSITE_FCGI_MAX_REQUESTS => 500, LAZYSITE_CGIBIN => $cgibin ); # no front door: a split template's pool
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
    my $shape  = delete $p{shape} // 'nginx';
    my $ran0   = length slurp($RAN);
    my %params = ( %OOM,
        REQUEST_METHOD => ( defined $body ? 'POST'       : 'GET' ),
        CONTENT_LENGTH => ( defined $body ? length $body : 0 ),
        CONTENT_TYPE   => 'application/json',
        REMOTE_ADDR    => '198.51.100.1',
        HTTP_HOST      => 'site.test',
        DOCUMENT_ROOT  => $d,
        SCRIPT_NAME    => '/cgi-bin/lazysite-odoo.pl',
        REQUEST_URI    => "/cgi-bin/lazysite-odoo.pl?$q",
        QUERY_STRING   => $q,
        ( $shape eq 'nginx' ? ( REDIRECT_URL => '/cgi-bin/lazysite-odoo.pl' ) : () ),
        %p );
    my $out;
    if ( $to eq $sock ) { $out = fcgi_request( $sock, \%params, $body )->{stdout} // '' }
    else { $out = Lazysite::WarmFork::Wire::request( $to, \%params, $body, timeout => 30 )->{out} // '' }
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( ( eval { decode_json( $jb // '' ) } || {} ), $out, substr( slurp($RAN), $ran0 ) );
}
sub status_of { my ($raw) = @_; return ( $raw =~ /\AStatus:\s*(\d+)/ )[0] // 0 }

spit( "$d/index.md", "---\ntitle: Home\n---\nHOME BODY\n" );

subtest 'each split template sends the endpoint, and only it, to the pool' => sub {
    my $ng = slurp("$root/installers/nginx/vhost-fcgi.conf.example");
    like( $ng, qr!location = /cgi-bin/lazysite-odoo\.pl \{[^}]*fastcgi_pass unix:/run/lazysite/__DOMAIN__\.sock;!s,
        'nginx vhost-fcgi: an exact location for the endpoint, to the pool\'s socket' );
    my ($blk) = $ng =~ m!(location = /cgi-bin/lazysite-odoo\.pl \{[^}]*\})!s;
    like( $blk // '', qr/HTTP_X_REMOTE_USER\s+"";/, '...blanking the trust headers' );
    for my $f (qw(installers/apache/vhost-fcgi.conf.example installers/hestia/lazysite-fcgi.tpl installers/hestia/lazysite-fcgi.stpl)) {
        like( slurp("$root/$f"),
            qr{<Location "/cgi-bin/lazysite-odoo\.pl">\s*SetHandler "proxy:unix:/run/lazysite/(?:__DOMAIN__|%domain%)\.sock\|fcgi://localhost/"\s*</Location>},
            "$f: the endpoint's Location hands it to the pool's socket" );
    }
};

for my $shape (qw(nginx apache)) {
    subtest "the endpoint reaches the parent through a split template's pool ($shape)" => sub {
        my ( $r, $raw, $ran ) = odoo( shape => $shape );
        is( status_of($raw), 200, '?csrf=1 is answered' ) or diag $raw;
        ok( length( $r->{visitor_token} // '' ), 'with a visitor token' );
        is( $ran, '', 'and no CGI ran' );
        ( $r, $raw, $ran ) = odoo( shape => $shape, query => "binding=who&e=$ECHO" );
        ok( $r->{ok}, 'a binding call is answered' ) or diag $raw;
        is( $r->{report}{rows}[0]{echo}, $ECHO, '...by the operation, through oomd' );
        is( $ran,                        '',    '...with no CGI run' );
    };
}

my %FORGED = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins', LAZYSITE_AUTH_TRUSTED => 1,
    LAZYSITE_AUTH_SID => sid_for('alice'), LAZYSITE_AUTH_NO_PASSWORD => 1 );

subtest 'identity rules hold on that path: a forged identity is nobody, a cookie is its account' => sub {
    my ( $r, $raw, $ran ) = odoo(%FORGED);
    is( status_of($raw), 200, 'answered' ) or diag $raw;
    ok( !exists $r->{token}, 'X-Remote-User and the sentinel as parameters, no cookie: no session token' );
    my ($m) = odoo( query => 'binding=members&e=x', %FORGED );
    ok( !$m->{ok}, '...and the members\' binding is refused' );
    my ($b) = odoo( %FORGED, HTTP_COOKIE => cookie_for('bob') );
    is( $b->{token}, csrf_for('bob'), 'with bob\'s cookie it is bob, whatever the parameters say' );
    my ($a) = odoo( HTTP_COOKIE => cookie_for('alice') );
    is( $a->{token}, csrf_for('alice'), 'alice is alice' );
    my ($n) = odoo();
    ok( !exists $n->{token}, 'and the next anonymous visitor is nobody' );
    is( $ran, '', 'no CGI ran' );
};

subtest 'a page through the same worker is still a page' => sub {
    my $r = fcgi_request( $sock, { REQUEST_METHOD => 'GET', REDIRECT_URL => '/', REQUEST_URI => '/',
            DOCUMENT_ROOT => $d, HTTP_HOST => 'site.test', REMOTE_ADDR => '198.51.100.1' } );
    like( $r->{stdout} // '', qr/HOME BODY/, 'the home page renders' );
};

subtest 'with the parent stopped, the worker runs the CGI and it answers' => sub {
    oomd_stop($warm);
    ok( wait_until( sub { !-e $warm_sock }, 10 ), 'the parent is gone' );
    for my $shape (qw(nginx apache)) {
        my ( $r, $raw, $ran ) = odoo( shape => $shape, HTTP_COOKIE => cookie_for('alice') );
        is( $r->{token}, csrf_for('alice'), "$shape: alice is still alice" ) or diag $raw;
        like( $ran, qr/csrf=1/, "$shape: answered by the CGI" );
    }
};

oomd_stop($oomd);
done_testing;
