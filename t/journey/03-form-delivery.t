#!/usr/bin/perl
# Journey: a contact form page is rendered, submitted, and the
# submission lands in the file-storage handler's destination.
#
# Exercises: form rendering with ts/token, form-handler POST
# validation (honeypot, timestamp, HMAC token), file-storage
# dispatch, JSONL write.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP qw(decode_json);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );

mkdir "$docroot/lazysite";
mkdir "$docroot/lazysite/forms";
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: J3\n";
close $cf;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF\n";
close $nf;

# Form page declares form: contact, body has the :::form block
open my $pf, '>', "$docroot/contact.md" or die $!;
print $pf <<'EOF';
---
title: Contact
form: contact
---
::: form
name | Your name | required
email | Your email | required email
message | Message | textarea
submit | Send
:::
EOF
close $pf;

# Form config: one target, file handler, writing to a path under
# the forms dir so we can inspect the submission on disk.
open my $hc, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print $hc <<EOF;
handlers:
  - id: jsonl
    type: file
    name: Local storage
    enabled: true
    path: $docroot/form-submissions
EOF
close $hc;

open my $fc, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print $fc "targets:\n  - handler: jsonl\n";
close $fc;

# --- 1. Render the form to harvest a valid _ts/_tk pair ---
my ( $ts, $tk );
{
    my $proc = "$root/lazysite-processor.pl";
    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REDIRECT_URL   => '/contact',
        REQUEST_METHOD => 'GET',
        QUERY_STRING   => '',
    );
    my $out = qx($^X \Q$proc\E 2>/dev/null);
    like( $out, qr/<form/, 'form rendered' );
    like( $out, qr/name="_ts"/, '_ts hidden field present' );
    like( $out, qr/name="_tk"/, '_tk hidden field present' );
    ( $ts ) = $out =~ /name="_ts"\s+value="(\d+)"/;
    ( $tk ) = $out =~ /name="_tk"\s+value="([0-9a-f]{64})"/;
    ok( $ts && $tk, 'extracted ts and tk from rendered form' );
}

# Must be at least 3 seconds old to pass the "too fast" check
sleep 4;

# --- 2. POST to form-handler ---
{
    my $body = join '&',
        "_form=contact",
        "_ts=$ts",
        "_tk=$tk",
        "_hp=",
        "name=Ada+Lovelace",
        "email=ada\@example.com",
        "message=Hello+world";

    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => '127.0.0.1',
        QUERY_STRING   => '',
    );

    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin,
        $^X, "$root/plugins/form-handler.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;

    like( $out, qr/Status: 200 OK/, 'form POST → 200' );
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $r = decode_json($out);
    is( $r->{ok}, 1, 'form response ok' );
}

# --- 3. Submission landed on disk as JSONL ---
{
    my $log = "$docroot/form-submissions/contact.jsonl";
    ok( -f $log, 'submissions JSONL created' );
    open my $fh, '<', $log or die $!;
    my $line = <$fh>;
    close $fh;
    my $rec = decode_json($line);
    is( $rec->{name},    'Ada Lovelace',    'name field recorded' );
    is( $rec->{email},   'ada@example.com', 'email field recorded' );
    is( $rec->{message}, 'Hello world',     'message field recorded' );
    is( $rec->{_form},   'contact',          'form name tagged' );
    ok( $rec->{_submitted} =~ /^\d{4}-\d{2}-\d{2}T/, 'timestamp recorded' );
}

# --- 4. Replay the same _ts/_tk pair (would pass age check again,
#        but token-lockout is not enforced - this test just documents
#        current behaviour, not a claim about idempotency) ---
{
    my $body = "_form=contact&_ts=$ts&_tk=$tk&_hp=&name=X&email=x\@x.com&message=Y";
    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => '127.0.0.1',
    );
    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin,
        $^X, "$root/plugins/form-handler.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $r = decode_json($out);
    # Current behaviour: same token is accepted while within window.
    # Replay protection is not in scope for this journey; this
    # assertion pins what the code does today.
    is( $r->{ok}, 1, 'replay of valid token currently accepted' );
}

# --- 5. Honeypot non-empty → rejected ---
{
    my $body = "_form=contact&_ts=$ts&_tk=$tk&_hp=GOT+YOU&name=X&email=x\@x.com&message=Y";
    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => '127.0.0.1',
    );
    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin,
        $^X, "$root/plugins/form-handler.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $r = decode_json($out);
    is( $r->{ok}, 0, 'honeypot-filled → rejected' );
}

done_testing();
