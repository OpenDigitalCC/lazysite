#!/usr/bin/perl
# SM1181 S5 (SM1082 C2, R6): THE DEV SERVER RUNS THE SURFACES THAT VERIFY THEIR
# OWN CALLERS DIRECTLY, AS EVERY PRODUCTION FRONT END DOES.
#
# On a site with accounts tools/lazysite-server.pl ran every /cgi-bin/lazysite-*.pl
# behind the auth wrapper - the Odoo, data, MCP and OAuth endpoints included. No
# shipped front end wraps those four: each verifies its own caller (the Odoo and
# data endpoints the session cookie, SM411; MCP its bearer, SM076; OAuth its
# client and grant) and reads nothing the wrapper writes. So the lab's `?csrf=1`
# through the dev server was two programs, and its ~210 ms floor was the wrapper's
# start-up (the lab's note of 2026-10-19). The filing's slice: "the dev server
# stops wrapping the surfaces that verify themselves (Odoo, data, MCP, OAuth), as
# no production front end wraps them, and runs the bad-URL guard for them itself."
#
# The dev server runs from a copy of tools/ in a scratch tree whose lazysite-*.pl
# are shims: each records its own name and execs the REAL script, so what ran is
# read off the record and every answer is the real endpoint's.
#
#   - each of the four is reached with no wrapper run, by itself once
#   - each still decides its own caller: a forged X-Remote-User is nobody to the
#     data and Odoo endpoints, a session cookie is the account (the endpoint's own
#     check), the Odoo endpoint refuses a sign-out without its token, MCP refuses a
#     tool call without a bearer (a cookie is not one), OAuth refuses a bad grant
#   - the page and the manager API are still wrapped (unchanged)
#   - the guard (SM128) counts probes sent to these surfaces and refuses the
#     blocked address on them, the shared Lazysite::BadUrl::guard
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Copy  qw(copy);
use IO::Socket::INET;
use Time::HiRes qw(sleep);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper   qw(repo_root site_tempdir grant_caps);
use NginxHarness qw(free_port);

plan skip_all => 'DBI/DBD::SQLite not available (the data endpoint needs them)'
    unless eval { require DBI; require DBD::SQLite; 1 };

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

my $SECRET = 'f' x 64;
spit( "$LZ/lazysite.conf", "site_name: T\nmanager: enabled\nmcp_enabled: true\noauth_enabled: true\n"
        . "bad_url_threshold: 3\nplugins:\n  - plugins/odoo.pl\n  - plugins/data.pl\n" );
spit( "$LZ/auth/.secret", "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", "boss:x\nmem:x\n" );
grant_caps( $d, 'boss', qw(ui manage_users) );
spit( "$d/index.md", "---\ntitle: Home\n---\nHOME BODY\n" );

# The scratch tree: tools/ is the dev server under test, lib/ the real modules,
# and every script beside tools/ a recording shim.
my $tree = "$base/tree";
my $RAN  = "$base/ran.log";
make_path("$tree/tools");
copy( "$root/tools/lazysite-server.pl", "$tree/tools/lazysite-server.pl" ) or die "copy: $!";
symlink "$root/lib", "$tree/lib" or die "symlink: $!";
for my $s (qw(auth processor manager-api odoo data mcp oauth)) {
    spit( "$tree/lazysite-$s.pl", <<"PERL" );
#!/usr/bin/perl
unless (\@ARGV) {
    open my \$fh, '>>', '$RAN' or die;
    print {\$fh} "$s\\n";
    close \$fh;
}
exec \$^X, '$root/lazysite-$s.pl', \@ARGV;
PERL
}

my $port = free_port();
my $pid  = fork() // die "fork: $!";
if ( !$pid ) {
    open STDOUT, '>', "$base/server.out";
    open STDERR, '>', "$base/server.err";
    exec $^X, "$tree/tools/lazysite-server.pl", '--docroot', $d, '--no-seed', '--port', $port;
    exit 1;
}
END { if ($pid) { kill 'TERM', $pid; waitpid $pid, 0 } }

