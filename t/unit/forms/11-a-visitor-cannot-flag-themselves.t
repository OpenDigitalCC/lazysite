#!/usr/bin/perl
# SM523: the quarantine markers are ENGINE-OWNED. A visitor who posts
# _quarantined=1&_spam_reason=... must not mute their own notification, put
# their own reason on the stored record, or be counted as quarantined - the
# flags exist so the operator can trust what the ENGINE decided.
#
# Two posts through the real handler as a subprocess: an honest one and a
# self-flagged one. Both must be stored clean, both must ring the bell, both
# must be recorded as `stored` in form-events.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/forms");
make_path("$docroot/lazysite/logs");
my $SECRET = 'b' x 64;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} $SECRET;
close $fs;
open my $hc, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hc} "handlers:\n  - id: jsonl\n    type: file\n    name: Local\n"
    . "    enabled: true\n    path: $docroot/subs\n";
close $hc;
open my $fc, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$fc} "targets:\n  - handler: jsonl\n";
close $fc;

my $ip = 0;

sub post {
    my ($body) = @_;
    my $bf = "$docroot/.body";
    open my $b, '>:raw', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.' . ( ++$ip ),
        HTTP_ACCEPT    => 'application/json',
    );
    my $out = qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

my $ts = time - 10;
my $tk = hmac_sha256_hex( $ts, $SECRET );
like( post("_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Ada"), qr/"ok":1/,
    'an honest post is accepted' );
like(
    post(     "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=Bob"
            . "&_quarantined=1&_spam_reason=visitor-chosen&_ip=1.2.3.4" ),
    qr/"ok":1/,
    'a self-flagged post is accepted (the flags are simply not the visitor\'s)'
);

open my $rf, '<', "$docroot/subs/contact.jsonl" or BAIL_OUT('no records written');
my @rows = map { decode_json($_) } <$rf>;
close $rf;
is( scalar @rows, 2, 'two records stored' );
my ($bob) = grep { $_->{name} eq 'Bob' } @rows;
ok( $bob, 'the self-flagged submission was stored' );
ok( !exists $bob->{_quarantined}, 'the visitor\'s _quarantined did not reach the record' );
ok( !exists $bob->{_spam_reason}, 'nor their _spam_reason' );
isnt( $bob->{_ip}, '1.2.3.4', 'nor their _ip: the engine records the address it saw' );

my $notices = 0;
if ( open my $nf, '<', "$docroot/lazysite/logs/notices.jsonl" ) {
    $notices++ while <$nf>;
    close $nf;
}
is( $notices, 2, 'the bell rang for both posts' );

my ($ev) = glob("$docroot/lazysite/stats/form-events/*.jsonl");
ok( $ev, 'form-events were recorded' );
my $events = do { local $/; open my $ef, '<', $ev or die $!; <$ef> };
unlike( $events, qr/quarantined/, 'no outcome was recorded as quarantined' );
is( scalar( () = $events =~ /stored/g ), 2, 'both outcomes are stored' );

done_testing();
