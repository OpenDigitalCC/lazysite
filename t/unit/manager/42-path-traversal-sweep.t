#!/usr/bin/perl
# ADVERSARIAL (breadth pass 2026-07): a driven sweep of EVERY path-taking control
# action against directory-traversal payloads. The shared validate_path() confines
# writes/reads strictly under the docroot (SEC-2026-07 H3), and t/lint/15 pins
# that each handler calls it - this test proves the behaviour end-to-end for every
# action at once, so a new path-taking action that forgets the guard is caught by
# a leaked/overwritten sibling file rather than by review alone.
#
# Layout: docroot is $base/site; a secret sits OUTSIDE it at $base/secret.txt.
# No action may read it (leak SENTINEL), overwrite it, or delete it via '../'.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;
my $SENT   = 'OUTSIDE-DOCROOT-SENTINEL';

# Raw call to the manager-API (returns the whole response incl. headers).
sub call {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}        = $d;
    $ENV{REQUEST_METHOD}       = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}       = defined $body ? length($body) : 0;
    $ENV{HTTP_X_REMOTE_USER}   = 'admin';
    $ENV{HTTP_X_REMOTE_GROUPS} = 'managers';
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:admin:" . int( time() / 3600 ), $secret );
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{$_} = $o{$_} for grep { defined $o{$_} && /^[A-Z]/ } keys %o;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    return $out // '';
}
sub json_of { my ($jb) = $_[0] =~ /\r?\n\r?\n(.*)/s; eval { decode_json( $jb // '' ) } // {} }

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/site";
make_path( "$d/lazysite/auth", "$d/sub" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\nmanager: enabled\nmanager_groups: managers\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;
open my $pg, '>', "$d/page.md" or die $!;
print $pg "---\ntitle: P\n---\n\nhello\n";
close $pg;

# the out-of-tree secret
open my $sk, '>', "$base/secret.txt" or die $!;
print $sk "$SENT\n";
close $sk;

my @traversals = ( '../secret.txt', '../../secret.txt', 'sub/../../secret.txt' );

# --- reads / downloads must not leak the out-of-tree secret --------------------
for my $p (@traversals) {
    for my $act (qw(read file-download file-zip-download)) {
        my $out = call( $d, QUERY_STRING => "action=$act&path=" . _enc($p) );
        unlike( $out, qr/\Q$SENT\E/,
            "$act '$p' does not leak the out-of-tree secret" );
    }
}

# --- writes / deletes / moves must not escape the docroot ----------------------
for my $p (@traversals) {
    # save: try to plant content outside
    my $s = json_of(
        call( $d, REQUEST_METHOD => 'POST', QUERY_STRING => "action=save&path=" . _enc($p),
            body => encode_json( { content => 'PWNED-BY-TRAVERSAL' } ) ) );
    ok( !$s->{ok}, "save '$p' is refused (no write outside the docroot)" );

    # move / copy the in-tree page OUT of the tree
    for my $act (qw(move copy)) {
        my $r = json_of(
            call( $d, REQUEST_METHOD => 'POST',
                QUERY_STRING => "action=$act&path=/page.md&to=" . _enc($p), body => '{}' ) );
        ok( !$r->{ok}, "$act to '$p' is refused" );
    }

    # delete: try to remove the out-of-tree secret
    my $del = json_of(
        call( $d, REQUEST_METHOD => 'POST', QUERY_STRING => "action=delete&path=" . _enc($p),
            body => '{}' ) );
    ok( !$del->{ok}, "delete '$p' is refused" );

    # mkdir outside
    my $mk = json_of(
        call( $d, REQUEST_METHOD => 'POST', QUERY_STRING => "action=mkdir&path=" . _enc("$p.dir"),
            body => '{}' ) );
    ok( !$mk->{ok}, "mkdir '$p.dir' is refused" );
}

# --- the out-of-tree secret survived intact: never read, moved, or deleted -----
ok( -f "$base/secret.txt", 'the out-of-tree secret still exists (nothing deleted it)' );
open my $rf, '<', "$base/secret.txt" or die $!;
my $still = do { local $/; <$rf> };
close $rf;
like( $still, qr/\Q$SENT\E/, 'the out-of-tree secret is unmodified (nothing overwrote it)' );

# --- F1 (2026-07 audit): ".." that RE-ENTERS a blocklisted IN-docroot subtree.
# realpath keeps these inside the docroot (so the H3 boundary check passes), but
# the raw request string starts with "sub/", not "lazysite/", so the blocklist -
# which string-matches on rel - used to miss it. That was the bypass that read
# lazysite/auth/.secret (cookie-signing secret -> operator-cookie forgery) and
# wrote into lazysite/auth. validate_path now rejects any ".." segment AND
# canonicalises rel, so every handler refuses it.
{
    for my $p ( 'sub/../lazysite/auth/.secret', 'sub/../lazysite/lazysite.conf' ) {
        for my $act (qw(read file-download file-zip-download)) {
            my $out = call( $d, QUERY_STRING => "action=$act&path=" . _enc($p) );
            unlike( $out, qr/\Q$secret\E/,
                "$act '$p' does not leak an in-docroot secret ('..' re-entry blocked)" );
        }
    }
    # the read action returns an explicit refusal, not the file
    my $r = json_of( call( $d, QUERY_STRING => "action=read&path=" . _enc('sub/../lazysite/auth/.secret') ) );
    ok( !$r->{ok}, "read 'sub/../lazysite/auth/.secret' is refused" );

    # WRITE into the protected tree via '..' is refused, and nothing lands there
    my $w = json_of(
        call( $d, REQUEST_METHOD => 'POST',
            QUERY_STRING => "action=save&path=" . _enc('sub/../lazysite/canary.txt'),
            body => encode_json( { content => 'PWNED-INTO-LAZYSITE' } ) ) );
    ok( !$w->{ok}, "save 'sub/../lazysite/canary.txt' is refused (no write into lazysite/)" );
    ok( !-e "$d/lazysite/canary.txt", 'no canary written into the protected lazysite/ tree' );
}

sub _enc {
    my $s = shift;
    $s =~ s/([^A-Za-z0-9._~-])/sprintf '%%%02X', ord $1/ge;
    return $s;
}

done_testing();
