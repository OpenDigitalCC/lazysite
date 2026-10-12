#!/usr/bin/perl
# SM1040 (ruled 2026-10-12, "Fix now"): any password change - the account's
# own, an operator's passwd, a redeemed setup or reset link - and any 2FA
# disable signs out every OTHER session of that account; the session making the
# change stays signed in.
#
# Before this, a password change wrote the new hash and nothing else, so a
# stolen session survived the change it prompted (SM1034, "Changing one's
# password today"). Each case below mints that account's sessions by hand,
# changes the credential through a real door, and asks the auth wrapper - the
# one place a cookie is verified - which sessions still sign in.
#
#   1  users tool passwd (API, no session to keep): every session ends,
#      the legacy one included; another account is untouched
#   2  passwd keeping the caller's session: that one stays, the others end
#   3  a later sign-out-everywhere ends the kept session too
#   4  a redeemed setup link ends every session
#   5  2FA disable keeps the caller's and ends the others; disabling nothing
#      ends nothing
#   6  the manager API: an operator changing their OWN password keeps their
#      session; a keep_sid in the request body is ignored, so an operator
#      resetting someone else cannot keep that person's session alive
#   7  the Sessions listing agrees with the verifier about the kept session
#   8  the CLI passwd revokes too
#   9  a revocation that cannot be written changes nothing: the password
#      stays the old one
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps);

my $root   = repo_root();
my $auth   = "$root/lazysite-auth.pl";
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1040-secret-' x 3;
my %SID    = ( A => 'a' x 16, B => 'b' x 16, C => 'c' x 16, O1 => '0' x 16, O2 => '1' x 16 );

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
print $stf <<'STUB';
#!/usr/bin/perl
print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";
print "USER=", ( $ENV{HTTP_X_REMOTE_USER} // '' ), "\n";
STUB
close $stf;

# Does this cookie still sign in? Asked of the auth wrapper itself.
sub signed_in {
    my ( $d, $cookie ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REDIRECT_URL       => '/',
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => '',
        REMOTE_ADDR        => '127.0.0.1',
        LAZYSITE_PROCESSOR => $stub,
        HTTP_COOKIE        => "lazysite_auth=$cookie",
    );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $auth );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    return ( $out // '' ) =~ /^USER=(\S+)$/m ? $1 : '';
}

sub cookie {
    my ($payload) = @_;
    return $payload . ':' . hmac_sha256_hex( $payload, $secret );
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => 'POST',
        CONTENT_LENGTH        => length($body),
        LAZYSITE_AUTH_TRUSTED => 1,
        %o );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w $body;
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# A site with alice (three sessions: A, B and a legacy one), bob (C), and an
# operator op (O1, O2). Every session was issued a minute ago.
sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
    for my $u (qw(alice bob op)) {
        uapi( $d, { action => 'add', username => $u, password => "$u-first-password" } );
    }
    grant_caps( $d, 'op', 'ui', 'manage_users' );
    my $ts = time() - 60;
    my %c  = (
        A      => cookie("alice:$ts:$SID{A}:"),
        B      => cookie("alice:$ts:$SID{B}:"),
        legacy => cookie("alice:$ts:"),
        C      => cookie("bob:$ts:$SID{C}:"),
        O1     => cookie("op:$ts:$SID{O1}:role-op"),
        O2     => cookie("op:$ts:$SID{O2}:role-op"),
    );
    open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
    for my $k (qw(A B C O1 O2)) {
        my $user = $k eq 'C' ? 'bob' : $k =~ /^O/ ? 'op' : 'alice';
        print $rf encode_json( { sid => $SID{$k}, user => $user, t => $ts, ip => '', ua => '' } ) . "\n";
    }
    close $rf;
    return ( $d, \%c );
}

sub users_line {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or die $!;
    my ($l) = grep {/^\Q$u\E:/} <$fh>;
    close $fh;
    return $l // '';
}

# --- 0. the fixture signs in ------------------------------------------------------
{
    my ( $d, $c ) = site();
    is( signed_in( $d, $c->{$_} ), ( $_ eq 'C' ? 'bob' : $_ =~ /^O/ ? 'op' : 'alice' ),
        "fixture: session $_ signs in before anything changes" )
        for qw(A B legacy C O1);
}

# --- 1. passwd with no session to keep ends them all --------------------------------
{
    my ( $d, $c ) = site();
    my $r = uapi( $d, { action => 'passwd', username => 'alice', password => 'alice-second-password' } );
    ok( $r->{ok}, 'passwd: the password changes' ) or diag explain $r;
    is( signed_in( $d, $c->{A} ),      '', 'passwd: session A is signed out' );
    is( signed_in( $d, $c->{B} ),      '', 'passwd: session B is signed out' );
    is( signed_in( $d, $c->{legacy} ), '', 'passwd: a legacy cookie with no session id is signed out' );
    is( signed_in( $d, $c->{C} ), 'bob', 'passwd: another account keeps its session' );
}

