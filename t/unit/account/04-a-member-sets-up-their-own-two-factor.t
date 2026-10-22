#!/usr/bin/perl
# SM1042 (SM1034 phase 1c, ruled 2026-10-12 "Self-enrol only"): a member sets up,
# confirms, turns off and re-keys their OWN two-factor on /account, and is the
# only one who ever sees its secret or recovery codes. A manager can reset it
# and nothing more - the manager API refuses every verb that would hand back a
# secret or a code, and the users tool refuses them for any actor that is not
# the account.
#
#   enrol: the current password; not while 2FA is on
#   confirm: a code from the app turns it on
#   recovery codes: the password AND a current code; the old codes stop working
#   disable: the password AND a current code; the other sessions end (SM1040)
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps run_child);

my $root   = repo_root();
my $auth   = "$root/lazysite-auth.pl";
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1042-secret-' x 3;
my %SID    = ( A => 'a' x 16, B => 'b' x 16 );
my $PW     = 'alice-first-password';

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
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
    my $out = run_child( [ $^X, $auth ] )->{out};
    return ( $out // '' ) =~ /^USER=(\S+)$/m ? $1 : '';
}

sub cookie { my ($p) = @_; return $p . ':' . hmac_sha256_hex( $p, $secret ) }
sub csrf   { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body, %o ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => ( $post ? 'POST' : 'GET' ),
        QUERY_STRING          => "action=$action",
        CONTENT_LENGTH        => length($json),
        REMOTE_ADDR           => '192.0.2.30',
        HTTP_X_REMOTE_USER    => $who, HTTP_X_REMOTE_GROUPS => ( $o{groups} // '' ),
        LAZYSITE_AUTH_TRUSTED => 1,
        ( $o{sid} ? ( LAZYSITE_AUTH_SID => $o{sid} )    : () ),
        ( $post   ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
    );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub totp_now {
    my ( $d, $sec ) = @_;
    return uapi( $d, { action => 'totp-code', secret => $sec, time => time() } )->{code};
}

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
}
uapi( $d, { action => 'add', username => 'alice', password => $PW } );
uapi( $d, { action => 'add', username => 'op',    password => 'op-first-password' } );
grant_caps( $d, 'op', 'ui', 'manage_users' );
my $ts = time() - 60;
my %c  = ( A => cookie("alice:$ts:$SID{A}:"), B => cookie("alice:$ts:$SID{B}:") );
open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
print $rf encode_json( { sid => $SID{$_}, user => 'alice', t => $ts, ip => '', ua => '' } ) . "\n" for qw(A B);
close $rf;

# --- a manager cannot enrol anybody, or see a code --------------------------------------
for my $verb (qw(mfa-enroll mfa-confirm mfa-recovery-regenerate mfa-verify)) {
    my $r = api( $d, 'op', 'users', { action => $verb, username => 'alice', code => '123456' },
        groups => 'role-op' );
    ok( !$r->{ok}, "manager API: '$verb' is refused to a user manager" );
    ok( !exists $r->{secret} && !exists $r->{recovery_codes}, "manager API: '$verb' hands back no secret" );
}
my $own = api( $d, 'op', 'users', { action => 'mfa-enroll', username => 'op' }, groups => 'role-op' );
ok( !$own->{ok}, 'manager API: not even for the manager\'s own account - that is /account too' );
my $tool = uapi( $d, { action => 'mfa-enroll', username => 'alice', actor => 'op' } );
is( $tool->{kind}, 'forbidden', 'users tool: an actor that is not the account cannot enrol it' );
ok( !exists $tool->{secret}, 'users tool: and gets no secret' );

# --- enrol ---------------------------------------------------------------------------------
my $no = api( $d, 'alice', 'me-2fa-enrol', { current_password => 'not-it-at-all' }, sid => $SID{A} );
ok( !$no->{ok},            'enrol: the wrong password is refused' );
ok( !exists $no->{secret}, 'enrol: and no secret leaves' );

my $en = api( $d, 'alice', 'me-2fa-enrol', { current_password => $PW }, sid => $SID{A} );
ok( $en->{ok}, 'enrol: the member sets up their own' ) or diag explain $en;
like( $en->{secret} // '', qr/\A[A-Z2-7]+\z/, 'enrol: the secret is shown to them, once' );
like( $en->{otpauth_uri} // '', qr{\Aotpauth://totp/}, 'enrol: with the URI for the QR' );
is( scalar @{ $en->{recovery_codes} || [] }, 8, 'enrol: and eight recovery codes' );
ok( api( $d, 'alice', 'me' )->{mfa_pending}, 'enrol: pending until confirmed' );

my $bad = api( $d, 'alice', 'me-2fa-confirm', { code => '000000' }, sid => $SID{A} );
ok( !$bad->{ok}, 'confirm: a wrong code does not turn it on' );
my $ok = api( $d, 'alice', 'me-2fa-confirm', { code => totp_now( $d, $en->{secret} ) }, sid => $SID{A} );
ok( $ok->{ok}, 'confirm: the app\'s code turns it on' ) or diag explain $ok;
ok( api( $d, 'alice', 'me' )->{mfa_enrolled}, 'it is on' );

my $again = api( $d, 'alice', 'me-2fa-enrol', { current_password => $PW }, sid => $SID{A} );
is( $again->{kind}, 'conflict', 'enrol: refused while it is on - a stolen session cannot swap the authenticator' );
ok( !exists $again->{secret}, 'enrol: and no new secret leaves' );

# --- recovery codes -----------------------------------------------------------------------
my @old = @{ $en->{recovery_codes} };
my $nocode = api( $d, 'alice', 'me-recovery-codes', { current_password => $PW, code => 'zzzzz-zzzzz' },
    sid => $SID{A} );
ok( !$nocode->{ok}, 'recovery codes: a wrong code is refused' );
my $rc = api( $d, 'alice', 'me-recovery-codes', { current_password => $PW, code => $old[0] },
    sid => $SID{A} );
ok( $rc->{ok}, 'recovery codes: the password and a recovery code make new ones' ) or diag explain $rc;
is( scalar @{ $rc->{recovery_codes} || [] }, 8, 'recovery codes: eight new ones' );
ok( !uapi( $d, { action => 'mfa-verify', username => 'alice', code => $old[1] } )->{ok},
    'recovery codes: an old one no longer works' );

# --- disable --------------------------------------------------------------------------------
my $pwonly = api( $d, 'alice', 'me-2fa-disable', { current_password => $PW }, sid => $SID{A} );
ok( !$pwonly->{ok}, 'disable: the password alone is not enough' );
is( $pwonly->{field},       'code',  'disable: it asks for the code' );
is( signed_in( $d, $c{B} ), 'alice', 'disable: a refused attempt signs nobody out' );

my $off = api( $d, 'alice', 'me-2fa-disable',
    { current_password => $PW, code => $rc->{recovery_codes}[0] }, sid => $SID{A} );
ok( $off->{ok}, 'disable: the password and a current code turn it off' ) or diag explain $off;
ok( !api( $d, 'alice', 'me' )->{mfa_enrolled}, 'it is off' );
is( signed_in( $d, $c{A} ), 'alice', 'disable: this session stays (SM1040)' );
is( signed_in( $d, $c{B} ), '',      'disable: the other session ends (SM1040)' );

# --- a manager can still reset it --------------------------------------------------------------
my $en2 = api( $d, 'alice', 'me-2fa-enrol', { current_password => $PW }, sid => $SID{A} );
api( $d, 'alice', 'me-2fa-confirm', { code => totp_now( $d, $en2->{secret} ) }, sid => $SID{A} );
my $reset = api( $d, 'op', 'users', { action => 'mfa-disable', username => 'alice' }, groups => 'role-op' );
ok( $reset->{ok}, 'manager API: a user manager can still reset (disable) a member\'s 2FA' );
ok( !api( $d, 'alice', 'me' )->{mfa_enrolled}, 'and it is off' );
is( signed_in( $d, $c{A} ), '', 'and every session of the member ends - the manager is not the member' );

# --- the Users page cannot show a secret any more ----------------------------------------------
{
    open my $fh, '<', "$root/starter/manager/users.md" or die $!;
    my $page = do { local $/; <$fh> };
    unlike( $page, qr/mfa-enroll|mfa-confirm|otpauth|recovery_codes/,
        'the Users page asks for no enrolment and shows no secret or code' );
    like( $page, qr/Reset 2FA/, 'and keeps the reset' );
}

done_testing;
