#!/usr/bin/perl
# SM1181 S5 (SM1082 C2, R3): IN A POOL WORKER request_session NEVER CONSULTS THE
# SENTINEL, SO A LISTED PROXY'S USER WINS OVER A COOKIE (SM1130) EVEN WHEN A
# LAZYSITE_AUTH_TRUSTED FASTCGI PARAMETER ARRIVES WITH THEM.
#
# S4's report, "Found in passing": "request_session asks request_identity whether
# a trusted proxy names a user without `pool => 1`, so in a worker a
# `LAZYSITE_AUTH_TRUSTED` FastCGI parameter makes it read the fixed names as a
# cookie identity. A listed proxy's user is then passed over and the cookie
# decides." It failed closed - the value was anonymous or the cookie's own account
# - but it broke S2's rule (R3: "In the pool, LAZYSITE_AUTH_TRUSTED from %ENV is
# never believed") and SM1130's order (a listed proxy peer with a user wins, the
# cookie is not consulted). The front door now tells request_session it is in the
# pool, and request_session passes that to request_identity.
#
# ONE worker, the front door on, a site that lists 192.0.2.7 as its proxy. Every
# request below comes from that proxy naming `ed`, with a cookie for `boss` and the
# sentinel sent as a FastCGI parameter. The proxy's user must win:
#
#   - for a page the worker renders itself (S3's path)
#   - for the manager API the worker relays (S4's path): the real API answers as
#     `ed`, handed the proxy's own header and no sentinel
#
# and, as the control, the same request without the forged parameter (which S4
# already got right).
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $d    = site_tempdir();
( my $base = $d ) =~ s{/public_html\z}{};
my $LZ = "$d/lazysite";
make_path("$LZ/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

my $SECRET = 'd' x 64;
my $PROXY  = '192.0.2.7';
spit( "$LZ/lazysite.conf",
    "site_name: T\nmanager: enabled\nauth_proxy_trusted: true\nauth_proxy_trusted_from: $PROXY\n" );
spit( "$LZ/auth/.secret", "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", "boss:x\ned:x\n" );
grant_caps( $d, 'boss', qw(ui manage_users) );
grant_caps( $d, 'ed',   'ui' );
spit( "$d/index.md",   "---\ntitle: Home\n---\nHOME BODY\n" );
spit( "$d/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %]\n" );

my $cgibin = "$base/cgi-bin";
my $RAN    = "$base/wrapper-ran.log";
my $API    = "$base/api-ran.log";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
spit( "$cgibin/lazysite-auth.pl", <<"PERL" );
#!/usr/bin/perl
unless (\@ARGV) {
    open my \$fh, '>>', '$RAN' or die;
    print {\$fh} ( \$ENV{REDIRECT_URL} // \$ENV{REQUEST_URI} // '-' ), "\\n";
    close \$fh;
}
exec \$^X, '$root/lazysite-auth.pl', \@ARGV;
PERL
spit( "$cgibin/lazysite-manager-api.pl", <<"PERL" );
#!/usr/bin/perl
open my \$fh, '>>', '$API' or die;
print {\$fh} join( ' ', map { "\$_=" . ( \$ENV{\$_} // '' ) } qw(LAZYSITE_AUTH_TRUSTED HTTP_X_REMOTE_USER) ), "\\n";
close \$fh;
exec \$^X, '$root/lazysite-manager-api.pl';
PERL

sub cookie_for {
    my ($user) = @_;
    my $sid = substr( hmac_sha256_hex( "sid-$user", 'w' ), 0, 16 );
    my $payload = join ':', $user, time(), $sid, '';
    return "lazysite_auth=$payload:" . hmac_sha256_hex( $payload, $SECRET );
}

my $sock = "$base/pool.sock";
my $LOG  = "$base/worker-stderr.log";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";
my $pid = fork() // die "fork: $!";
if ( $pid == 0 ) {
    %ENV = ( env_passthrough(), PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
        LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin );
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', $LOG or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

# One request. Returns ( stdout, the wrapper runs it caused, the API runs it caused ).
sub req {
    my ( $uri, %p ) = @_;
    my ( $path, $q ) = split /\?/, $uri, 2;
    my $ran0 = length slurp($RAN);
    my $api0 = length slurp($API);
    my $r    = fcgi_request( $sock,
        {   REQUEST_METHOD  => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 ProxyWinsTest',
            HTTP_HOST       => 'site.test',
            DOCUMENT_ROOT   => $d,
            REDIRECT_URL    => $path,
            REQUEST_URI     => $uri,
            QUERY_STRING    => $q // '',
            %p,
        } );
    return ( $r->{stdout} // '', substr( slurp($RAN), $ran0 ), substr( slurp($API), $api0 ) );
}

my $up;
for ( 1 .. 50 ) {
    ($up) = eval { req('/') };
    last if $up && $up =~ /HOME BODY/;
    select( undef, undef, undef, 0.1 );
}
like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
    or do { diag( slurp($LOG) ); kill 'TERM', $pid; waitpid $pid, 0; done_testing(); exit };

# The listed proxy names ed; the cookie is boss's.
my %FROM_PROXY = ( REMOTE_ADDR => $PROXY, HTTP_X_REMOTE_USER => 'ed', HTTP_COOKIE => cookie_for('boss') );

subtest 'a page the worker renders: the proxy\'s user wins over the cookie' => sub {
    my ( $out, $ran ) = req( '/members', %FROM_PROXY );
    like( $out, qr/MEMBERS WHO=ed\b/, 'without the parameter: ed, the proxy\'s user (the control)' );
    is( $ran, '', 'in the worker' );

    ( $out, $ran ) = req( '/members', %FROM_PROXY, LAZYSITE_AUTH_TRUSTED => '1' );
    like( $out, qr/MEMBERS WHO=ed\b/, 'with LAZYSITE_AUTH_TRUSTED as a FastCGI parameter: still ed' )
        or diag( ( $out =~ /(MEMBERS WHO=\S*)/ )[0] // 'no WHO line' );
    unlike( $out, qr/MEMBERS WHO=boss/, 'the cookie is not consulted (SM1130)' );
    is( $ran, '', 'in the worker' );
};

subtest 'the manager API the worker relays: the proxy\'s user wins over the cookie' => sub {
    my $uri = '/cgi-bin/lazysite-manager-api.pl?action=whoami&plugins=0';
    my %api = ( SCRIPT_NAME => '/cgi-bin/lazysite-manager-api.pl', CONTENT_TYPE => 'application/json' );

    my ( $out, $ran, $apiran ) = req( $uri, %api, %FROM_PROXY );
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) } || {};
    is( $res->{user} // $res->{username}, 'ed', 'without the parameter: ed (the control)' ) or diag($out);

    ( $out, $ran, $apiran ) = req( $uri, %api, %FROM_PROXY, LAZYSITE_AUTH_TRUSTED => '1' );
    ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    $res = eval { decode_json( $jb // '' ) } || {};
    ok( $res->{ok}, 'with the parameter the call is answered' ) or diag($out);
    is( $res->{user} // $res->{username}, 'ed', 'as ed, the proxy\'s user, not the cookie\'s boss' );
    is( $apiran, "LAZYSITE_AUTH_TRUSTED= HTTP_X_REMOTE_USER=ed\n",
        'the API was handed the proxy\'s own header and no sentinel' );
    is( $ran, '', 'without the wrapper' );
};

ok( kill( 0, $pid ), 'the one worker served every request and is still running' );
kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
