#!/usr/bin/perl
# Ruling 206 (item 6 of the 0.16.9 fault survey): A lazysite/auth/groups THAT
# EXISTS AND WILL NOT OPEN REFUSES SIGN-IN AND EVERY SESSION.
#
# load_user_groups answered "no groups" for a groups file it could not open, so
# a sign-in minted a session carrying none and every request on an existing
# session lost its groups - which lifts every rule that denies by group (a
# locked group, an address-limited one). Now the groups file is one of
# session_store_fault's stores: the sign-in answers ?error=unavailable with no
# cookie, an existing session reaches the page as no identity (cannot-tell),
# and `lazysite check` names the file. An ABSENT groups file is a site with no
# groups yet and signs in as before.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_cmd run_child);

plan skip_all => 'root opens a 0000 file; run as the site user' if $> == 0;

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
my $G = "$A/groups";

my $stub = "$d/../stub-processor.pl";
put( $stub, qq(#!$^X\nprint "Status: 200 OK\\r\\nContent-Type: text/plain\\r\\n\\r\\n";\n)
        . q(print 'USER=' . ( $ENV{HTTP_X_REMOTE_USER} // '' ) . "\n";)
        . q(print 'GROUPS=' . ( $ENV{HTTP_X_REMOTE_GROUPS} // '' ) . "\n";) . "\n" );
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
    return run_child( [ $^X, $auth ], stdin => ( $body // '' ) )->{out} // '';
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

subtest 'ABSENT groups file: sign-in and sessions work' => sub {
    unlink $G;
    like( login(),         qr/Set-Cookie:\s*lazysite_auth=/, 'sign-in issues a cookie' );
    like( page_as_human(), qr/USER=human/,                   'and the session reaches the page' );
};

subtest 'THE CONTROL: a readable groups file names the account\'s groups' => sub {
    put( $G, "staff: human\n" );
    chmod 0660, $G;
    like( login(),         qr/Set-Cookie:\s*lazysite_auth=/, 'sign-in issues a cookie' );
    like( page_as_human(), qr/GROUPS=staff/,                 'and the session carries its group' );
};

subtest 'UNREADABLE groups file: sign-in and sessions refused' => sub {
    chmod 0000, $G or die "chmod: $!";
    my $out = login();
    unlike( $out, qr/Set-Cookie:\s*lazysite_auth=[^;\s]/, 'no session cookie issues' );
    like( $out, qr/Location:[^\n]*error=unavailable/, 'sign-in answers error=unavailable' );
    like( page_as_human(), qr/USER=\n/, 'an existing session reaches the page as no identity' );
    my $check = run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
    like( $check, qr/lazysite\/auth\/groups \(0000.*is not readable by the CGI.*every sign-in\s+and every session is refused/s,
        'lazysite check names the file and what it stops' ) or diag $check;
    chmod 0660, $G;
    like( login(), qr/Set-Cookie:\s*lazysite_auth=/, 'repaired, sign-in works again' );
};

done_testing();
