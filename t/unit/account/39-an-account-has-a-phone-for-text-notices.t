#!/usr/bin/perl
# SM1363, ruling 196: an account may carry a phone number, for the webhook route
# (text messages) alone.
#   - international form, E.164-ish: a +, a country code not starting with 0, 8 to 15
#     digits; spaces, dots, dashes and brackets are dropped; anything else is refused
#   - the person sets their own on /account (me-phone, a self-service key); an operator
#     sets it on the Users page (users settings-set); empty clears
#   - me reports it to the account; the webhook body carries it (t/unit/notify/41)
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps run_child);

my $root   = repo_root();
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'r196-secret-' x 3;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ], stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub api {
    my ( $d, $who, $action, $body, %o ) = @_;
    my $post = defined $body;
    my $json = $post ? encode_json($body) : '';
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => ( $post ? 'POST' : 'GET' ), QUERY_STRING => "action=$action",
        CONTENT_LENGTH => length($json), REMOTE_ADDR => '192.0.2.39',
        HTTP_X_REMOTE_USER => $who, HTTP_X_REMOTE_GROUPS => ( $o{groups} // '' ), LAZYSITE_AUTH_TRUSTED => 1,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ) );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub phone_of {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/user-settings.json" or die $!;
    my $all = decode_json( do { local $/; <$fh> } );
    close $fh;
    return $all->{$u}{phone};
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
uapi( $d, { action => 'add', username => 'alice', password => 'alice-first-password' } );
uapi( $d, { action => 'add', username => 'op',    password => 'op-first-password' } );
grant_caps( $d, 'op', 'ui', 'manage_users' );

# --- the form ---------------------------------------------------------------------------------
for my $bad ( '07700 900123', '+0 7700 900123', '+44 77ab 900123', '+12345', '+4477009001234567' ) {
    my $r = uapi( $d, { action => 'settings-set', username => 'alice', key => 'phone', value => $bad } );
    ok( !$r->{ok}, "refused: '$bad'" );
}
like( uapi( $d, { action => 'settings-set', username => 'alice', key => 'phone', value => 'nope' } )->{error} // '',
    qr/international form/, 'and the refusal says how to write one' );
ok( uapi( $d, { action => 'settings-set', username => 'alice', key => 'phone', value => '+44 20 7946 0000' } )->{ok},
    'the users tool takes a number written the way people write them' );
is( phone_of( $d, 'alice' ), '+442079460000', 'and keeps it in one form' );

# --- the person, on /account ---------------------------------------------------------------------
my $set = api( $d, 'alice', 'me-phone', { phone => '+1 415 555 0132' } );
ok( $set->{ok}, 'me-phone: alice sets her own' ) or diag explain $set;
is( phone_of( $d, 'alice' ), '+14155550132', 'it is in her record' );
is( api( $d, 'alice', 'me' )->{phone}, '+14155550132', 'and me reports it to her' );
my $bad = api( $d, 'alice', 'me-phone', { phone => '555 0132' } );
is( $bad->{field}, 'phone', 'me-phone: a number not in international form is refused, naming the field' );
is( phone_of( $d, 'alice' ), '+14155550132', 'and the one she had is kept' );
ok( api( $d, 'alice', 'me-phone', { phone => '' } )->{ok}, 'me-phone: empty clears it' );
ok( !defined phone_of( $d, 'alice' ), 'and it is gone' );

# --- an operator, on the Users page ----------------------------------------------------------------
my $op = api( $d, 'op', 'users', { action => 'settings-set', username => 'alice', key => 'phone', value => '+33 1 23 45 67 89' },
    groups => 'role-op' );
ok( $op->{ok}, 'an operator sets it through the users action' ) or diag explain $op;
is( phone_of( $d, 'alice' ), '+33123456789', 'in the same form' );
is( uapi( $d, { action => 'settings-get', username => 'alice' } )->{settings}{phone}, '+33123456789',
    'and the Users page reads it back' );

done_testing();
