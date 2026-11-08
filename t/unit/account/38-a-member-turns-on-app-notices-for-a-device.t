#!/usr/bin/perl
# SM1363: a member turns app notices (web push) on and off for their OWN devices
# on /account; the route choice is one account field, notify_routes, beside
# notify_email.
#
#   me-push              whether this site can push, the key a browser subscribes
#                        with, this account's devices and routes
#   me-push-subscribe    an https endpoint; the device is kept, and webpush joins
#                        notify_routes
#   me-push-unsubscribe  the device goes; with the last one, webpush leaves
#   notify_routes        webpush and/or webhook, set by an operator (a webhook may
#                        cost the site money); anything else is refused
# A manager cannot turn a device on for somebody, and without CryptX the actions
# say what is missing.
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

my $root   = repo_root();
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1363-secret-' x 3;
my $EP     = 'https://push.example.net/send/abc123';

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
        REMOTE_ADDR           => '192.0.2.38',
        HTTP_X_REMOTE_USER    => $who, HTTP_X_REMOTE_GROUPS => ( $o{groups} // '' ),
        LAZYSITE_AUTH_TRUSTED => 1,
        ( $post ? ( HTTP_X_CSRF_TOKEN => csrf($who) ) : () ),
        %{ $o{env} || {} },
    );
    my $out = run_child( [ $^X, $mapi ], stdin => $json )->{out};
    my ($jb) = ( $out // '' ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub record {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/user-settings.json" or die $!;
    my $all = decode_json( do { local $/; <$fh> } );
    close $fh;
    return $all->{$u} || {};
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

my $p = api( $d, 'alice', 'me-push' );
ok( $p->{ok} && $p->{available}, 'me-push: this site can push' ) or diag explain $p;
like( $p->{key} // '', qr/\A[A-Za-z0-9_-]{80,}\z/, 'and gives the key a browser subscribes with' );
is_deeply( $p->{devices}, [], 'alice has no devices yet' );

my $bad = api( $d, 'alice', 'me-push-subscribe', { endpoint => 'http://push.example.net/x' } );
is( $bad->{field}, 'endpoint', 'an endpoint that is not https is refused' );
$bad = api( $d, 'alice', 'me-push-subscribe', { endpoint => 'https://push.example.net/' . ( 'x' x 1100 ) } );
is( $bad->{field}, 'endpoint', 'and an endpoint of any length is not stored' );

my $on = api( $d, 'alice', 'me-push-subscribe', { endpoint => $EP } );
ok( $on->{ok}, 'me-push-subscribe: the device is added' ) or diag explain $on;
is_deeply( record( $d, 'alice' )->{push}[0]{endpoint}, $EP, 'its endpoint is in her record' );
is( record( $d, 'alice' )->{notify_routes}, 'webpush', 'and webpush joins her notify_routes' );
is_deeply( api( $d, 'alice', 'me-push' )->{devices}, [$EP], 'me-push lists it' );

my $mgr = api( $d, 'op', 'users', { action => 'push-subscribe', username => 'alice', endpoint => $EP . '2' },
    groups => 'role-op' );
is( $mgr->{kind}, 'forbidden', 'manager API: a manager cannot turn a device on for somebody' );
my $tool = uapi( $d, { action => 'push-subscribe', username => 'alice', actor => 'op', endpoint => $EP . '2' } );
is( $tool->{kind}, 'forbidden', 'users tool: nor can an actor that is not the account' );

# --- notify_routes: an operator's setting, two values ----------------------------------------------
my $self = uapi( $d, { action => 'settings-set', username => 'alice', actor => 'alice', key => 'notify_routes',
        value => 'webpush,webhook' } );
ok( !$self->{ok}, 'notify_routes is not a self-service setting (a webhook may cost the site money)' );
my $junk = uapi( $d, { action => 'settings-set', username => 'alice', key => 'notify_routes', value => 'webpush,sms' } );
like( $junk->{error} // '', qr/webpush and\/or webhook/, 'a route that is not one is refused, naming the two' );
ok( uapi( $d, { action => 'settings-set', username => 'alice', key => 'notify_routes', value => 'webpush,webhook' } )->{ok},
    'the operator adds the webhook route' );
is( record( $d, 'alice' )->{notify_routes}, 'webpush,webhook', 'one field holds the choice' );

# --- off ---------------------------------------------------------------------------------------------
my $off = api( $d, 'alice', 'me-push-unsubscribe', { endpoint => $EP } );
ok( $off->{ok}, 'me-push-unsubscribe: the device is removed' );
ok( !exists record( $d, 'alice' )->{push}, 'no device is left' );
is( record( $d, 'alice' )->{notify_routes}, 'webhook', 'and webpush leaves notify_routes, the webhook stays' );

# --- without CryptX -------------------------------------------------------------------------------------
my $shadow = tempdir( CLEANUP => 1 );
make_path("$shadow/Crypt/PK");
{
    open my $fh, '>', "$shadow/Crypt/PK/ECC.pm" or die $!;
    print {$fh} "die qq{not installed (test shadow)\\n};\n";
    close $fh;
}
my %hide = ( env => { PERL5LIB => join ':', $shadow, ( $ENV{PERL5LIB} // () ) } );
my $np = api( $d, 'alice', 'me-push', undef, %hide );
ok( $np->{ok} && !$np->{available}, 'without CryptX me-push says app notices are unavailable' );
like( $np->{needs} // '', qr/libcryptx-perl/, 'and what is needed' );
is( api( $d, 'alice', 'me-push-subscribe', { endpoint => $EP }, %hide )->{kind}, 'unavailable',
    'and a device cannot be turned on' );

# --- the app's worker shows a pushed notice, reading nothing from it --------------------------------
{
    my $s = site_tempdir();
    system( 'cp', '-r', "$root/starter/.", $s ) == 0 or die 'copy starter';
    make_path("$s/lazysite/cache");
    open my $cf, '>', "$s/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Probe\napp_name: Probe App\n";
    close $cf;
    my $sw = TestHelper::run_processor( $s, '/lazysite-sw.js' );
    like( $sw, qr/addEventListener\('push'.*showNotification\(CFG\.name/s, 'the worker shows a pushed notice under the app\'s name' );
    my ($pushl) = $sw =~ /(addEventListener\('push'.*?\n\}\);)/s;
    unlike( $pushl // 'event.data', qr/\.data\b/, 'reading nothing from the push: it carries nothing' );
    like( $sw, qr/"notices":"\/account"/, 'and a tap opens the account\'s notices' );
    like( $sw, qr/addEventListener\('notificationclick'.*openWindow\(CFG\.notices/s, 'from the notification click' );
}

done_testing();