# --- 2/3. passwd keeping the caller's session; then sign out everywhere -------------
{
    my ( $d, $c ) = site();
    my $r = uapi( $d, { action => 'passwd', username => 'alice',
            password => 'alice-second-password', keep_sid => $SID{A} } );
    ok( $r->{ok}, 'passwd keeping A: ok' );
    is( signed_in( $d, $c->{A} ), 'alice', 'passwd keeping A: A stays signed in' );
    is( signed_in( $d, $c->{B} ), '',      'passwd keeping A: B is signed out' );
    is( signed_in( $d, $c->{legacy} ), '', 'passwd keeping A: the legacy cookie is signed out' );

    my $s = mapi( $d, QUERY_STRING => 'action=sessions-list', REQUEST_METHOD => 'GET',
        body => '', HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    my %live = map { $_->{sid} => 1 } @{ $s->{sessions} || [] };
    ok( $live{ $SID{A} },  'listing: the kept session is listed, as the verifier admits it' );
    ok( !$live{ $SID{B} }, 'listing: the ended session is not listed' );

    my $u = mapi( $d, QUERY_STRING => 'action=user-revoke',
        body => encode_json( { username => 'alice' } ),
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        HTTP_X_CSRF_TOKEN  => csrf('op') );
    ok( $u->{ok}, 'sign out everywhere: ok' ) or diag explain $u;
    is( signed_in( $d, $c->{A} ), '', 'sign out everywhere ends the session a password change kept' );
}

# --- 4. a redeemed link ends every session --------------------------------------------
{
    my ( $d, $c ) = site();
    my $cl = uapi( $d, { action => 'claim-create', username => 'alice' } );
    ok( $cl->{claim}, 'claim issued' ) or diag explain $cl;
    my $r = uapi( $d, { action => 'claim-redeem', username => 'alice', claim => $cl->{claim},
            password => 'alice-claimed-password' } );
    ok( $r->{ok}, 'claim redeemed' ) or diag explain $r;
    is( signed_in( $d, $c->{A} ), '', 'redeemed link: session A is signed out' );
    is( signed_in( $d, $c->{B} ), '', 'redeemed link: session B is signed out' );
    is( signed_in( $d, $c->{C} ), 'bob', 'redeemed link: another account is untouched' );
}

# --- 5. 2FA disable ------------------------------------------------------------------
{
    my ( $d, $c ) = site();
    my $none = uapi( $d, { action => 'mfa-disable', username => 'alice' } );
    ok( $none->{ok}, 'disabling 2FA that was never enrolled: ok' );
    is( signed_in( $d, $c->{B} ), 'alice', 'nothing was turned off, so nothing is signed out' );

    uapi( $d, { action => 'mfa-enroll', username => 'alice' } );
    my $r = uapi( $d, { action => 'mfa-disable', username => 'alice', keep_sid => $SID{A} } );
    ok( $r->{ok}, '2FA disable keeping A: ok' );
    is( signed_in( $d, $c->{A} ), 'alice', '2FA disable: the session that made it stays' );
    is( signed_in( $d, $c->{B} ), '',      '2FA disable: the other session is signed out' );
}

# --- 6. the manager API keeps only the caller's own session ---------------------------
{
    my ( $d, $c ) = site();
    my $own = mapi( $d, QUERY_STRING => 'action=users',
        body => encode_json( { action => 'passwd', username => 'op', password => 'op-second-password' } ),
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        HTTP_X_CSRF_TOKEN  => csrf('op'), LAZYSITE_AUTH_SID => $SID{O1} );
    ok( $own->{ok}, 'manager API: an operator changes their own password' ) or diag explain $own;
    is( signed_in( $d, $c->{O1} ), 'op', 'manager API: the session that changed it stays' );
    is( signed_in( $d, $c->{O2} ), '',   'manager API: their other session is signed out' );

    my $other = mapi( $d, QUERY_STRING => 'action=users',
        body => encode_json( { action => 'passwd', username => 'alice',
                password => 'alice-reset-by-op', keep_sid => $SID{A} } ),
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        HTTP_X_CSRF_TOKEN  => csrf('op'), LAZYSITE_AUTH_SID => $SID{O1} );
    ok( $other->{ok}, 'manager API: the operator resets alice' ) or diag explain $other;
    is( signed_in( $d, $c->{A} ), '',
        'manager API: a keep_sid in the body keeps nothing - alice\'s session A ends' );
    is( signed_in( $d, $c->{O1} ), 'op',
        'manager API: resetting someone else leaves the operator signed in' );
}

# --- 8. the CLI ------------------------------------------------------------------------
{
    my ( $d, $c ) = site();
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utl, '--docroot', $d, 'passwd', 'alice', 'alice-cli-password' );
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    like( $out, qr/Password updated/, 'CLI passwd: ok' );
    is( signed_in( $d, $c->{A} ), '', 'CLI passwd: the account\'s sessions are signed out' );
}

# --- 9. a revocation that cannot be written changes nothing ---------------------------
SKIP: {
    skip 'root ignores file modes', 3 if $> == 0;
    my ( $d, $c ) = site();
    my $before = users_line( $d, 'alice' );
    my $lock   = "$d/lazysite/auth/revoked.json.lock";
    open my $lf, '>', $lock or die $!;
    close $lf;
    chmod 0000, $lock;
    my $r = uapi( $d, { action => 'passwd', username => 'alice', password => 'alice-second-password' } );
    chmod 0600, $lock;
    ok( !$r->{ok}, 'unwritable revocation: the change is refused' );
    like( $r->{error} // '', qr/nothing was changed/, 'unwritable revocation: it says nothing changed' );
    is( users_line( $d, 'alice' ), $before, 'unwritable revocation: the password is the old one' );
}

done_testing;
