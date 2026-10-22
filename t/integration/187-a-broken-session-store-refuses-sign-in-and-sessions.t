#!/usr/bin/perl
# SM1024 follow-up (ruled 2026-10-12, "Close all three"): on the auth wrapper,
# a broken revoked.json or user-settings.json refuses sign-in and every
# session until it is repaired - the cannot-tell answer the API doors give.
#
# Before: a broken user-settings.json read as "nobody is disabled", so a
# disabled account signed in; a broken revoked.json read as "nothing is
# revoked", so a signed-out session was served as its user. Now the sign-in
# answers `?error=unavailable` (the page says sign-in is unavailable and the
# operator can see why in the site log), no cookie issues, and a session
# cookie reaches the page as no identity. An ABSENT store is a fresh site and
# signs in as before. `lazysite check --docroot` names the broken file.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_cmd run_child);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $docroot ],
        stdin => encode_json($payload), stderr => 'inherit' )->{out};
    return decode_json($out);
}

sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $d = site_tempdir();
mkdir "$d/lazysite";
mkdir "$d/lazysite/auth";
put( "$d/lazysite/lazysite.conf", "site_name: T\n" );
users_api( $d, { action => 'add', username => 'human', password => 'pw-long-enough' } );
my $A = "$d/lazysite/auth";

# The processor the wrapper hands a request to: it reports who it was told.
my $stub = "$d/../stub-processor.pl";
put( $stub, qq(#!$^X\nprint "Status: 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n";\n)
        . q(print 'USER=' . ( $ENV{HTTP_X_REMOTE_USER} // '' ) . "\n";) . "\n" );
chmod 0755, $stub;

sub run_auth {
    my ( $method, $query, $body, %env ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT       => $d,
        REQUEST_METHOD      => $method,
        QUERY_STRING        => $query,
        CONTENT_LENGTH      => length( $body // '' ),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => '',
        LAZYSITE_USERS_TOOL => $utl,
        LAZYSITE_PROCESSOR  => $stub,
        REDIRECT_URL        => '/members',
        %env,
    );
    my $out = run_child( [ $^X, $auth ], stdin => ( $body // '' ) )->{out};
    return $out // '';
}

sub login { return run_auth( 'POST', 'action=login', 'username=human&password=pw-long-enough&next=/' ) }

sub page_as_human {
    open my $sf, '<', "$A/.secret" or die "no secret: $!";
    my $sec = do { local $/; <$sf> };
    $sec =~ s/\s+\z//;
    my $payload = 'human:' . time() . ':';
    my $cookie  = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $sec );
    return run_auth( 'GET', '', '', HTTP_COOKIE => $cookie );
}

my $BROKEN = '{ "human": { "disabled": 1 ';

subtest 'THE CONTROL: absent stores sign in and serve the session' => sub {
    ok( !-e "$A/revoked.json", 'a fresh site has no revoked.json' );
    like( login(),         qr/Set-Cookie:\s*lazysite_auth=/, 'sign-in issues a cookie' );
    like( page_as_human(), qr/USER=human/, 'and the session reaches the page as its user' );
};

for my $store (qw(user-settings.json revoked.json)) {
    subtest "BROKEN $store: sign-in and sessions refused until it is repaired" => sub {
        my $had = -e "$A/$store";
        my $keep;
        if ($had) { open my $fh, '<:raw', "$A/$store" or die $!; local $/; $keep = <$fh> }
        put( "$A/$store", $BROKEN );

        my $out = login();
        unlike( $out, qr/Set-Cookie:\s*lazysite_auth=[^;\s]/, 'no session cookie issues' );
        like( $out, qr/Location:[^\n]*error=unavailable/, 'sign-in answers error=unavailable' );
        like( page_as_human(), qr/USER=\n/, 'an existing session reaches the page as no identity' );

        my $check = run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
        like( $check, qr/\Q$store\E does not decode as a JSON object/, 'lazysite check names the file' )
            or diag $check;

        if ($had) { put( "$A/$store", $keep ) }
        else      { unlink "$A/$store" }
        like( login(), qr/Set-Cookie:\s*lazysite_auth=/, 'repaired, sign-in works again' );
    };
}

subtest 'the sign-in page says what error=unavailable means' => sub {
    open my $fh, '<', "$root/starter/lazysite/templates/system/login.md" or die $!;
    my $page = do { local $/; <$fh> };
    like( $page, qr/query\.error == 'unavailable'/, 'the page has its own sentence for it' );
};

done_testing();
