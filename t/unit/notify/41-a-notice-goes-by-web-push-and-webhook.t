#!/usr/bin/perl
# SM1363 (rulings 187, 188): `webpush` and `webhook` are routes in Notify's route
# table, beside xmpp and email, and reach the account the notice names when its
# record chooses them (`notify_routes`, beside notify_email).
#
#   - webhook: through the named connector notify.conf's webhook.connector names -
#     its secret header, its call record - with the notice's kind, title, the
#     account and the link, and never the message (ruling 188: SMS goes this way)
#   - webpush: an EMPTY POST to each of the account's devices, VAPID-signed with the
#     site's own key (a JWT whose audience is the endpoint's origin, verified here)
#   - a broadcast, and an account that did not choose the route, reach nobody
#   - every route's send is a line in the one send record (the bounds: t/unit/notify/42)
#   - every attempt is a log line with its outcome
#   - without CryptX, web push says what is missing and the webhook still goes
# Both destinations are a 127.0.0.1 fixture this test runs.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use File::Temp   qw(tempdir);
use IO::Socket::INET;
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require Lazysite::Notify;
require Lazysite::WebPush;
require Lazysite::Manager::Connectors;

my $root = repo_root();
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

# --- the fixture: one 127.0.0.1 listener for both routes, recording each request ----------
my $rec = tempdir( CLEANUP => 1 ) . '/requests.jsonl';
my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 10, ReuseAddr => 1 )
    or plan skip_all => "no 127.0.0.1 listener: $!";
my $port = $srv->sockport;
my $pid  = fork // die "fork: $!";
if ( !$pid ) {
    while ( my $c = $srv->accept ) {
        my ( $line, %h ) = ( scalar <$c> );
        while ( my $l = <$c> ) { last if $l =~ /^\r?\n\z/; $h{ lc $1 } = $2 if $l =~ /^([^:]+):\s*(.*?)\r?\n\z/ }
        my $body = '';
        read( $c, $body, $h{'content-length'} ) if $h{'content-length'};
        my ( $m, $p ) = split ' ', $line // '';
        open my $fh, '>>', $rec or exit 1;
        print {$fh} encode_json( { method => $m, path => $p, headers => \%h, body => $body } ) . "\n";
        close $fh;
        print {$c} "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
    }
    exit 0;
}
close $srv;
END { kill 'TERM', $pid if $pid }

sub requests { return [ map { decode_json($_) } grep { length } split /\n/, slurp($rec) ] }

