#!/usr/bin/perl
# SM1352: a member lists, adds and removes their OWN passkeys on /account, and an
# operator can only remove all of an account's passkeys, for a lost phone.
#
#   me-passkeys          the list, and whether this site can use passkeys
#   me-passkey-begin     the current password (when the account has one), then a
#                        challenge for this account
#   me-passkey-add       the browser's answer, verified against that challenge
#   me-passkey-remove    one of mine
#   users passkey-wipe   the operator's: every passkey goes, the sessions with them,
#                        and the audit records it
# A manager cannot add or remove one passkey for somebody (the manager API refuses
# the verbs, the users tool refuses an actor that is not the account), and
# without CryptX the actions say what is missing.
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

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require PasskeyFixture;

my $root   = repo_root();
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1352-secret-' x 3;
my $SID    = 'c' x 16;
my $PW     = 'alice-first-password';
my $HOST   = 'site.example';
my $ORIGIN = "https://$HOST";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body, %o ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => ( $post ? 'POST' : 'GET' ),
        QUERY_STRING          => "action=$action",
        CONTENT_LENGTH        => length($json),
        REMOTE_ADDR           => '192.0.2.36',
        HTTP_HOST             => $HOST,
        HTTPS                 => 'on',
        HTTP_X_REMOTE_USER    => $who, HTTP_X_REMOTE_GROUPS => ( $o{groups} // '' ),
        LAZYSITE_AUTH_TRUSTED => 1,
        LAZYSITE_AUTH_SID     => $SID,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
        %{ $o{env} || {} },
    );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
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
uapi( $d, { action => 'add', username => 'deleg', password => 'deleg-first-password' } );
grant_caps( $d, 'op',    'ui', 'manage_users' );
grant_caps( $d, 'deleg', 'ui', 'create_sub_users' );

my $list = api( $d, 'alice', 'me-passkeys' );
ok( $list->{ok} && $list->{available}, 'me-passkeys: this site can use passkeys' ) or diag explain $list;
is_deeply( $list->{passkeys}, [], 'and alice has none' );

