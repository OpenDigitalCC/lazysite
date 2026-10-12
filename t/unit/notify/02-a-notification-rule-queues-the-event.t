#!/usr/bin/perl
# SM1019 (SM1010 phase 1): A NOTIFICATION RULE BOUND AS A FORM'S SECOND TARGET
# QUEUES THE EVENT AND RETURNS - through the real CGI.
#
# The visitor never waits on the sends (the daemon's notify-outbox job does
# them, SM1020): delivering a notify handler writes one outbox entry naming the
# rule, the event's visible fields and who caused it, and nothing else.
#
# And a QUARANTINED submission notifies nobody, asked of the delivery context -
# the lesson SM1017 paid for.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough run_cmd);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
plan skip_all => "no $handler" unless -f $handler;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/auth" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n"
        . "  - id: store\n    type: file\n    name: Store\n"
        . "  - id: followers\n    type: notify\n    name: Followers\n"
        . "    recipients: [{\"fixed\":[\"office\@example.org\"]}]\n"
        . "    unsubscribe_path: /account/following\n" );
spit( "$d/lazysite/forms/comment.conf",
    "spam_dwell: off\ntargets:\n  - handler: store\n  - handler: followers\n" );
spit( "$d/lazysite/auth/.secret",  'a' x 64 );
spit( "$d/lazysite/forms/.secret", 'b' x 64 );
run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, 'add', 'zz9member', 'pw123456789' );

my $OUTBOX = "$d/lazysite/notify/outbox";

sub entries {
    opendir my $dh, $OUTBOX or return ();
    my @f = sort grep { /\.json\z/ } readdir $dh;
    closedir $dh;
    return map { JSON::PP::decode_json( slurp("$OUTBOX/$_") ) } @f;
}

my $n = 0;

sub post {
    my ( $body_fields, %extra ) = @_;
    $n++;
    my $ts   = time - 10;
    my $tk   = hmac_sha256_hex( $ts, 'b' x 64 );
    my $body = "_form=comment&$body_fields&_hp=&_ts=$ts&_tk=$tk";
    spit( "$d/.body", $body );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => "203.0.113.$n",
        %extra,
    );
    return scalar qx($^X \Q$handler\E < \Q$d/.body\E 2>/dev/null);
}

sub cookie {
    my $pay = "zz9member:" . time . ':';
    return "lazysite_auth=$pay:" . hmac_sha256_hex( $pay, 'a' x 64 );
}

subtest 'a clean post queues one entry, and the visitor is answered' => sub {
    like( post( 'post=p1&comment=Nice+piece', HTTP_COOKIE => cookie() ), qr/"ok":1/, 'answered ok' );
    my @e = entries();
    is( scalar @e,    1,           'one outbox entry' );
    is( $e[0]{rule},  'followers', 'naming the rule' );
    is( $e[0]{actor}, 'zz9member', 'and who caused it - the verified member (SM1018)' );
    is_deeply( $e[0]{fields}, { post => 'p1', comment => 'Nice piece' }, 'and the event\'s fields' );
    like( $e[0]{id}, qr/\A[0-9a-f]{16}\z/, 'with an event id' );
    is( $e[0]{attempts}, 0, 'not yet attempted - nothing was sent in the request' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/form:comment -> followers \| [^|]* \| ok/,
        'the delivery is one audit row, ok' );
};

subtest 'a quarantined post queues nothing' => sub {
    post('post=p1&comment=Buy+at+https://a.example.biz+and+https://b.example.info+and+https://c.example.top');
    is( scalar( () = entries() ), 1, 'still one entry - the spam queued nothing' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/followers .*quarantine/,
        'and the delivery record says why' );
};

done_testing();
