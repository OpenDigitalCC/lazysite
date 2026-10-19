#!/usr/bin/perl
# SM1181 S3 (SM1082 C2): UNDER THE ONE-RULE POOL, A SIGNED-IN PAGE IS RENDERED IN
# THE WORKER, ITS IDENTITY DECIDED THERE AS A VALUE.
#
# Before S3 the pool's front door relayed every request it would have wrapped - a
# page with a session cookie, a /manager/ page, a static on a site with an ACL
# store: fork, exec lazysite-auth.pl, which verified the cookie, wrote the identity
# headers and exec'd the processor. Two programs for a page this worker renders
# itself. Now the front door asks Lazysite::Auth::Session::request_session once,
# holds the answer in $REQUEST_IDENT, and main() renders from it. The filing's slice
# table: "T1, T2, T5, T7, T11 in the pool; t/integration/50 still relays the rest".
#
# ONE worker (no LAZYSITE_FCGI_WORKERS), so every request below is served by the
# same process, as a pooled visitor's next request is. The cgi-bin's
# lazysite-auth.pl is a shim that records each run and then execs the real
# wrapper, so "rendered in the worker" is read off what ran, not inferred - on the
# base tree every signed-in request below ran it.
#
#   T1  alice, anonymous, bob, alice again: each sees only themselves
#   T2  a forged X-Remote-User / X-Lazysite-* / the sentinel as a parameter: with no
#       cookie anonymous; with bob's cookie bob, the forged headers stripped and
#       logged (R4), a forged payment header not believed
#   T5  disabled, removed, revoked, and a store that cannot be read: each stops at
#       the next pooled request; a group gate refuses a non-member and serves them
#       once added (fresh groups, SEC-2026-07 M5); the manager entry asks `ui`
#   T7  a request that dies after the identity is held leaves nothing for the next
#   T11 the wrapper's lines at the wrapper's levels, under the site's log_level,
#       and no cookie value in the log
#   R5  the bad-URL guard counts probes and refuses a blocked address on every
#       request, a signed-in one included, and counts a probe once
#   SM1160 an Odoo site sign-in sees its pages and grants nothing past
#       odoo_identity_ttl
#   and what stays the wrapper's: its own ?action= requests and the manager API.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP    qw(encode_json);
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
my $CONF   = "site_name: T\nmanager: enabled\nbad_url_threshold: 3\n";
spit( "$LZ/lazysite.conf", $CONF );
spit( "$LZ/auth/.secret",  "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", join '', map {"$_:x\n"} qw(alice bob dora erin fay boss) );
grant_caps( $d, 'boss', 'ui' );    # a secured site: one group grants the manager
spit( "$LZ/auth/groups", slurp("$LZ/auth/groups") . "staff: alice\n" );
spit( "$LZ/auth/acls.json", encode_json( { 'files/secret.txt' => { owner => 'alice', read => ['alice'] } } ) );

spit( "$d/index.md",     "---\ntitle: Home\n---\nHOME BODY\n" );
spit( "$d/members.md",   "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %]\n" );
spit( "$d/staff.md",     "---\ntitle: Staff\nauth: required\nauth_groups: [staff]\n---\nSTAFF BODY\n" );
spit( "$d/paid.md",      "---\ntitle: Paid\npayment: required\npayment_amount: 1\n---\nPAID BODY\n" );
spit( "$d/wholesale.md", "---\ntitle: Trade\nauth: required\nauth_groups: [wholesale]\n---\nTRADE WHO=[% auth_user %]\n" );
spit( "$d/files/secret.txt", "SECRET BYTES\n" );
spit( "$d/broken.md", "---\ntitle: Broken\n---\nnever read\n" );
chmod 0000, "$d/broken.md";

