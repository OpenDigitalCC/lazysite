#!/usr/bin/perl
# SM1130 (SM1128 P1-4): under proxy trust, the proxy's identity wins over a
# lazysite cookie for the same request.
#
# lazysite-auth.pl used to overwrite X-Remote-User/Groups with a valid cookie's
# identity, so a stale local session beat the directory. Now, with
# auth_proxy_trusted on, the peer listed in auth_proxy_trusted_from and the
# request carrying a user, the cookie is not consulted for identity at all
# (a DEBUG line says one was ignored). With no proxy user the cookie still
# works - a site may use both.
#
# Driven through the real chain: lazysite-auth.pl (the wrapper) -> the real
# processor, deciding on a per-file ACL (read: alice) whose answer names the
# identity that arrived.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);
use ManagerSession;

my $root = repo_root();

my $ms = ManagerSession::new_site(
    root => $root,
    conf => "site_name: T\nauth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8\n",
);
my $d = $ms->docroot;
$ms->add_user('alice');
$ms->add_user('bob');

make_path("$d/private");
for my $f (qw(for-alice for-carol)) {
    open my $fh, '>', "$d/private/$f.html" or die $!;
    print {$fh} "<h1>body-$f</h1>";
    close $fh;
}
open my $af, '>', "$d/lazysite/auth/acls.json" or die $!;
print {$af} encode_json( {
    'private/for-alice.html' => { read => ['alice'] },
    'private/for-carol.html' => { read => ['carol'] },
} );
close $af;

# One request through the wrapper. %o: addr, cookie_user, proxy_user.
sub via_wrapper {
    my ( $uri, %o ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT        => $d,
        REDIRECT_URL         => $uri,
        REQUEST_METHOD       => 'GET',
        QUERY_STRING         => '',
        REMOTE_ADDR          => $o{addr},
        LAZYSITE_PROCESSOR   => "$root/lazysite-processor.pl",
        LAZYSITE_LOG_LEVEL   => 'DEBUG',
        ( defined $o{cookie_user} ? ( HTTP_COOKIE => $ms->cookie_for( $o{cookie_user} ) ) : () ),
        ( defined $o{proxy_user}  ? ( HTTP_X_REMOTE_USER => $o{proxy_user}, HTTP_X_REMOTE_GROUPS => '' ) : () ),
    );
    my $err = gensym;
    my $pid = open3( my $w, my $r, $err, $^X, "$root/lazysite-auth.pl" );
    close $w;
    my $out = do { local $/; <$r> };
    my $log = do { local $/; <$err> };
    waitpid $pid, 0;
    return ( $out, $log );
}

my $PROXY = '10.1.2.3';
my $OTHER = '203.0.113.9';

subtest 'trusted proxy + a stale cookie for another user: the proxy identity' => sub {
    # The cookie says alice (valid, her account exists); the directory says carol.
    my ( $out, $log ) = via_wrapper( '/private/for-carol', addr => $PROXY, cookie_user => 'alice', proxy_user => 'carol' );
    like( $out, qr/body-for-carol/, 'carol, whom only the proxy named, reads her file' ) or diag substr( $out, 0, 300 );
    ( $out, $log ) = via_wrapper( '/private/for-alice', addr => $PROXY, cookie_user => 'alice', proxy_user => 'carol' );
    unlike( $out, qr/body-for-alice/, "alice's valid cookie does not lend her file to the proxy's carol" );
    like( $out, qr/Status: 403/, 'carol is signed in and refused: 403, not a bounce to sign in' );
    like( $log, qr/proxy identity wins, cookie ignored/, 'a DEBUG line says the cookie was ignored' );
};

subtest 'trusted proxy, no cookie: the proxy identity (unchanged)' => sub {
    my ( $out ) = via_wrapper( '/private/for-carol', addr => $PROXY, proxy_user => 'carol' );
    like( $out, qr/body-for-carol/, 'served' );
};

subtest 'no proxy headers + a valid cookie: the cookie identity (a site may use both)' => sub {
    my ( $out, $log ) = via_wrapper( '/private/for-alice', addr => $PROXY, cookie_user => 'alice' );
    like( $out, qr/body-for-alice/, 'alice, by cookie alone, reads her file' ) or diag substr( $out, 0, 300 );
    unlike( $log, qr/proxy identity wins/, 'and nothing says a cookie was ignored' );
    ( $out ) = via_wrapper( '/private/for-carol', addr => $PROXY, cookie_user => 'alice' );
    unlike( $out, qr/body-for-carol/, 'and the cookie is still alice, not anyone else' );
};

subtest 'an untrusted peer sending proxy headers does not displace its cookie' => sub {
    # The headers are not the proxy's, so they are no identity: the cookie decides.
    my ( $out, $log ) = via_wrapper( '/private/for-alice', addr => $OTHER, cookie_user => 'alice', proxy_user => 'carol' );
    like( $out, qr/body-for-alice/, "a forged X-Remote-User from an unlisted peer does not beat the visitor's own cookie" )
        or diag substr( $out, 0, 300 );
    unlike( $log, qr/proxy identity wins/, 'and the cookie is not reported ignored' );
    ( $out ) = via_wrapper( '/private/for-carol', addr => $OTHER, proxy_user => 'carol' );
    unlike( $out, qr/body-for-carol/, 'and with no cookie the forged header is nobody' );
};

done_testing();
