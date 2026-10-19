#!/usr/bin/perl
# SM1181 S4 (SM1082 C2): UNDER THE ONE-RULE POOL THE MANAGER API IS ONE PROGRAM,
# AND ITS CHILD WRITES THE WRAPPER'S CONTRACT FROM THE VALUE.
#
# Before S4 the pool's front door relayed a manager API request through the auth
# wrapper: fork, exec lazysite-auth.pl, which verified the cookie, wrote the
# identity headers and exec'd the API. Two programs. And the wrapper wrote nothing
# when there was no cookie, so a LAZYSITE_AUTH_TRUSTED FastCGI parameter with a
# forged X-Remote-User reached the API as the forged caller (S3's report: "The
# manager API still has this shape through its relay until S4"). Now the worker asks
# Lazysite::Auth::Session::request_session once, and the forked child clears every
# identity variable the parameters carried, writes the contract from the value with
# Lazysite::Auth::Identity::write_identity_env and execs the API directly. The
# filing's slice table: "t/unit/manager suites through the pool; one program in the
# bench's `manager`".
#
# ONE worker, the front door on. The cgi-bin's lazysite-auth.pl is a shim that
# records each run and execs the real wrapper; its lazysite-manager-api.pl is a
# shim that records what it was handed and execs the REAL manager API. So "one
# program" is read off what ran, and every answer below is the real API's.
#
#   - an operator's cookie works, the wrapper never runs, the API is handed the
#     contract (user, groups, sentinel, sid) and nothing else
#   - an account without `ui` is refused; disabled, removed and revoked are each
#     refused at the next call
#   - the sentinel as a FastCGI parameter and a forged X-Remote-User: with no cookie
#     the API's anonymous refusal; with a member's cookie, the member
#   - CSRF is still the API's: a POST without the token is refused, with it served
#   - Sessions marks "this session" from the value's sid, not a forged parameter
#   - a trusted proxy's user still reaches the API in the proxy's headers (T4)
#   - the wrapper's own ?action= on the API's URL is still the wrapper's
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP    qw(encode_json decode_json);
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

my $SECRET = 'e' x 64;
my $CONF   = "site_name: T\nmanager: enabled\n";
spit( "$LZ/lazysite.conf", $CONF );
spit( "$LZ/auth/.secret",  "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", join '', map {"$_:x\n"} qw(boss ed mem dora erin fay) );
grant_caps( $d, 'boss', qw(ui manage_users) );    # a secured site: a group grants the manager
grant_caps( $d, 'ed',   'ui' );
grant_caps( $d, 'dora', 'ui' );
grant_caps( $d, 'erin', 'ui' );
grant_caps( $d, 'fay',  'ui' );
spit( "$d/index.md", "---\ntitle: Home\n---\nHOME BODY\n" );