# --- the site ------------------------------------------------------------------------------
my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/connectors" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://site.example\n" );
sub notify_conf { spit( "$d/lazysite/notify.conf", "route.submission: bell,webpush,webhook\nwebhook.connector: sms\n" . ( $_[0] // '' ) ) }
notify_conf();
spit( "$d/lazysite/auth/users", "alice:x\nbob:x\n" );
spit( "$d/lazysite/auth/user-settings.json", encode_json( {
            alice => { notify_routes => 'webpush,webhook',
                push => [ { endpoint => "http://127.0.0.1:$port/push/alice-phone", t => time } ] },
            bob => { push => [ { endpoint => "http://127.0.0.1:$port/push/bob-phone", t => time } ] },
} ) );
{
    my ( $c, $err ) = Lazysite::Manager::Connectors::normalise( {
            name => 'SMS gateway', url => "http://127.0.0.1:$port/hook", data_class => 'fixed',
            modes => { scheduled => 1, authenticated => 0 } } );
    die $err unless $c;
    spit( "$d/lazysite/connectors/connectors.json", encode_json( { sms => $c } ) );
    spit( "$d/lazysite/connectors/secrets.json",    encode_json( { sms => 'gw-secret' } ) );
}

$Lazysite::WebPush::LOOPBACK_OK = 1;
my $LOG = "$d/stderr.log";
sub notice {
    my (%n) = @_;
    open my $save, '>&', \*STDERR or die $!;
    open STDERR, '>>', $LOG or die $!;
    local $ENV{LAZYSITE_LOG_LEVEL} = 'DEBUG';
    my $ok = Lazysite::Notify::notify( $d, { type => 'submission', message => 'SECRET-CONTENT of the form',
            url => '/manager/forms?form=contact', %n } );
    open STDERR, '>&', $save or die $!;
    return $ok;
}

# --- one notice to alice: both routes ------------------------------------------------------------
ok( notice( to => 'alice' ), 'notify() answers as it always has' );
my @push = grep { $_->{path} =~ m{^/push/} } @{ requests() };
my @hook = grep { $_->{path} eq '/hook' } @{ requests() };
is( scalar @push, 1, 'web push: one request, to alice\'s device' );
is( $push[0]{path}, '/push/alice-phone', 'to the endpoint her browser handed over' );
is( $push[0]{method}, 'POST', 'a POST' );
is( $push[0]{body}, '', 'with no payload at all' );
ok( $push[0]{headers}{ttl}, 'and a TTL for the push service' );
my ( $jwt, $k ) = ( $push[0]{headers}{authorization} // '' ) =~ /\Avapid t=(\S+), k=(\S+)\z/;
ok( $jwt && $k, 'signed with VAPID (t= and k=)' );
{
    my ( $h, $c, $s ) = split /\./, $jwt // '';
    my $pub = Crypt::PK::ECC->new;
    $pub->import_key_raw( MIME::Base64::decode_base64url($k), 'secp256r1' );
    ok( $pub->verify_message_rfc7518( MIME::Base64::decode_base64url($s), "$h.$c", 'SHA256' ),
        'the JWT verifies with the key it names (ES256)' );
    my $claims = decode_json( MIME::Base64::decode_base64url($c) );
    is( $claims->{aud}, "http://127.0.0.1:$port", 'its audience is the endpoint\'s origin' );
    ok( $claims->{exp} > time && $claims->{exp} <= time + 24 * 3600, 'and it expires within a day' );
    is( $k, ( Lazysite::WebPush::public_key($d) )[0], 'the key is the site\'s own, the one a device subscribes with' );
}
ok( -f "$d/lazysite/auth/webpush-vapid.pem", 'the key is kept under lazysite/' );

is( scalar @hook, 1, 'webhook: one call, through the connector' );
is( $hook[0]{headers}{authorization}, 'Bearer gw-secret', 'carrying the connector\'s own secret header' );
my $body = decode_json( $hook[0]{body} );
is( $body->{account}, 'alice', 'naming the account' );
is( $body->{notice},  'submission', 'and the kind of notice' );
is( $body->{url}, 'https://site.example/manager/forms?form=contact', 'with the link, made absolute' );
unlike( $hook[0]{body}, qr/SECRET-CONTENT/, 'and never the notice\'s message' );
like( slurp("$d/lazysite/connectors/calls.jsonl"), qr/"connector":"sms".*"trigger":"notice:submission"/,
    'the call is in the connector\'s own record' );

my $log = slurp($LOG);
like( $log, qr/notice sent by webpush/, 'log: the web push attempt and its outcome' );
like( $log, qr/notice pushed .*device=127\.0\.0\.1/, 'log: each device pushed' );
like( $log, qr/notice sent by webhook/, 'log: the webhook attempt and its outcome' );
my @sent = map { decode_json($_) } grep { length } split /\n/, slurp("$d/lazysite/logs/notice-mail.jsonl");
is_deeply( [ sort map { $_->{route} } @sent ], [qw(webhook webpush)], 'the one send record names each route' );

# --- who it does not reach -------------------------------------------------------------------------
my $before = scalar @{ requests() };
notice( to => 'bob' );
notice();
is( scalar @{ requests() }, $before, 'bob did not choose the routes, and a broadcast reaches nobody: nothing sent' );
$log = slurp($LOG);
like( $log, qr/notice not sent by webpush.*has not chosen notices by webpush/, 'log: bob\'s refusal, with its reason' );
like( $log, qr/notice not sent by webhook.*broadcast/, 'log: the broadcast\'s' );

# --- without CryptX ----------------------------------------------------------------------------------
my $shadow = tempdir( CLEANUP => 1 );
make_path("$shadow/Crypt/PK");
spit( "$shadow/Crypt/PK/ECC.pm", "die qq{not installed (test shadow)\\n};\n" );
$before = scalar @{ requests() };
my $child = run_child( [ $^X, '-I', $shadow, '-I', "$root/lib", '-e',
        'require Lazysite::Notify; require Lazysite::WebPush; $Lazysite::WebPush::LOOPBACK_OK = 1; '
            . 'Lazysite::Notify::notify( $ARGV[0], { type => "submission", message => "m", to => "alice" } )', $d ],
    stderr => 'merge' );
like( $child->{out} // '', qr/notice not sent by webpush.*libcryptx-perl/, 'no CryptX: web push says what is missing' );
is( scalar( grep { $_->{path} eq '/hook' } @{ requests() } ) - scalar(@hook), 1,
    'and the webhook still goes, needing nothing of it' );

done_testing();
