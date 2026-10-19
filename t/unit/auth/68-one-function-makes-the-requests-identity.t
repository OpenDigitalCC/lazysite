#!/usr/bin/perl
# SM1181 S1 (SM1082 C2): THE REQUEST'S IDENTITY IS MADE BY ONE FUNCTION, AS A VALUE.
#
# Lazysite::Auth::Session::request_session is SM1130's rule moved out of the auth
# wrapper: a trusted proxy's user wins, otherwise the session cookie - which it takes
# as an ARGUMENT, so the pool's front door (S3) can hand it the request's header
# rather than an environment it does not own. The wrapper and the data endpoint call
# it (t/integration/290 holds them to one answer); this pins the function itself:
#
#   - the cookie it verifies is the one passed in, never $ENV{HTTP_COOKIE};
#   - groups are the verifier's fresh ones less those the address is refused for
#     (SM1140), the same filter the identity reader applies;
#   - $STORE_FAULT (SM1024) is the verifier's answer about THIS call: a fault on one
#     request does not survive into the next, whichever path the next one takes;
#   - Lazysite::Auth::Identity::write_identity_env writes the wrapper's header
#     contract (SM794: produce or clear every trusted field) from the value, and
#     writes nothing for a value that is not a cookie session's.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session ();
use Lazysite::Auth::Identity ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';    # the broken-store WARNs below are expected

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path("$lz/auth");
no warnings 'once';
$Lazysite::Auth::Session::LAZYSITE_DIR = $lz;
use warnings 'once';

my $SECRET = 'a' x 64;
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
spit( "$lz/lazysite.conf", "site_name: T\n" );
spit( "$lz/auth/.secret", "$SECRET\n" );
spit( "$lz/auth/users",  "alice:x\nbob:x\nnopw:\n" );
spit( "$lz/auth/groups", "staff: alice\noffice-only: alice\neditors: bob\n" );

sub cookie {
    my ( $user, $sid ) = @_;
    my $payload = join ':', $user, time(), ( defined $sid ? ( $sid, 'baked' ) : ('baked') );
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
}
my $NOPROXY = { trusted => 0 };

sub session {
    my (%o) = @_;
    return Lazysite::Auth::Session::request_session( lazysite_dir => $lz, proxy => $NOPROXY, %o );
}

subtest 'the cookie verified is the argument, not the environment' => sub {
    local $ENV{HTTP_COOKIE} = cookie('bob');
    my ( $v, $why ) = session( cookie => cookie( 'alice', 'abcdef0123456789' ) );
    ok( $v, 'verified' ) or return diag $why;
    is( $v->{user},   'alice',            'the argument\'s account, not the environment\'s' );
    is( $v->{source}, 'cookie',           'a cookie session' );
    is( $v->{sid},    'abcdef0123456789', 'with its sid' );
    is_deeply( $v->{groups}, [ 'staff', 'office-only' ], 'and fresh groups, as a list (never the baked ones)' );
    ( $v, $why ) = session( cookie => '' );
    is( $v,   undef,       'an empty argument is no cookie, whatever the environment carries' );
    is( $why, 'no-cookie', 'and says so' );
    ok( !eval { Lazysite::Auth::Session::request_session( lazysite_dir => $lz, proxy => $NOPROXY ); 1 },
        'a caller that passes no cookie argument at all is refused, not read from %ENV' );
    like( $@, qr/cookie/, 'naming the missing argument' );
};

subtest 'a passwordless account is flagged in the value' => sub {
    my ($v) = session( cookie => cookie('nopw') );
    ok( $v && $v->{no_password}, 'no_password is the verifier\'s read of the store' );
    ($v) = session( cookie => cookie('alice') );
    ok( !$v->{no_password}, 'and an account with a password is not flagged' );
};

subtest 'groups go through the address filter the reader applies' => sub {
    spit( "$lz/auth/address-lists.json",
        encode_json( { office => { kind => 'allow', entries => [ { cidr => '198.51.100.0/24', note => 'HQ' } ] } } ) );
    spit( "$lz/auth/groups-settings.json", encode_json( { 'office-only' => { addresses => ['office'] } } ) );
    local $ENV{REQUEST_METHOD} = 'GET';
    local $ENV{REMOTE_ADDR}    = '198.51.100.4';
    my ($v) = session( cookie => cookie('alice') );
    is_deeply( $v->{groups}, [ 'staff', 'office-only' ], 'from inside the list, both groups' );
    local $ENV{REMOTE_ADDR} = '203.0.113.9';
    ($v) = session( cookie => cookie('alice') );
    is_deeply( $v->{groups}, ['staff'], 'from outside it, the limited group does not count' );
    unlink "$lz/auth/groups-settings.json", "$lz/auth/address-lists.json";
};

