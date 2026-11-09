#!/usr/bin/perl
# SM1363, rulings 195 and 199: two hourly bounds, counted from the one send record.
#   - webhook.per_hour (default 20) bounds the webhook route alone: spent, the
#     webhook is refused while web push still goes
#   - mail.per_hour (default 60) bounds every route but webhook: spent, web push is
#     refused while the webhook still goes
#   - a device whose push service answers 404 or 410 is removed from the account,
#     and with the last one webpush leaves notify_routes
# A 127.0.0.1 fixture stands in for the gateway and the push service; the push
# service answers 410 for one path.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require Lazysite::Notify;
require Lazysite::WebPush;
require Lazysite::Manager::Connectors;

my $root = repo_root();
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

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
        print {$fh} encode_json( { path => $p, body => $body } ) . "\n";
        close $fh;
        my $st = $p =~ m{/gone} ? '410 Gone' : '201 Created';
        print {$c} "HTTP/1.1 $st\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        close $c;
    }
    exit 0;
}
close $srv;
END { kill 'TERM', $pid if $pid }

sub count { my ($re) = @_; return scalar grep { $_->{path} =~ $re } map { decode_json($_) } grep { length } split /\n/, slurp($rec) }

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/connectors" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\nsite_url: https://site.example\n" );
spit( "$d/lazysite/auth/users", "alice:x\ncarol:x\n" );
sub accounts {
    spit( "$d/lazysite/auth/user-settings.json", encode_json( {
                alice => { notify_routes => 'webpush,webhook',
                    push => [ { endpoint => "http://127.0.0.1:$port/push/alice", t => time } ] },
                carol => { notify_routes => 'webpush',
                    push => [ { endpoint => "http://127.0.0.1:$port/push/gone", t => time } ] },
    } ) );
}
accounts();
{
    my ( $c, $err ) = Lazysite::Manager::Connectors::normalise( {
            name => 'SMS', url => "http://127.0.0.1:$port/hook", data_class => 'fixed',
            modes => { scheduled => 1, authenticated => 0 }, rate_per_hour => 0 } );
    die $err unless $c;
    spit( "$d/lazysite/connectors/connectors.json", encode_json( { sms => $c } ) );
}
sub conf {
    spit( "$d/lazysite/notify.conf", "route.submission: bell,webpush,webhook\nwebhook.connector: sms\n" . ( $_[0] // '' ) );
    unlink "$d/lazysite/logs/notice-mail.jsonl";
}

$Lazysite::WebPush::LOOPBACK_OK = 1;
$ENV{LAZYSITE_USERS_TOOL} = "$root/tools/lazysite-users.pl";
my $LOG = "$d/stderr.log";
sub notice {
    my ($to) = @_;
    open my $save, '>&', \*STDERR or die $!;
    open STDERR, '>>', $LOG or die $!;
    Lazysite::Notify::notify( $d, { type => 'submission', message => 'm', to => $to } );
    open STDERR, '>&', $save or die $!;
    return;
}

is( $Lazysite::Notify::DEFAULT_WEBHOOK_PER_HOUR, 20, 'the webhook bound is low by default: 20 an hour' );

# --- the webhook bound, spent: the webhook stops, the push does not ---------------------------
conf("webhook.per_hour: 2\n");
notice('alice') for 1 .. 3;
is( count(qr{^/hook$}),        2, 'webhook.per_hour: 2 - the third webhook is refused' );
is( count(qr{^/push/alice$}),  3, 'and every push still went: the mail bound was not spent' );
like( slurp($LOG), qr/notice not sent by webhook.*webhook\.per_hour/, 'the refusal names its own setting' );

# --- the mail bound, spent: the push stops, the webhook does not ---------------------------------
unlink $rec;
conf("mail.per_hour: 2\n");
notice('alice') for 1 .. 3;
is( count(qr{^/push/alice$}), 2, 'mail.per_hour: 2 - the third push is refused' );
is( count(qr{^/hook$}),       3, 'and every webhook still went: the webhook bound was not spent' );
like( slurp($LOG), qr/notice not pushed.*mail\.per_hour in notify\.conf \(it bounds every notice route but webhook\)/,
    'the refusal names the mail bound, and what it covers' );

# --- a device that has gone is removed -----------------------------------------------------------
conf();
notice('carol');
is( count(qr{^/push/gone$}), 1, 'the push service was asked once' );
my $all = decode_json( slurp("$d/lazysite/auth/user-settings.json") );
ok( !exists $all->{carol}{push}, 'it answered 410: the device is removed from carol\'s record' );
ok( !exists $all->{carol}{notify_routes}, 'and with her last device, webpush leaves notify_routes' );
like( slurp($LOG), qr/a device that unsubscribed was removed/, 'log: the removal' );
notice('carol');
is( count(qr{^/push/gone$}), 1, 'the next notice does not push into nothing' );
is_deeply( $all->{alice}{push}[0]{endpoint}, "http://127.0.0.1:$port/push/alice", 'alice\'s working device is untouched' );

done_testing();
