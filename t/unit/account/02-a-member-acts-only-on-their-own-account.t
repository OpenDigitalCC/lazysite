#!/usr/bin/perl
# SM1043 (SM1034 phase 1a): the me-* actions. A signed-in member with no manager
# capability changes their own password, lists and ends their own sessions, and
# signs themselves out everywhere - and reaches nobody else's account by any of
# them. Driven through the real manager API CGI, with sessions checked through
# the real auth wrapper.
#
# The adversarial cases are the point:
#   - no account parameter is read: a body naming bob still acts on alice
#   - another account's session id answers exactly like a made-up one
#   - re-authentication: a wrong current password changes nothing, is audited,
#     and counts against the sign-in rate limiter by account and by address
#   - CSRF: a POST without the session's token is refused
#   - a token client is refused; an unauthenticated caller is refused
#   - account_page: disabled turns the family off, naming the setting
#   - the audit trail names the account and never carries the password
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use Digest::SHA  qw(hmac_sha256_hex);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root   = repo_root();
my $auth   = "$root/lazysite-auth.pl";
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1043-secret-' x 3;
my %SID    = ( A => 'a' x 16, B => 'b' x 16, C => 'c' x 16 );
my $ALICE  = 'alice-first-password';
my $BOB    = 'bob-first-password';

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utl, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

my $stubdir = tempdir( CLEANUP => 1 );
my $stub    = "$stubdir/stub-processor.pl";
open my $stf, '>', $stub or die $!;
print $stf "#!/usr/bin/perl\nprint \"Status: 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n\";\n"
    . "print 'USER=', ( \$ENV{HTTP_X_REMOTE_USER} // '' ), \"\\n\";\n";
close $stf;

sub signed_in {
    my ( $d, $cookie ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REDIRECT_URL => '/',         REQUEST_METHOD     => 'GET',
        QUERY_STRING  => '', REMOTE_ADDR  => '127.0.0.1', LAZYSITE_PROCESSOR => $stub,
        HTTP_COOKIE   => "lazysite_auth=$cookie" );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $auth );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    return ( $out // '' ) =~ /^USER=(\S+)$/m ? $1 : '';
}