# The cgi-bin: the real processor, a shim in the wrapper's place that records each
# run and execs the real wrapper, and a stand-in manager API that prints what the
# wrapper handed it.
my $cgibin = "$base/cgi-bin";
my $RAN    = "$base/wrapper-ran.log";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
spit( "$cgibin/lazysite-auth.pl", <<"PERL" );
#!/usr/bin/perl
open my \$fh, '>>', '$RAN' or die;
print {\$fh} ( \$ENV{REDIRECT_URL} // \$ENV{REQUEST_URI} // '-' ), "\\n";
close \$fh;
exec \$^X, '$root/lazysite-auth.pl';
PERL
spit( "$cgibin/lazysite-manager-api.pl", <<'PERL' );
#!/usr/bin/perl
print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";
print "API USER=", ( $ENV{HTTP_X_REMOTE_USER} // '' ), " TRUSTED=", ( $ENV{LAZYSITE_AUTH_TRUSTED} // '' ), "\n";
PERL

sub sid_for { my $h = hmac_sha256_hex( "sid-$_[0]", 'x' ); return substr( $h, 0, 16 ) }

# user:ts:sid:groups, signed with the site secret, as the wrapper mints it. The
# groups field is empty: the verifier reads them fresh (SEC-2026-07 M5).
sub cookie_for {
    my ( $user, %o ) = @_;
    my $payload = join ':', $user, time(), sid_for($user), '';
    my $sig     = $o{bad_sig} ? ( 'f' x 64 ) : hmac_sha256_hex( $payload, $SECRET );
    return "lazysite_auth=$payload:$sig";
}

my $sock = "$base/pool.sock";
my $LOG  = "$base/worker-stderr.log";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";
my $pid = fork() // die "fork: $!";
if ( $pid == 0 ) {
    %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
        LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin );
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', $LOG or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

# One request. Returns the response; in list context ( response, the log lines it
# added, the wrapper runs it caused ).
sub req {
    my ( $uri, %p ) = @_;
    my ( $path, $q ) = split /\?/, $uri, 2;
    my $log0 = length slurp($LOG);
    my $ran0 = length slurp($RAN);
    my $r    = fcgi_request( $sock,
        {   REQUEST_METHOD  => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 InWorkerTest',
            HTTP_HOST       => 'site.test',
            DOCUMENT_ROOT   => $d,
            REDIRECT_URL    => $path,
            REQUEST_URI     => $uri,
            QUERY_STRING    => $q // '',
            %p,
        } );
    my $out = $r->{stdout} // '';
    return $out unless wantarray;
    return ( $out, ( $r->{stderr} // '' ) . substr( slurp($LOG), $log0 ), substr( slurp($RAN), $ran0 ) );
}

sub as { my ( $user, $uri, %p ) = @_; return req( $uri, HTTP_COOKIE => cookie_for($user), %p ) }
sub to_login { return $_[0] =~ /^Location:\s*\S*\/login/mi ? 1 : 0 }

my $up;
for ( 1 .. 50 ) {
    $up = eval { req('/') };
    last if $up && $up =~ /HOME BODY/;
    select( undef, undef, undef, 0.1 );
}
like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
    or do { diag( slurp($LOG) ); kill 'TERM', $pid; waitpid $pid, 0; done_testing(); exit };

subtest 'T1: one worker, four visitors, each sees only themselves' => sub {
    my ( $a1, undef, $ran_a ) = as( 'alice', '/members' );
    like( $a1, qr/MEMBERS WHO=alice\b/, 'alice sees her page as alice' );
    is( $ran_a, '', 'rendered in the worker: the auth wrapper did not run' );

    my $anon = req('/members');
    unlike( $anon, qr/MEMBERS WHO=/, 'the next visitor, anonymous, is not alice' );
    ok( to_login($anon), 'and is sent to sign in' );

    my ( $b1, undef, $ran_b ) = as( 'bob', '/members' );
    like( $b1, qr/MEMBERS WHO=bob\b/, 'bob sees himself' );
    unlike( $b1, qr/alice/, 'and nothing of alice' );
    is( $ran_b, '', 'in the worker too' );

    like( as( 'alice', '/members' ), qr/MEMBERS WHO=alice\b/, 'alice again is alice, not bob' );
};

subtest 'an ACL static is decided in the worker from the value' => sub {
    my ( $mine, undef, $ran ) = as( 'alice', '/files/secret.txt' );
    like( $mine, qr/SECRET BYTES/, 'the reader the ACL names gets the file' );
    is( $ran, '', 'without the wrapper' );
    unlike( as( 'bob', '/files/secret.txt' ), qr/SECRET BYTES/, 'another account does not' );
    unlike( req('/files/secret.txt'), qr/SECRET BYTES/, 'nor an anonymous visitor' );
};

my %FORGED = (
    HTTP_X_REMOTE_USER            => 'alice',
    HTTP_X_REMOTE_GROUPS          => 'staff,role-boss',
    HTTP_X_LAZYSITE_AUTH_TRUSTED  => '1',
    HTTP_X_LAZYSITE_AUTH_SID      => sid_for('alice'),
    LAZYSITE_AUTH_TRUSTED         => '1',
    LAZYSITE_AUTH_SID             => sid_for('alice'),
    LAZYSITE_AUTH_NO_PASSWORD     => '1',
);

subtest 'T2: a forged identity is never the identity in the pool' => sub {
    my $page = req( '/members', %FORGED );
    unlike( $page, qr/MEMBERS WHO=/, 'no cookie: a page is not served as the forged user' );
    ok( to_login($page), 'it is anonymous' );

    my ( $file, undef, $ran ) = req( '/files/secret.txt', %FORGED );
    unlike( $file, qr/SECRET BYTES/, 'no cookie: an ACL static the front door decides is refused to the forged reader' );
    is( $ran, '', 'decided in the worker (an anonymous value), not by the wrapper' );

    my ( $bob, $log ) = as( 'bob', '/members', %FORGED );
    like( $bob, qr/MEMBERS WHO=bob\b/, 'with bob\'s cookie: bob, not the forged alice' );
    like( $log, qr/untrusted auth header ignored/, 'R4: the forged header is stripped and logged' );

    my ( $paid, $plog ) = as( 'bob', '/paid', %FORGED, HTTP_X_PAYMENT_VERIFIED => '1', HTTP_X_PAYMENT_PAYER => '0xforged' );
    unlike( $paid, qr/PAID BODY/, 'a forged payment header with a held value does not unlock a paid page' );
    like( $plog, qr/untrusted payment header ignored/, 'and is logged as ignored' );

    unlike( as( 'bob', '/staff', %FORGED ), qr/STAFF BODY/, 'a forged groups header grants no group' );
};

subtest 'T5: every check the verifier makes stops the next pooled request' => sub {
    my $us = "$LZ/auth/user-settings.json";

    like( as( 'dora', '/members' ), qr/MEMBERS WHO=dora\b/, 'dora is served' );
    spit( $us, encode_json( { dora => { disabled => 1 } } ) );
    my ( $dis, $dlog ) = as( 'dora', '/members' );
    ok( to_login($dis), 'disabled: her next request is anonymous' );
    like( $dlog, qr/\[WARN\].*auth: account disabled user=dora/, 'logged as the wrapper logged it' );

    like( as( 'erin', '/members' ), qr/MEMBERS WHO=erin\b/, 'erin is served' );
    spit( "$LZ/auth/users", join '', map {"$_:x\n"} qw(alice bob dora fay boss) );
    my ( $rem, $rlog ) = as( 'erin', '/members' );
    ok( to_login($rem), 'removed: her next request is anonymous' );
    like( $rlog, qr/auth: account does not exist user=erin/, 'logged' );

    like( as( 'fay', '/members' ), qr/MEMBERS WHO=fay\b/, 'fay is served' );
    spit( "$LZ/auth/revoked.json", encode_json( { sids => { sid_for('fay') => time() } } ) );
    my ( $rev, $vlog ) = as( 'fay', '/members' );
    ok( to_login($rev), 'revoked (her sid signed out): her next request is anonymous' );
    like( $vlog, qr/auth: session revoked user=fay/, 'logged' );

    spit( "$LZ/auth/revoked.json", "{ not json" );
    my ( $ct, $clog ) = as( 'alice', '/members' );
    ok( to_login($ct), 'a session store that cannot be read: refused (cannot tell)' );
    like( $clog, qr/auth: cannot tell/, 'logged' );
    unlink "$LZ/auth/revoked.json";
    like( as( 'alice', '/members' ), qr/MEMBERS WHO=alice\b/, 'and served again once it is repaired' );

    my $no = as( 'bob', '/staff' );
    unlike( $no, qr/STAFF BODY/, 'a group-gated page is refused to a non-member' );
    like( $no, qr/^Status: 403/m, 'with a 403' );
    spit( "$LZ/auth/groups", slurp("$LZ/auth/groups") =~ s/^staff: alice$/staff: alice, bob/mr );
    like( as( 'bob', '/staff' ), qr/STAFF BODY/, 'and served on his next request once he is added (fresh groups)' );

    my $mgr_alice = as( 'alice', '/manager/' );
    my $mgr_boss  = as( 'boss',  '/manager/' );
    like( $mgr_alice, qr/^Status: 403/m, 'the manager entry refuses an account without ui' );
    unlike( $mgr_boss, qr/^Status: 403/m, 'and admits one with it' );
    ok( !to_login($mgr_boss), 'as signed in' );
};

subtest 'T7: a request that dies after the identity is held leaves nothing behind' => sub {
    my $dead = as( 'alice', '/broken' );
    like( $dead, qr/^Status: 500/m, 'the request died (an unreadable page) and was answered 500' );
    my $next = req('/members');
    unlike( $next, qr/MEMBERS WHO=/, 'the next request in the worker is not alice' );
    ok( to_login($next), 'it is anonymous' );
    unlike( req('/files/secret.txt'), qr/SECRET BYTES/, 'nor is the next one the front door decides' );
};

subtest 'T11: the wrapper\'s lines, at its levels, under the site\'s log_level' => sub {
    my ( undef, $quiet ) = as( 'alice', '/members' );
    unlike( $quiet, qr/auth: cookie valid/, 'at the default level a valid session logs nothing (SM1099)' );

    my ( undef, $bad ) = req( '/members', HTTP_COOKIE => cookie_for( 'alice', bad_sig => 1 ) );
    like( $bad, qr/\[WARN\] \[processor\] \[\/members\] auth: signature mismatch/, 'a forged signature is a WARN, as in the wrapper' );

    spit( "$LZ/lazysite.conf", $CONF . "log_level: DEBUG\n" );
    my $c = cookie_for('alice');
    my ( undef, $loud ) = req( '/members', HTTP_COOKIE => $c );
    like( $loud, qr/\[DEBUG\] \[processor\] \[\/members\] auth: cookie valid/, 'log_level: DEBUG brings the line back' );
    like( $loud, qr/user=alice/, 'naming the account' );
    my ( undef, $none ) = req('/files/secret.txt');
    like( $none, qr/auth: no cookie/, 'and the no-cookie line for a request the front door decided' );
    my ($sig) = $c =~ /:([0-9a-f]{64})\z/;
    unlike( slurp($LOG), qr/\Q$sig\E/, 'no cookie value is ever in the log' );
    spit( "$LZ/lazysite.conf", $CONF );
};

subtest 'what stays the wrapper\'s is still relayed to it' => sub {
    my ( $api, undef, $aran ) = as( 'alice', '/cgi-bin/lazysite-manager-api.pl' );
    like( $aran, qr{lazysite-manager-api}, 'the manager API is still wrapped (S4)' );
    like( $api, qr/API USER=alice TRUSTED=1/, 'and gets the wrapper\'s contract' );

    # Last: signing out revokes alice's session.
    my ( $out, undef, $ran ) = as( 'alice', '/members?action=logout' );
    like( $ran, qr{^/members$}m, 'a wrapped request naming the wrapper\'s own action reaches the wrapper' );
    like( $out, qr/^Set-Cookie:\s*lazysite_auth=;/mi, 'which signs out' );
};

subtest 'R5: the bad-URL guard runs on every request, and counts each probe once' => sub {
    my %X = ( REMOTE_ADDR => '203.0.113.10' );
    as( 'bob', '/wp-login.php', %X ) for 1 .. 2;
    like( as( 'bob', '/members', %X ), qr/MEMBERS WHO=bob\b/, 'two signed-in probes under a threshold of three: not blocked (no probe counted twice)' );
    as( 'bob', '/wp-login.php', %X );
    my $blocked = as( 'bob', '/members', %X );
    like( $blocked, qr/^Status: 403/m, 'the third blocks the address: a signed-in page request from it is refused' );
    unlike( $blocked, qr/MEMBERS WHO=/, 'and not rendered' );

    my %Y = ( REMOTE_ADDR => '203.0.113.20' );
    req( '/wp-admin/x', %Y ) for 1 .. 3;
    like( req( '/', %Y ), qr/^Status: 403/m, 'anonymous probes count too, and an anonymous page from that address is refused (T13)' );
    like( req( '/', REMOTE_ADDR => '203.0.113.30' ), qr/HOME BODY/, 'another address is served' );
    like( slurp("$LZ/cache/bad-url-blocked.json"), qr/203\.0\.113\.20/, 'the block is the shared store the wrapper writes' );

    # A request the front door hands to the wrapper (a wrapped request naming its
    # ?action=) is guarded by the wrapper alone: two such probes are two, not four.
    my %W = ( REMOTE_ADDR => '203.0.113.40', HTTP_COOKIE => 'lazysite_auth=nobody' );
    my ( undef, undef, $wran ) = req( '/wp-login.php?action=logout', %W );
    req( '/wp-login.php?action=logout', %W );
    like( $wran, qr{^/wp-login\.php$}m, 'a probe naming the wrapper\'s action went to the wrapper' );
    like( req( '/', REMOTE_ADDR => '203.0.113.40' ), qr/HOME BODY/,
        'and two of them do not block under a threshold of three: the front door did not count them as well' );
};

subtest 'SM1160: an Odoo site sign-in sees its pages, and nothing past odoo_identity_ttl' => sub {
    spit( "$LZ/odoo.conf", "odoo_site_signin: on\nodoo_group_map: sales.group_wholesale = wholesale\nodoo_identity_ttl: 900\n" );
    local $ENV{DOCUMENT_ROOT} = $d;
    require Lazysite::Auth::Session;
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    my ( $cookie, undef, $sid ) = Lazysite::Auth::Session::mint_odoo_session(
        login => 'jane@example.com', name => 'Jane', groups => ['wholesale'], ip => '198.51.100.1', ua => 't' );
    ok( $cookie, 'an Odoo site session is minted' ) or return;

    my ( $page, undef, $ran ) = req( '/wholesale', HTTP_COOKIE => "lazysite_auth=$cookie" );
    like( $page, qr/TRADE WHO=odoo:jane\@example\.com/, 'its mapped group\'s page is served to odoo:<login>' );
    is( $ran, '', 'in the worker' );

    ok( Lazysite::Auth::Session::renew_odoo_session( sid => $sid, groups => ['wholesale'], now => time() - 2000 ),
        'its record is now older than odoo_identity_ttl' );
    my $stale = req( '/wholesale', HTTP_COOKIE => "lazysite_auth=$cookie" );
    unlike( $stale, qr/TRADE WHO=/, 'past the TTL it grants nothing' );
    ok( to_login($stale), 'the request is anonymous until Odoo is asked again' );
};

ok( kill( 0, $pid ), 'the one worker served every request above and is still running' );
kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