# One request. Returns ( status code, decoded JSON body or {}, raw, what ran ).
sub hit {
    my ( $method, $uri, %o ) = @_;
    my $body = $o{body} // '';
    my $ran0 = length slurp($RAN);
    my $s    = IO::Socket::INET->new( PeerAddr => '127.0.0.1', PeerPort => $port ) or die "connect: $!";
    my $req  = "$method $uri HTTP/1.0\r\nHost: site.test\r\n";
    $req .= "$_: $o{headers}{$_}\r\n" for sort keys %{ $o{headers} || {} };
    $req .= "Content-Type: " . ( $o{type} // 'application/json' ) . "\r\nContent-Length: " . length($body) . "\r\n"
        if length $body;
    print {$s} "$req\r\n$body";
    my $raw = do { local $/; <$s> } // '';
    close $s;
    my ($code) = $raw =~ m{\AHTTP/\S+\s+(\d+)};
    my ($jb)   = $raw =~ /\r?\n\r?\n(.*)/s;
    my $res    = eval { decode_json( $jb // '' ) } || {};
    my @ran    = split /\n/, substr( slurp($RAN), $ran0 );
    return ( $code // 0, $res, $raw, \@ran );
}

sub cookie_for {
    my ($user) = @_;
    my $sid = substr( hmac_sha256_hex( "sid-$user", 'z' ), 0, 16 );
    my $payload = join ':', $user, time(), $sid, '';
    return "lazysite_auth=$payload:" . hmac_sha256_hex( $payload, $SECRET );
}

my $up;
for ( 1 .. 100 ) {
    my $s = IO::Socket::INET->new( PeerAddr => '127.0.0.1', PeerPort => $port );
    if ($s) { close $s; $up = 1; last }
    sleep 0.1;
}
ok( $up, 'the dev server is up' ) or do { diag( slurp("$base/server.err") ); done_testing(); exit };

subtest 'the Odoo endpoint is reached directly, and decides its own caller' => sub {
    my ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-odoo.pl?csrf=1',
        headers => { 'X-Remote-User' => 'boss' } );
    is( $code, 200, '?csrf=1 is answered' ) or diag($raw);
    is_deeply( $ran, ['odoo'], 'by the endpoint alone: the wrapper did not run' );
    ok( length( $res->{visitor_token} // '' ), 'with a visitor token' );
    ok( !exists $res->{token}, 'and a forged X-Remote-User is nobody: no session token' );

    ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-odoo.pl?csrf=1',
        headers => { Cookie => cookie_for('boss') } );
    is_deeply( $ran, ['odoo'], 'a signed-in ?csrf=1 is one program too' );
    ok( length( $res->{token} // '' ), 'and the endpoint\'s own check of the cookie gives the account its token' )
        or diag($raw);

    ( $code, $res, $raw, $ran ) = hit( 'POST', '/cgi-bin/lazysite-odoo.pl',
        headers => { Cookie => cookie_for('boss') }, body => encode_json( { signout => JSON::PP::true } ) );
    is( $code, 403, 'a sign-out without the visitor token is refused' ) or diag($raw);
    is( $res->{kind}, 'csrf', 'by the endpoint\'s CSRF check' );
    is_deeply( $ran, ['odoo'], 'with no wrapper run' );
};

subtest 'the data endpoint is reached directly, and decides its own caller' => sub {
    my ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-data.pl?csrf=1',
        headers => { 'X-Remote-User' => 'boss' } );
    is( $code, 403, 'a forged X-Remote-User with no cookie is not signed in' ) or diag($raw);
    is_deeply( $ran, ['data'], 'the wrapper did not run' );

    ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-data.pl?csrf=1',
        headers => { Cookie => cookie_for('mem') } );
    is( $code, 200, 'a session cookie is the account, by the endpoint\'s own check' ) or diag($raw);
    ok( length( $res->{token} // '' ), 'and it is given its token' );
    is_deeply( $ran, ['data'], 'one program' );

    my $forged = cookie_for('mem') =~ s/:[0-9a-f]{64}\z/':' . ( '0' x 64 )/er;
    ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-data.pl?csrf=1',
        headers => { Cookie => $forged, 'X-Remote-User' => 'mem' } );
    is( $code, 403, 'a cookie with a bad signature is nobody, whatever the header says' ) or diag($raw);
};

subtest 'MCP is reached directly, and refuses a caller without its bearer' => sub {
    my $call = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'whoami', arguments => {} } } );
    my ( $code, $res, $raw, $ran ) = hit( 'POST', '/cgi-bin/lazysite-mcp.pl', body => $call,
        headers => { 'X-Remote-User' => 'boss' } );
    is( $code, 401, 'an unauthenticated tool call is refused' ) or diag($raw);
    like( $raw, qr/WWW-Authenticate: Bearer/, 'with the bearer challenge' );
    is_deeply( $ran, ['mcp'], 'the wrapper did not run' );

    ( $code, $res, $raw, $ran ) = hit( 'POST', '/cgi-bin/lazysite-mcp.pl', body => $call,
        headers => { Cookie => cookie_for('boss') } );
    is( $code, 401, 'an operator\'s session cookie is not an MCP credential either' ) or diag($raw);
    is_deeply( $ran, ['mcp'], 'one program' );
};

subtest 'OAuth is reached directly, and refuses a bad grant' => sub {
    my ( $code, $res, $raw, $ran ) = hit( 'POST', '/cgi-bin/lazysite-oauth.pl?action=token',
        type => 'application/x-www-form-urlencoded',
        body => 'grant_type=authorization_code&code=nope&client_id=x&code_verifier=y&redirect_uri=z',
        headers => { Cookie => cookie_for('boss') } );
    is( $code, 400, 'an unknown code is refused' ) or diag($raw);
    is( $res->{error}, 'invalid_grant', 'as invalid_grant' );
    is_deeply( $ran, ['oauth'], 'the wrapper did not run' );
};

subtest 'the page and the manager API are still wrapped' => sub {
    my ( $code, $res, $raw, $ran ) = hit( 'GET', '/', headers => { Cookie => cookie_for('boss') } );
    like( $raw, qr/HOME BODY/, 'the page renders' );
    is_deeply( $ran, [qw(auth processor)], 'through the wrapper, as before' );

    ( $code, $res, $raw, $ran ) = hit( 'GET', '/cgi-bin/lazysite-manager-api.pl?action=whoami&plugins=0',
        headers => { Cookie => cookie_for('boss') } );
    ok( $res->{ok}, 'the operator\'s whoami is answered' ) or diag($raw);
    is_deeply( $ran, [qw(auth manager-api)], 'through the wrapper, as before' );
};

subtest 'the bad-URL guard runs for these surfaces, in the dev server' => sub {
    my @probes = ( '/cgi-bin/lazysite-mcp.pl/wp-admin', '/cgi-bin/lazysite-odoo.pl/.env',
        '/cgi-bin/lazysite-data.pl/phpmyadmin' );
    for my $p ( @probes[ 0, 1 ] ) {
        my ( $code, undef, undef, $ran ) = hit( 'GET', $p );
        isnt( $code, 403, "$p: counted, not yet refused" );
        ok( !grep( { $_ eq 'auth' } @$ran ), "$p: and no wrapper ran" );
    }
    my $hits = eval { decode_json( slurp("$LZ/cache/bad-url-hits.json") ) } || {};
    is( scalar @{ $hits->{'127.0.0.1'} || [] }, 2, 'each probe counted once' );

    my ( $code, undef, $raw, $ran ) = hit( 'GET', $probes[2] );
    is( $code, 403, 'the third probe trips the block' ) or diag($raw);
    is_deeply( $ran, [], 'and the endpoint did not run' );
    ok( ( eval { decode_json( slurp("$LZ/cache/bad-url-blocked.json") ) } || {} )->{'127.0.0.1'},
        'the address is in the shared block store' );

    for my $u ( '/cgi-bin/lazysite-odoo.pl?csrf=1', '/cgi-bin/lazysite-oauth.pl?action=token' ) {
        ( $code, undef, $raw, $ran ) = hit( 'GET', $u );
        is( $code, 403, "$u: the blocked address is refused" ) or diag($raw);
        is_deeply( $ran, [], "$u: before the endpoint runs" );
    }
};

done_testing;