sub cookie { my ($p) = @_; return $p . ':' . hmac_sha256_hex( $p, $secret ) }
sub csrf   { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# Call the manager API as $who (a verified cookie session, as the auth wrapper
# hands it on), POST when a body is given.
sub api {
    my ( $d, $who, $action, $body, %o ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => ( $o{method} // ( $post ? 'POST' : 'GET' ) ),
        QUERY_STRING   => "action=$action",
        CONTENT_LENGTH => length($json),
        REMOTE_ADDR    => $o{ip} // '192.0.2.10',
        ( length $who
            ? ( HTTP_X_REMOTE_USER => $who, HTTP_X_REMOTE_GROUPS => '', LAZYSITE_AUTH_TRUSTED => 1 )
            : () ),
        ( $o{sid}               ? ( LAZYSITE_AUTH_SID => $o{sid} )    : () ),
        ( $post && !$o{no_csrf} ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
        ( $o{token} ? ( HTTP_AUTHORIZATION => 'Basic ' . encode_base64( "$who:$o{token}", '' ) ) : () ),
    );
    delete $ENV{HTTP_X_REMOTE_USER} if $o{token};
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w $json;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub site {
    my ($extra) = @_;
    my $d = site_tempdir( plugins => 1 );
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\ncontrol_api_enabled: true\n"
        . "plugins:\n  - plugins/login-rate-limit.pl\n" . ( $extra // '' );
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
    uapi( $d, { action => 'add', username => 'alice', password => $ALICE } );
    uapi( $d, { action => 'add', username => 'bob',   password => $BOB } );
    my $ts = time() - 60;
    my %c  = (
        A => cookie("alice:$ts:$SID{A}:"),
        B => cookie("alice:$ts:$SID{B}:"),
        C => cookie("bob:$ts:$SID{C}:"),
    );
    open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
    for my $k (qw(A B C)) {
        print $rf encode_json( { sid => $SID{$k}, user => ( $k eq 'C' ? 'bob' : 'alice' ),
                t => $ts, ip => "198.51.100.$k", ua => "UA-$k" } ) . "\n";
    }
    close $rf;
    return ( $d, \%c );
}

sub users_line {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or return '';
    my ($l) = grep { /^\Q$u\E:/ } <$fh>;
    close $fh;
    return $l // '';
}

sub audit_text {
    my ($d) = @_;
    my $t = '';
    for my $f ( glob("$d/lazysite/logs/audit*") ) {
        open my $fh, '<', $f or next;
        local $/;
        $t .= <$fh> // '';
        close $fh;
    }
    return $t;
}

# --- me: who am I, and nothing secret --------------------------------------------------
{
    my ( $d, $c ) = site();
    uapi( $d, { action => 'mfa-enroll', username => 'alice' } );
    my $r = api( $d, 'alice', 'me' );
    ok( $r->{ok}, 'me: a member with no capability reads their own account' ) or diag explain $r;
    is( $r->{user},                'alice', 'me: it is the caller' );
    is( $r->{password_min_length}, 12,      'me: says the password policy' );
    ok( $r->{mfa_pending}, 'me: 2FA is a state' );
    my $raw = encode_json($r);
    unlike( $raw, qr/totp|secret|recovery|sha256iter/i, 'me: no secret, no hash' );

    my $other = api( $d, 'alice', 'me' . '&username=bob' );
    is( $other->{user}, 'alice', 'me: a username in the query names nobody - still the caller' );

    my $anon = api( $d, '', 'me' );
    ok( !$anon->{ok}, 'me: nobody signed in is refused' );

    my $tok = uapi( $d, { action => 'token', username => 'bob' } );
    my ($key) = ( $tok->{token} // '' ) =~ /(lzs_\w+)/;
SKIP: {
        skip 'no token minted', 1 unless $key;
        my $t = api( $d, 'bob', 'me', undef, token => $key );
        ok( !$t->{ok}, 'me: an access key is refused - the account page is cookie-only' );
    }
}

# --- me-password ----------------------------------------------------------------------
{
    my ( $d, $c ) = site();
    my $before_bob = users_line( $d, 'bob' );

    my $nocsrf = api( $d, 'alice', 'me-password',
        { current_password => $ALICE, new_password => 'alice-second-password' },
        sid => $SID{A}, no_csrf => 1 );
    ok( !$nocsrf->{ok}, 'me-password: a POST without the session\'s CSRF token is refused' );

    my $get = api( $d, 'alice', 'me-password', undef, sid => $SID{A} );
    ok( !$get->{ok}, 'me-password: a GET is refused - it changes something' );

    my $wrong = api( $d, 'alice', 'me-password',
        { current_password => 'not-my-password', new_password => 'alice-second-password' }, sid => $SID{A} );
    ok( !$wrong->{ok}, 'me-password: a wrong current password is refused' );
    is( $wrong->{field}, 'current_password', 'me-password: and says which field' );
    is( signed_in( $d, $c->{B} ), 'alice', 'me-password: a refused change signs nobody out' );

    my $short = api( $d, 'alice', 'me-password',
        { current_password => $ALICE, new_password => 'short' }, sid => $SID{A} );
    ok( !$short->{ok}, 'me-password: the password policy applies' );
    like( $short->{error} // '', qr/at least 12/, 'me-password: and names the length' );

    my $ok = api( $d, 'alice', 'me-password',
        { current_password => $ALICE, new_password => 'alice-second-password',
            username => 'bob' }, sid => $SID{A} );
    ok( $ok->{ok}, 'me-password: the right current password changes it' ) or diag explain $ok;
    is( users_line( $d, 'bob' ), $before_bob,
        'me-password: a body naming bob changes nothing of bob\'s - the subject is the caller' );
    is( signed_in( $d, $c->{A} ), 'alice', 'me-password: the session that changed it stays (SM1040)' );
    is( signed_in( $d, $c->{B} ), '', 'me-password: the other session is signed out (SM1040)' );
    is( signed_in( $d, $c->{C} ), 'bob', 'me-password: bob is untouched' );

    my $audit = audit_text($d);
    like( $audit, qr/\| alice \| me-password \| alice \| [^|]+ \| ok \|/, 'audit: the change is recorded against alice' );
    like( $audit, qr/\| alice \| me-password \| alice \| [^|]+ \| fail \| ui \| forbidden/,
        'audit: the wrong current password is a refused row' );
    unlike( $audit, qr/alice-second-password|not-my-password|\Q$ALICE\E/,
        'audit: no password, old, new or wrong, is in the trail' );
}

# --- rate limit: guessing the password behind a stolen session -------------------------
{
    my ( $d, $c ) = site();
    my $last;
    for my $i ( 1 .. 6 ) {
        $last = api( $d, 'alice', 'me-password',
            { current_password => "guess-$i-xxxxxxx", new_password => 'alice-second-password' },
            sid => $SID{A}, ip => "203.0.113.$i" );
    }
    is( $last->{kind}, 'rate', 'six guesses from six addresses: the account\'s bucket stops the sixth' );
    my $right = api( $d, 'alice', 'me-password',
        { current_password => $ALICE, new_password => 'alice-second-password' },
        sid => $SID{A}, ip => '203.0.113.99' );
    is( $right->{kind}, 'rate', 'and while it is closed the right password is refused too' );
    is( users_line( $d, 'alice' ) =~ /^alice:/ ? 1 : 0, 1, 'the account is intact' );
}

# --- me-sessions / me-session-revoke ---------------------------------------------------
{
    my ( $d, $c ) = site();
    my $r = api( $d, 'alice', 'me-sessions', undef, sid => $SID{A} );
    ok( $r->{ok}, 'me-sessions: ok' );
    my %s = map { $_->{sid} => $_ } @{ $r->{sessions} || [] };
    is_deeply( [ sort keys %s ], [ sort @SID{qw(A B)} ], 'me-sessions: alice\'s two, never bob\'s' );
    ok( $s{ $SID{A} }{current}, 'me-sessions: this session is marked' );

    my $bobs = api( $d, 'alice', 'me-session-revoke', { sid => $SID{C} }, sid => $SID{A} );
    my $none = api( $d, 'alice', 'me-session-revoke', { sid => 'f' x 16 }, sid => $SID{A} );
    ok( !$bobs->{ok}, 'me-session-revoke: bob\'s session is not alice\'s to end' );
    is( $bobs->{error}, $none->{error},
        'me-session-revoke: another account\'s id answers exactly as an id that does not exist' );
    is( $bobs->{kind}, 'not-found', 'me-session-revoke: not found, never forbidden' );
    is( signed_in( $d, $c->{C} ), 'bob', 'me-session-revoke: bob is still signed in' );

    my $own = api( $d, 'alice', 'me-session-revoke', { sid => $SID{B} }, sid => $SID{A} );
    ok( $own->{ok}, 'me-session-revoke: alice ends her other session' );
    is( signed_in( $d, $c->{B} ), '',      'me-session-revoke: it is signed out' );
    is( signed_in( $d, $c->{A} ), 'alice', 'me-session-revoke: this one is not' );
}

# --- me-sign-out-everywhere -----------------------------------------------------------
{
    my ( $d, $c ) = site();
    my $r = api( $d, 'alice', 'me-sign-out-everywhere', {}, sid => $SID{A} );
    ok( $r->{ok}, 'me-sign-out-everywhere: ok' );
    is( signed_in( $d, $c->{A} ), '',    'everywhere: this session ends too' );
    is( signed_in( $d, $c->{B} ), '',    'everywhere: and the other' );
    is( signed_in( $d, $c->{C} ), 'bob', 'everywhere: bob is untouched' );
}

# --- account_page: disabled -------------------------------------------------------------
{
    my ( $d, $c ) = site("account_page: disabled\n");
    for my $a (qw(me me-sessions)) {
        my $r = api( $d, 'alice', $a, undef, sid => $SID{A} );
        is( $r->{kind}, 'disabled', "$a: off when the page is off" );
        like( $r->{error} // '', qr/account_page/, "$a: and names the setting" );
    }
    my $p = api( $d, 'alice', 'me-password',
        { current_password => $ALICE, new_password => 'alice-second-password' }, sid => $SID{A} );
    is( $p->{kind}, 'disabled', 'me-password: off when the page is off' );
}

# --- defence in depth: the module refuses on its own ------------------------------------
# The dispatcher already refuses a token (no me-* action is in the token gate) and
# an empty account. The module asks again, so a future caller that reaches it
# some other way gets the same answer.
{
    my ( $d, $c ) = site();
    require Lazysite::Manager::Common;
    require Lazysite::Manager::Account;
    no warnings 'once';
    local $Lazysite::Manager::Account::DOCROOT      = $d;
    local $Lazysite::Manager::Account::LAZYSITE_DIR = "$d/lazysite";
    # Assigned, not localised: `local` would give Common a NEW scalar and leave
    # the one Account imported (the same glob, aliased at import) untouched.
    $Lazysite::Manager::Common::auth_user  = 'alice';
    $Lazysite::Manager::Common::token_auth = 1;
    my $r = Lazysite::Manager::Account::action_me();
    is( $r->{kind}, 'forbidden', 'in process: a token caller is refused by the module itself' );
    like( $r->{error} // '', qr/access key/, 'in process: refused as a token, not as nobody' );
    $Lazysite::Manager::Common::token_auth = 0;
    $Lazysite::Manager::Common::auth_user  = '';
    $r = Lazysite::Manager::Account::action_me_sessions();
    is( $r->{kind}, 'forbidden', 'in process: no account asking, no sessions' );
}

done_testing;