# --- begin: the current password first --------------------------------------------------------------
my $no = api( $d, 'alice', 'me-passkey-begin', { current_password => 'not-it-at-all' } );
is( $no->{field}, 'current_password', 'begin: the wrong current password is refused' );
ok( !exists $no->{challenge}, 'and no challenge is issued' );
my $b = api( $d, 'alice', 'me-passkey-begin', { current_password => $PW } );
ok( $b->{ok} && length( $b->{challenge} // '' ), 'begin: the current password gives a challenge' ) or diag explain $b;
is( $b->{rp_id}, $HOST, 'for this host' );
is( PasskeyFixture::b64u('alice'), $b->{user_id}, 'and the user handle is the account' );

# --- add: the answer must answer that challenge ------------------------------------------------------
my $k  = PasskeyFixture::key(-7);
my %ok = PasskeyFixture::created( $k, challenge => $b->{challenge}, origin => $ORIGIN, rp => $HOST, label => 'my phone' );
my $bad = api( $d, 'alice', 'me-passkey-add', { %ok, client_data => PasskeyFixture::b64u('{}') } );
ok( !$bad->{ok}, 'add: an answer whose client data is not an enrolment is refused' );
$bad = api( $d, 'alice', 'me-passkey-add',
    { PasskeyFixture::created( $k, challenge => $b->{challenge}, origin => $ORIGIN, rp => $HOST, flags => 0x04 ) } );
like( $bad->{error} // '', qr/present/, 'add: an authenticator that did not see the person is refused' );

my $bob_k = PasskeyFixture::key(-7);
my $bb = api( $d, 'op', 'me-passkey-begin', { current_password => 'op-first-password' } );
my $add = api( $d, 'alice', 'me-passkey-add',
    { PasskeyFixture::created( $bob_k, challenge => $bb->{challenge}, origin => $ORIGIN, rp => $HOST ) } );
like( $add->{error} // '', qr/another account/, 'add: a challenge issued to another account is refused' );

$b = api( $d, 'alice', 'me-passkey-begin', { current_password => $PW } );
%ok = PasskeyFixture::created( $k, challenge => $b->{challenge}, origin => $ORIGIN, rp => $HOST, label => 'my phone' );
$add = api( $d, 'alice', 'me-passkey-add', \%ok );
ok( $add->{ok}, 'add: the right answer adds the passkey' ) or diag explain $add;
my $replay = api( $d, 'alice', 'me-passkey-add', { %ok, id => PasskeyFixture::key(-7)->{id} } );
like( $replay->{error} // '', qr/already used|not issued/, 'add: the same answer again is refused - its challenge is spent' );
$list = api( $d, 'alice', 'me-passkeys' );
is( scalar @{ $list->{passkeys} }, 1, 'me-passkeys lists it' );
is( $list->{passkeys}[0]{label}, 'my phone', 'with its label' );
ok( !exists $list->{passkeys}[0]{key}, 'and not its key - nothing a page does not need' );

$b = api( $d, 'alice', 'me-passkey-begin', { current_password => $PW } );
my $k2 = PasskeyFixture::key(-8);
ok( api( $d, 'alice', 'me-passkey-add',
        { PasskeyFixture::created( $k2, challenge => $b->{challenge}, origin => $ORIGIN, rp => $HOST ) } )->{ok},
    'add: a second passkey (Ed25519)' );
is_deeply( [ sort @{ api( $d, 'alice', 'me-passkey-begin', { current_password => $PW } )->{exclude} } ],
    [ sort ( $k->{id}, $k2->{id} ) ], 'begin names the passkeys she holds, so a phone does not enrol twice' );

# --- remove: mine only --------------------------------------------------------------------------------
my $rm = api( $d, 'op', 'me-passkey-remove', { id => $k->{id} } );
is( $rm->{kind}, 'not-found', 'remove: another account\'s passkey id is not one of mine' );
$rm = api( $d, 'alice', 'me-passkey-remove', { id => $k2->{id} } );
ok( $rm->{ok}, 'remove: alice removes her own' );
is( scalar @{ api( $d, 'alice', 'me-passkeys' )->{passkeys} }, 1, 'and one is left' );

# --- a manager adds and removes nothing for somebody else ------------------------------------------------
for my $verb (qw(passkey-add passkey-remove passkey-used)) {
    my $r = api( $d, 'op', 'users', { action => $verb, username => 'alice', id => $k->{id},
            passkey => PasskeyFixture::stored( PasskeyFixture::key(-7) ) }, groups => 'role-op' );
    is( $r->{kind}, 'forbidden', "manager API: '$verb' is refused to a user manager" );
}
my $tool = uapi( $d, { action => 'passkey-add', username => 'alice', actor => 'op',
        passkey => PasskeyFixture::stored( PasskeyFixture::key(-7) ) } );
is( $tool->{kind}, 'forbidden', 'users tool: an actor that is not the account cannot add one' );

# --- the operator's wipe -----------------------------------------------------------------------------------
my $dw = api( $d, 'deleg', 'users', { action => 'passkey-wipe', username => 'alice' }, groups => 'role-deleg' );
ok( !$dw->{ok}, 'a delegated sub-user manager cannot wipe' );
{
    open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
    print $rf encode_json( { sid => 'd' x 16, user => 'alice', t => time - 60, ip => '', ua => '' } ) . "\n";
    close $rf;
}
my $w = api( $d, 'op', 'users', { action => 'passkey-wipe', username => 'alice' }, groups => 'role-op' );
ok( $w->{ok}, 'the operator wipes alice\'s passkeys' ) or diag explain $w;
is( $w->{removed}, 1, 'and is told how many' );
is_deeply( api( $d, 'alice', 'me-passkeys' )->{passkeys}, [], 'she has none' );
{
    open my $fh, '<', "$d/lazysite/auth/revoked.json" or die "no revoked store: $!";
    my $rv = do { local $/; <$fh> };
    close $fh;
    like( $rv, qr/alice/, 'and her sessions are signed out (a lost phone is usually signed in)' );
    open my $af, '<', "$d/lazysite/logs/audit.log" or die $!;
    my $log = do { local $/; <$af> };
    close $af;
    like( $log, qr/\|\s*op\s*\|.*passkey-wipe/, 'the audit records the operator\'s wipe' );
}

# --- without CryptX ------------------------------------------------------------------------------------------
my $shadow = tempdir( CLEANUP => 1 );
make_path("$shadow/Crypt/PK");
{
    open my $fh, '>', "$shadow/Crypt/PK/ECC.pm" or die $!;
    print {$fh} "die qq{not installed (test shadow)\\n};\n";
    close $fh;
}
my %hide = ( env => { PERL5LIB => join ':', $shadow, ( $ENV{PERL5LIB} // () ) } );
my $nl = api( $d, 'alice', 'me-passkeys', undef, %hide );
ok( $nl->{ok} && !$nl->{available}, 'without CryptX me-passkeys says passkeys are unavailable' );
like( $nl->{needs} // '', qr/libcryptx-perl/, 'and what is needed' );
my $nb = api( $d, 'alice', 'me-passkey-begin', { current_password => $PW }, %hide );
is( $nb->{kind}, 'unavailable', 'and begin refuses, saying the same' );

done_testing();