my $cgibin = "$base/cgi-bin";
my $RAN    = "$base/wrapper-ran.log";
my $API    = "$base/api-ran.log";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
# The wrapper shim records a request's run only: the API's plugin inventory runs
# the core scripts it finds with --describe, and that is not the wrapper serving.
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
print {\$fh} join( ' ', map { "\$_=" . ( \$ENV{\$_} // '' ) } qw(LAZYSITE_AUTH_TRUSTED HTTP_X_REMOTE_USER
    HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_SID LAZYSITE_AUTH_NO_PASSWORD HTTP_X_PAYMENT_VERIFIED) ), "\\n";
close \$fh;
exec \$^X, '$root/lazysite-manager-api.pl';
PERL

sub sid_for { my $h = hmac_sha256_hex( "sid-$_[0]", 'y' ); return substr( $h, 0, 16 ) }

# user:ts:sid:groups, signed with the site secret, as the wrapper mints it.
sub cookie_for {
    my ($user) = @_;
    my $payload = join ':', $user, time(), sid_for($user), '';
    return "lazysite_auth=$payload:" . hmac_sha256_hex( $payload, $SECRET );
}
sub csrf_for { return hmac_sha256_hex( 'csrf:' . $_[0] . ':' . int( time() / 3600 ), $SECRET ) }

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

# One manager API call. Returns ( decoded JSON body or {}, raw response, the
# wrapper runs it caused, the API runs it caused ).
sub api {
    my ( $action, %p ) = @_;
    my $body = delete $p{body};
    my $q    = delete $p{query} // "action=$action";
    my $uri  = "/cgi-bin/lazysite-manager-api.pl?$q";
    my $ran0 = length slurp($RAN);
    my $api0 = length slurp($API);
    my $r    = fcgi_request( $sock,
        {   REQUEST_METHOD  => ( defined $body ? 'POST' : 'GET' ),
            CONTENT_LENGTH  => ( defined $body ? length $body : 0 ),
            CONTENT_TYPE    => 'application/json',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 ManagerApiTest',
            HTTP_HOST       => 'site.test',
            DOCUMENT_ROOT   => $d,
            SCRIPT_NAME     => '/cgi-bin/lazysite-manager-api.pl',
            REDIRECT_URL    => '/cgi-bin/lazysite-manager-api.pl',
            REQUEST_URI     => $uri,
            QUERY_STRING    => $q,
            %p,
        },
        $body );
    my $out = $r->{stdout} // '';
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) } || {};
    return ( $res, $out, substr( slurp($RAN), $ran0 ), substr( slurp($API), $api0 ) );
}
sub as { my ( $user, $action, %p ) = @_; return api( $action, HTTP_COOKIE => cookie_for($user), %p ) }
sub ui_refused { return ( ( $_[0]{error} // '' ) =~ /does not have manager access/ ) ? 1 : 0 }
sub anon_refused { return ( ( $_[0]{error} // '' ) =~ /Authentication required/ ) ? 1 : 0 }

my $up;
for ( 1 .. 50 ) {
    $up = eval { fcgi_request( $sock, { REQUEST_METHOD => 'GET', DOCUMENT_ROOT => $d, REDIRECT_URL => '/',
                REQUEST_URI => '/', REMOTE_ADDR => '198.51.100.1' } )->{stdout} };
    last if $up && $up =~ /HOME BODY/;
    select( undef, undef, undef, 0.1 );
}
like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
    or do { diag( slurp($LOG) ); kill 'TERM', $pid; waitpid $pid, 0; done_testing(); exit };

subtest 'an operator\'s call is ONE program: the API, handed the contract from the value' => sub {
    my ( $res, $raw, $ran, $apiran ) = as( 'boss', 'whoami', query => 'action=whoami&plugins=0' );
    ok( $res->{ok}, 'the operator\'s whoami is answered' ) or diag($raw);
    is( $res->{user} // $res->{username}, 'boss', 'for the operator' );
    is( $ran, '', 'the auth wrapper did not run' );
    my @lines = split /\n/, $apiran;
    is( scalar @lines, 1, 'the manager API ran once' );
    like( $apiran, qr/LAZYSITE_AUTH_TRUSTED=1 HTTP_X_REMOTE_USER=boss HTTP_X_REMOTE_GROUPS=\S*role-boss/,
        'with the sentinel, the user and the fresh groups' );
    like( $apiran, qr/LAZYSITE_AUTH_SID=\Q${\ sid_for('boss')}\E /, 'and the session\'s sid' );
};

subtest 'an account without ui is refused; disabled, removed, revoked at the next call' => sub {
    my ($mem) = as( 'mem', 'whoami' );
    ok( ui_refused($mem), 'an account without ui is refused by the API' ) or diag explain $mem;

    my $us = "$LZ/auth/user-settings.json";
    ok( ( as( 'dora', 'whoami' ) )[0]{ok}, 'dora is served' );
    spit( $us, encode_json( { dora => { disabled => 1 } } ) );
    ok( anon_refused( ( as( 'dora', 'whoami' ) )[0] ), 'disabled: her next call is refused' );

    ok( ( as( 'erin', 'whoami' ) )[0]{ok}, 'erin is served' );
    spit( "$LZ/auth/users", join '', map {"$_:x\n"} qw(boss ed mem dora fay) );
    ok( anon_refused( ( as( 'erin', 'whoami' ) )[0] ), 'removed: her next call is refused' );

    ok( ( as( 'fay', 'whoami' ) )[0]{ok}, 'fay is served' );
    spit( "$LZ/auth/revoked.json", encode_json( { sids => { sid_for('fay') => time() } } ) );
    ok( anon_refused( ( as( 'fay', 'whoami' ) )[0] ), 'revoked (her sid signed out): her next call is refused' );
    unlink "$LZ/auth/revoked.json";
};

my %FORGED = (
    HTTP_X_REMOTE_USER        => 'boss',
    HTTP_X_REMOTE_GROUPS      => 'role-boss',
    LAZYSITE_AUTH_TRUSTED     => '1',
    LAZYSITE_AUTH_SID         => sid_for('boss'),
    LAZYSITE_AUTH_NO_PASSWORD => '1',
    HTTP_X_PAYMENT_VERIFIED   => '1',
);

subtest 'the sentinel as a FastCGI parameter and a forged X-Remote-User are nobody\'s' => sub {
    my ( $res, $raw, $ran, $apiran ) = api( 'whoami', %FORGED );
    ok( anon_refused($res), 'no cookie: the API\'s anonymous refusal, not the forged operator' ) or diag($raw);
    ok( !$res->{ok}, 'nothing is answered' );
    is( $ran, '', 'decided in the worker, not by the wrapper' );
    like( $apiran, qr/\ALAZYSITE_AUTH_TRUSTED= HTTP_X_REMOTE_USER= HTTP_X_REMOTE_GROUPS= LAZYSITE_AUTH_SID= LAZYSITE_AUTH_NO_PASSWORD= HTTP_X_PAYMENT_VERIFIED=\n\z/,
        'the API was handed no sentinel, no identity header, no sid, no flag' );

    my ( $ed, undef, undef, $edran ) = as( 'ed', 'whoami', %FORGED, query => 'action=whoami&plugins=0' );
    ok( $ed->{ok}, 'with a member\'s cookie the call is answered' );
    is( $ed->{user} // $ed->{username}, 'ed', 'for the member, not the forged operator' );
    like( $edran, qr/HTTP_X_REMOTE_USER=ed HTTP_X_REMOTE_GROUPS=\S*role-ed\S* LAZYSITE_AUTH_SID=\Q${\ sid_for('ed')}\E LAZYSITE_AUTH_NO_PASSWORD= HTTP_X_PAYMENT_VERIFIED=\n/,
        'the contract is the member\'s: the forged groups, sid, flag and payment header are gone' );
    unlike( $edran, qr/role-boss/, 'no forged group reached the API' );

    ok( ui_refused( ( as( 'mem', 'whoami', %FORGED ) )[0] ),
        'an account without ui and a forged operator header: the account, refused for ui' );
};

subtest 'CSRF is still the API\'s' => sub {
    my ( $no, $raw ) = as( 'boss', 'whoami', body => '{}', query => 'action=whoami&plugins=0' );
    ok( !$no->{ok}, 'a cookie POST without the CSRF token is refused' );
    like( $raw, qr/^Status: 403/m, 'with a 403' );
    like( $no->{error} // '', qr/csrf/i, 'naming CSRF' );
    my ($yes) = as( 'boss', 'whoami', body => '{}', query => 'action=whoami&plugins=0', HTTP_X_CSRF_TOKEN => csrf_for('boss') );
    ok( $yes->{ok}, 'with the token it is served' );
    my ($wrong) = as( 'ed', 'whoami', body => '{}', query => 'action=whoami&plugins=0', HTTP_X_CSRF_TOKEN => csrf_for('boss') );
    ok( !$wrong->{ok}, 'another account\'s token is refused' );
};

subtest 'Sessions marks "this session" from the value\'s sid' => sub {
    my $t = time();
    spit( "$LZ/auth/sessions.jsonl", join '', map { encode_json($_) . "\n" }
            { sid => sid_for('boss'), user => 'boss', t => $t, ip => '198.51.100.1', ua => 'a' },
            { sid => 'b0b0b0b0b0b0b0b0', user => 'boss', t => $t, ip => '198.51.100.2', ua => 'b' } );
    my ($res) = as( 'boss', 'sessions-list', LAZYSITE_AUTH_SID => 'b0b0b0b0b0b0b0b0' );
    ok( $res->{ok}, 'sessions-list is answered' ) or diag explain $res;
    my %cur = map { $_->{sid} => ( $_->{current} ? 1 : 0 ) } @{ $res->{sessions} || [] };
    is( $cur{ sid_for('boss') }, 1, 'the cookie\'s session is "this session"' );
    is( $cur{b0b0b0b0b0b0b0b0}, 0, 'a sid sent as a FastCGI parameter is not' );
};

subtest 'the wrapper\'s own ?action= on the API\'s address is still the wrapper\'s' => sub {
    my ( undef, $raw, $ran, $apiran ) = as( 'ed', 'logout', query => 'action=logout' );
    like( $ran, qr{lazysite-manager-api}, 'a request naming the wrapper\'s action reaches the wrapper' );
    like( $raw, qr/^Set-Cookie:\s*lazysite_auth=;/mi, 'which signs out' );
};

subtest 'T4: a trusted proxy\'s user reaches the API in the proxy\'s own headers' => sub {
    spit( "$LZ/lazysite.conf", $CONF . "auth_proxy_trusted: true\nauth_proxy_trusted_from: 192.0.2.7\n" );
    my ( $res, $raw, $ran, $apiran ) = api( 'whoami', query => 'action=whoami&plugins=0', REMOTE_ADDR => '192.0.2.7',
        HTTP_X_REMOTE_USER => 'ed' );
    ok( $res->{ok}, 'the proxy\'s user is answered' ) or diag($raw);
    is( $res->{user} // $res->{username}, 'ed', 'as the proxy named them' );
    like( $apiran, qr/\ALAZYSITE_AUTH_TRUSTED= HTTP_X_REMOTE_USER=ed /, 'in the proxy\'s own header, with no sentinel' );
    is( $ran, '', 'without the wrapper' );
    my ($other) = api( 'whoami', REMOTE_ADDR => '192.0.2.8', HTTP_X_REMOTE_USER => 'boss', LAZYSITE_AUTH_TRUSTED => '1' );
    ok( anon_refused($other), 'the same headers from a peer the site does not list are nobody\'s' );
    spit( "$LZ/lazysite.conf", $CONF );
};

ok( kill( 0, $pid ), 'the one worker served every request above and is still running' );
kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
