#!/usr/bin/perl
# Journey: full auth cycle through the auth wrapper.
#   1. Create a user via tools/lazysite-users.pl --api
#   2. POST /login via lazysite-auth.pl, receive a cookie
#   3. Use the cookie to hit a protected page: must 200
#   4. Hit the protected page without the cookie: must 302 to /login
#   5. rotate-auth-secret via manager-api with valid cookie: must
#      invalidate the cookie (same cookie now rejected)
#
# This exercises the whole auth stack end-to-end: user storage,
# password hashing, cookie HMAC, auth-wrapper handoff, trust gate
# in the processor, CSRF, and the secret rotation lever.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use IPC::Open2;
use JSON::PP qw(encode_json decode_json);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );

# --- Build a minimal docroot ---
mkdir "$docroot/lazysite";
mkdir "$docroot/lazysite/auth";
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: J2\nmanager: enabled\nmanager_groups: admins\n";
close $cf;
open my $pf, '>', "$docroot/protected.md" or die $!;
print $pf "---\ntitle: P\nauth: required\nauth_groups:\n  - admins\n---\nPROTECTED-BODY\n";
close $pf;
open my $lf, '>', "$docroot/login.md" or die $!;
print $lf "---\ntitle: Login\nauth: none\n---\nLogin\n";
close $lf;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF\n";
close $nf;

sub users_api {
    my ($payload) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin,
        $^X, "$root/tools/lazysite-users.pl",
        '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

# --- 1. Create a user in the "admins" group ---
{
    my $r = users_api({ action => 'add', username => 'carol', password => 'secret' });
    is( $r->{ok}, 1, 'user created' );
    $r = users_api({ action => 'group-add', username => 'carol', group => 'admins' });
    is( $r->{ok}, 1, 'user added to admins' );
}

# --- 2. POST /login via auth wrapper, capture the cookie ---
my $cookie;
{
    my $body = 'username=carol&password=secret&next=/protected';
    local %ENV = (
        DOCUMENT_ROOT   => $docroot,
        REQUEST_METHOD  => 'POST',
        QUERY_STRING    => 'action=login',
        CONTENT_LENGTH  => length($body),
        CONTENT_TYPE    => 'application/x-www-form-urlencoded',
        REMOTE_ADDR     => '127.0.0.1',
    );
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, "$root/lazysite-auth.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;

    like( $out, qr/Status: 302 Found/,           'login → 302' );
    like( $out, qr{Location: /protected},         'login redirects to next param' );
    if ( $out =~ /Set-Cookie:\s*lazysite_auth=([^;]+);/ ) {
        $cookie = $1;
    }
    ok( $cookie && length $cookie, 'cookie captured' );
}

# --- 3. With the cookie: auth wrapper sets HTTP_X_REMOTE_USER,
#        processor serves protected page ---
sub auth_get {
    my ($uri, $cookie_val) = @_;
    local %ENV = (
        DOCUMENT_ROOT      => $docroot,
        REDIRECT_URL       => $uri,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => '',
        REMOTE_ADDR        => '127.0.0.1',
        # The wrapper exec()s LAZYSITE_PROCESSOR; the default it
        # falls back to is $DOCROOT/../cgi-bin/lazysite-processor.pl
        # which doesn't exist under a tempdir.
        LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
        ( $cookie_val ? ( HTTP_COOKIE => "lazysite_auth=$cookie_val" ) : () ),
    );
    return qx($^X \Q$root/lazysite-auth.pl\E 2>/dev/null);
}

{
    my $out = auth_get('/protected', $cookie);
    like( $out, qr/Status: 200 OK/, 'cookie-authenticated → 200' );
    like( $out, qr/PROTECTED-BODY/,  'protected body served' );
}

# --- 4. No cookie → redirect to /login ---
{
    my $out = auth_get('/protected', undef);
    like( $out, qr/Status: 302 Found/,      'no cookie → 302' );
    like( $out, qr{Location: /login.*next=}, 'redirect carries next param' );
}

# --- 5. Rotate auth secret via manager-api, verify same cookie
#        no longer authenticates ---
{
    # Get a CSRF token using the valid cookie
    local %ENV = (
        DOCUMENT_ROOT   => $docroot,
        REDIRECT_URL    => '/cgi-bin/lazysite-manager-api.pl',
        REQUEST_METHOD  => 'GET',
        QUERY_STRING    => 'action=csrf-token',
        REMOTE_ADDR     => '127.0.0.1',
        HTTP_COOKIE     => "lazysite_auth=$cookie",
        LAZYSITE_PROCESSOR => "$root/lazysite-manager-api.pl",
    );
    my $tok_resp = qx($^X \Q$root/lazysite-auth.pl\E 2>/dev/null);
    $tok_resp =~ s/\A.*?\r?\n\r?\n//s;    # strip headers
    my $token = decode_json($tok_resp)->{token};
    ok( $token && length($token) == 64, 'csrf token obtained' );

    # Rotate the secret
    local $ENV{QUERY_STRING}    = 'action=rotate-auth-secret';
    local $ENV{REQUEST_METHOD}  = 'POST';
    local $ENV{CONTENT_LENGTH}  = 0;
    local $ENV{HTTP_X_CSRF_TOKEN} = $token;
    my $rot = qx($^X \Q$root/lazysite-auth.pl\E 2>/dev/null);
    $rot =~ s/\A.*?\r?\n\r?\n//s;
    my $r = decode_json($rot);
    is( $r->{ok}, 1, 'rotate-auth-secret accepted' );

    # Old cookie must now fail
    my $out = auth_get('/protected', $cookie);
    like( $out, qr/Status: 302 Found/,
          'old cookie rejected after rotation (redirect to login)' );
    unlike( $out, qr/PROTECTED-BODY/,
          'protected body NOT served to old cookie' );
}

done_testing();