subtest 'a trusted proxy user wins, and the cookie is not consulted' => sub {
    spit( "$lz/lazysite.conf", "site_name: T\nauth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8\n" );
    local $ENV{REMOTE_ADDR}          = '10.1.2.3';
    local $ENV{HTTP_X_REMOTE_USER}   = 'carol';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'Staff';
    my ($v) = Lazysite::Auth::Session::request_session( lazysite_dir => $lz, cookie => cookie('alice') );
    is( $v->{user},   'carol', 'the proxy\'s user' );
    is( $v->{source}, 'proxy', 'as a proxy identity' );
    is_deeply( $v->{groups}, ['staff'], 'with the proxy\'s groups, read the reader\'s way' );
    is( $v->{sid}, '', 'and no sid: it is not a lazysite session' );
    local $ENV{HTTP_X_REMOTE_USER} = '';
    ($v) = Lazysite::Auth::Session::request_session( lazysite_dir => $lz, cookie => cookie('alice') );
    is( $v->{user}, 'alice', 'a trusted peer that names nobody leaves the cookie to decide' );
    spit( "$lz/lazysite.conf", "site_name: T\n" );
};

subtest '$STORE_FAULT from one call does not reach the next' => sub {
    spit( "$lz/auth/revoked.json", '{ not json' );
    my ( $v, $why, %detail ) = session( cookie => cookie('alice') );
    is( $why,           'cannot-tell',               'a broken store: cannot tell' );
    is( $detail{store}, 'lazysite/auth/revoked.json', 'naming it' );
    is( $Lazysite::Auth::Session::STORE_FAULT, 'lazysite/auth/revoked.json', 'the fault is recorded for this call' );
    unlink "$lz/auth/revoked.json";

    ( $v, $why ) = session( cookie => '' );
    is( $why, 'no-cookie', 'the next request carries no cookie' );
    is( $Lazysite::Auth::Session::STORE_FAULT, '', 'and the last request\'s fault is gone, though no stage ran' );

    spit( "$lz/auth/revoked.json", '{ not json' );
    session( cookie => cookie('alice') );
    unlink "$lz/auth/revoked.json";
    ($v) = session( cookie => cookie('bob') );
    is( $v->{user}, 'bob', 'a clean request for another account after a fault is that account' );
    is( $Lazysite::Auth::Session::STORE_FAULT, '', 'with no fault left over' );

    spit( "$lz/auth/revoked.json", '{ not json' );
    session( cookie => cookie('alice') );
    unlink "$lz/auth/revoked.json";
    local $ENV{HTTP_COOKIE} = '';
    Lazysite::Auth::Session::verify_session_cookie();
    is( $Lazysite::Auth::Session::STORE_FAULT, '', 'the verifier called on its own resets it too' );
};

subtest 'write_identity_env writes the wrapper\'s contract from a cookie value' => sub {
    local %ENV = (
        HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins', HTTP_X_REMOTE_NAME => 'Forged',
        HTTP_X_REMOTE_EMAIL => 'f@example.invalid', HTTP_X_PAYMENT_VERIFIED => '1', HTTP_X_PAYMENT_PAYER => 'f',
    );
    ok( Lazysite::Auth::Identity::write_identity_env(
            { user => 'alice', groups => [ 'staff', 'office-only' ], sid => 'abcdef0123456789',
                no_password => 1, source => 'cookie', name => '', email => '' } ),
        'written' );
    is( $ENV{HTTP_X_REMOTE_USER},        'alice',             'user produced' );
    is( $ENV{HTTP_X_REMOTE_GROUPS},      'staff,office-only', 'groups produced, comma-joined' );
    is( $ENV{LAZYSITE_AUTH_TRUSTED},     '1',                 'the sentinel set' );
    is( $ENV{LAZYSITE_AUTH_SID},         'abcdef0123456789',  'the sid passed on (SM141)' );
    is( $ENV{LAZYSITE_AUTH_NO_PASSWORD}, '1',                 'the passwordless flag passed on (SM1070)' );
    ok( !exists $ENV{$_}, "$_ cleared (SM794)" )
        for qw(HTTP_X_REMOTE_NAME HTTP_X_REMOTE_EMAIL HTTP_X_PAYMENT_VERIFIED HTTP_X_PAYMENT_PAYER);

    %ENV = ();
    Lazysite::Auth::Identity::write_identity_env(
        { user => 'odoo:pat', groups => [], sid => 'abcdef0123456789', odoo => 1,
            name => "Pat\x01 Smith", source => 'cookie' } );
    is( $ENV{HTTP_X_REMOTE_NAME}, 'Pat Smith', 'an Odoo session\'s name is produced, control characters dropped (SM1160)' );
    ok( !exists $ENV{LAZYSITE_AUTH_NO_PASSWORD}, 'and nothing flagged that the value does not say' );

    %ENV = ( HTTP_X_REMOTE_USER => 'carol' );
    ok( !Lazysite::Auth::Identity::write_identity_env( { user => 'carol', groups => [], source => 'proxy' } ),
        'a proxy value writes nothing: the proxy is the producer of its own headers' );
    is_deeply( \%ENV, { HTTP_X_REMOTE_USER => 'carol' }, 'the environment is as it was' );
    ok( !Lazysite::Auth::Identity::write_identity_env(undef), 'no value writes nothing' );
};

done_testing();
