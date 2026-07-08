#!/usr/bin/perl
# SM136: the shared operator-notification write path (Lazysite::Notify) - the
# bell-store append, and XMPP delivery gating (only when the notify-xmpp plugin is
# enabled AND configured; strictly best-effort).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Notify qw(notify);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/logs");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

# Capture XMPP sends instead of talking to a server.
my @sent;
local $Lazysite::Notify::XMPP_SENDER = sub { push @sent, [@_]; 1 };

# --- bell-store append ---
ok( notify( $d, { type => 'submission', message => "New form submission: contact",
    target => 'contact', url => '/manager/plugins' } ), 'notify returns true' );
open my $nf, '<', "$d/lazysite/logs/notices.jsonl" or die $!;
my @lines = <$nf>;
close $nf;
is( scalar @lines, 1, 'one notice appended' );
my $rec = decode_json( $lines[0] );
is( $rec->{type},    'submission',                    'type recorded' );
is( $rec->{message}, 'New form submission: contact',  'message recorded' );
ok( $rec->{ts} > 0, 'timestamp recorded' );

# --- newlines are flattened (one JSONL record per notice) ---
notify( $d, { message => "line one\nline two" } );
open $nf, '<', "$d/lazysite/logs/notices.jsonl" or die $!;
@lines = <$nf>;
close $nf;
is( scalar @lines, 2, 'still one line per notice' );
like( decode_json( $lines[1] )->{message}, qr/line one line two/, 'newlines flattened' );

# --- no XMPP attempt while the plugin is not enabled ---
is( scalar @sent, 0, 'no XMPP send while the notify-xmpp plugin is disabled' );

# --- enabled + configured -> the sender is called with the conf and message ---
open $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: My Test Site!\nplugins:\n  - notify-xmpp.pl\n";
close $cf;
open my $xc, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
print $xc "jid: sitebot\@example.com\npassword: s3cret\nto: ops\@example.com\n";
close $xc;
ok( notify( $d, { type => 'reset-request', message => 'Password reset requested' } ),
    'notify ok with XMPP configured' );
is( scalar @sent, 1, 'XMPP sender invoked once' );
is( $sent[0][0]{to},  'ops@example.com',            'sender got the recipient' );
is( $sent[0][0]{jid}, 'sitebot@example.com',        'sender got the client jid' );
like( $sent[0][1], qr/Password reset requested/,    'sender got the message text' );
is( $sent[0][0]{nick}, 'My-Test-Site',
    'sender nick defaults to the sanitised site name' );

# --- an explicit nick in the conf wins over the site-name default ---
open $xc, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
print $xc "jid: sitebot\@example.com\npassword: s3cret\nto: ops\@example.com\nnick: opsbot\n";
close $xc;
notify( $d, { message => 'nick check' } );
is( $sent[-1][0]{nick}, 'opsbot', 'an explicit nick is honoured' );

# --- a failing sender never breaks notify (best-effort) ---
{
    local $Lazysite::Notify::XMPP_SENDER = sub { die "server unreachable\n" };
    ok( notify( $d, { message => 'still records' } ), 'notify ok despite XMPP failure' );
}
open $nf, '<', "$d/lazysite/logs/notices.jsonl" or die $!;
@lines = <$nf>;
close $nf;
is( scalar @lines, 5, 'the notice was still appended to the bell store' );

# --- incomplete conf (no recipient) -> no send attempted ---
open $xc, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
print $xc "jid: sitebot\@example.com\npassword: s3cret\n";
close $xc;
@sent = ();
notify( $d, { message => 'x' } );
is( scalar @sent, 0, 'no send without a recipient configured' );

done_testing();
