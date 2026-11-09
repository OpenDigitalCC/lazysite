#!/usr/bin/perl
# SM1352, ruling 199: an account that signs in by passkey only adds a passkey only
# after a FRESH ASSERTION by a passkey it already holds - never on its session alone.
#   - "passkey only": no password of its own (the locked marker a setup link leaves),
#     or a member of a passkey_only group
#   - me-passkey-begin without an assertion answers kind 'reauth' with a challenge
#     bound to the account, and issues no enrolment challenge
#   - refused: an assertion by another account's passkey, by a key the account does
#     not hold, to a challenge issued to another account, without user verification
#     (ruling 198), and the same assertion twice
#   - a good assertion gives the enrolment challenge, and the passkey is added
#   - an account with a password, in no such group, still gives its password
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require PasskeyFixture;

my $root   = repo_root();
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'r199-secret-' x 3;
my $HOST   = 'site.example';
my $ORIGIN = "https://$HOST";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ], stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => ( $post ? 'POST' : 'GET' ), QUERY_STRING => "action=$action",
        CONTENT_LENGTH => length($json), REMOTE_ADDR => '192.0.2.40', HTTP_HOST => $HOST, HTTPS => 'on',
        HTTP_X_REMOTE_USER => $who, HTTP_X_REMOTE_GROUPS => '', LAZYSITE_AUTH_TRUSTED => 1,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ) );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub assertion {
    my ( $k, $ch, %o ) = @_;
    my %a = PasskeyFixture::asserted( $k, challenge => $ch, origin => $ORIGIN, rp => $HOST, %o );
    return { id => $a{pk_id}, client_data => $a{pk_client_data},
        authenticator_data => $a{pk_authenticator_data}, signature => $a{pk_signature} };
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
uapi( $d, { action => 'add', username => $_, password => "$_-first-password" } ) for qw(carol dan erin);
{    # carol has no password of her own: the marker a passkey setup link leaves
    open my $in, '<', "$d/lazysite/auth/users" or die $!;
    my @l = map { /^carol:/ ? "carol:!passkey\n" : $_ } <$in>;
    close $in;
    open my $out, '>', "$d/lazysite/auth/users" or die $!;
    print {$out} @l;
    close $out;
}
uapi( $d, { action => 'group-create', group => 'phones' } );
uapi( $d, { action => 'group-add', username => 'dan', group => 'phones' } );
uapi( $d, { action => 'group-settings-set', group => 'phones', key => 'passkey_only', value => 'on' } );
my %K = map { $_ => PasskeyFixture::key(-7) } qw(carol dan erin stranger);
uapi( $d, { action => 'passkey-add', username => $_, passkey => PasskeyFixture::stored( $K{$_} ) } ) for qw(carol dan erin);

# --- no password: the session alone is not enough -----------------------------------------------
my $r = api( $d, 'carol', 'me-passkey-begin', {} );
is( $r->{kind}, 'reauth', 'no password: begin asks for a passkey first' );
ok( length( $r->{challenge} // '' ), 'with a challenge to answer' );
is_deeply( $r->{allow}, [ $K{carol}{id} ], 'naming the passkeys that may answer it' );
my $c1 = $r->{challenge};
is( api( $d, 'carol', 'me-passkey-begin', { current_password => 'anything' } )->{kind}, 'reauth',
    'a password changes nothing for an account that has none' );

my $no = api( $d, 'carol', 'me-passkey-begin', { assertion => assertion( $K{erin}, $c1, count => 1 ) } );
ok( !$no->{ok} && !$no->{challenge}, 'another account\'s passkey does not confirm carol' );
$r  = api( $d, 'carol', 'me-passkey-begin', {} );
$no = api( $d, 'carol', 'me-passkey-begin', { assertion => assertion( $K{stranger}, $r->{challenge}, id => $K{carol}{id}, count => 1 ) } );
ok( !$no->{ok} && !$no->{challenge}, 'nor does a key she does not hold, signing for her passkey id' );
my $er = api( $d, 'erin', 'me-passkey-begin', { current_password => 'erin-first-password' } );
$r  = api( $d, 'erin', 'me-passkey-begin', {} );
$no = api( $d, 'carol', 'me-passkey-begin', { assertion => assertion( $K{carol}, $er->{challenge}, count => 1 ) } );
ok( !$no->{ok}, 'nor an answer to a challenge issued to another account' );
$r  = api( $d, 'carol', 'me-passkey-begin', {} );
$no = api( $d, 'carol', 'me-passkey-begin', { assertion => assertion( $K{carol}, $r->{challenge}, count => 1, flags => 0x01 ) } );
ok( !$no->{ok}, 'ruling 198: nor an assertion without user verification' );

$r = api( $d, 'carol', 'me-passkey-begin', {} );
my $good = assertion( $K{carol}, $r->{challenge}, count => 2 );
my $b    = api( $d, 'carol', 'me-passkey-begin', { assertion => $good } );
ok( $b->{ok} && length( $b->{challenge} // '' ), 'a fresh assertion by her own passkey gives the enrolment challenge' )
    or diag explain $b;
ok( !api( $d, 'carol', 'me-passkey-begin', { assertion => $good } )->{ok}, 'the same assertion twice does not' );
my $new = PasskeyFixture::key(-7);
ok( api( $d, 'carol', 'me-passkey-add',
        { PasskeyFixture::created( $new, challenge => $b->{challenge}, origin => $ORIGIN, rp => $HOST ) } )->{ok},
    'and the new passkey is added' );

# --- a passkey_only group member: the password does not do it either ----------------------------
$r = api( $d, 'dan', 'me-passkey-begin', { current_password => 'dan-first-password' } );
is( $r->{kind}, 'reauth', 'passkey_only group: the right password still asks for a passkey' );
$b = api( $d, 'dan', 'me-passkey-begin', { assertion => assertion( $K{dan}, $r->{challenge}, count => 1 ) } );
ok( $b->{ok} && $b->{challenge}, 'and his passkey confirms him' );

# --- an ordinary account gives its password, as before ---------------------------------------------
ok( $er->{ok} && $er->{challenge}, 'an account with a password in no such group begins with the password' );

done_testing();
