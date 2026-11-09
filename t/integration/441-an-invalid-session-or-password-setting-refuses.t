#!/usr/bin/perl
# Ruling 206 (item 8 of the 0.16.9 fault survey): AN INVALID session_lifetime
# OR password_min_length IS REFUSED, NEVER READ AS THE DEFAULT.
#
# session_lifetime outside 300..31536000 (or not a whole number) became the
# 24-hour default in silence, and password_min_length outside 8..128 became 12:
# the engine guessed what the operator meant. Now, while session_lifetime is
# invalid, the sign-in answers ?error=unavailable and an existing session is no
# identity (cannot-tell, naming lazysite.conf); while password_min_length is
# invalid, every password set is refused with a sentence that names no value.
# `lazysite check` names each key, its range and what it stops. Unset keys are
# the defaults, as before.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_cmd run_child);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub users_api {
    my ( $docroot, $payload ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $docroot ],
        stdin => encode_json($payload), stderr => 'discard' )->{out};
    return eval { decode_json($out) } || { ok => 0, error => "unparsed: $out" };
}

my $d = site_tempdir();
mkdir "$d/lazysite";
mkdir "$d/lazysite/auth";
my $CONF = "$d/lazysite/lazysite.conf";
put( $CONF, "site_name: T\n" );
users_api( $d, { action => 'add', username => 'human', password => 'pw-long-enough' } );
my $A = "$d/lazysite/auth";

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

sub check { return run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d ) }

subtest 'UNSET: the defaults, as before' => sub {
    like( login(),         qr/Set-Cookie:\s*lazysite_auth=/, 'sign-in issues a cookie' );
    like( page_as_human(), qr/USER=human/,                   'and the session reaches the page' );
    my $r = users_api( $d, { action => 'add', username => 'ann', password => 'twelve-chars' } );
    ok( $r->{ok}, 'a 12-character password is taken' ) or diag explain $r;
    unlike( check(), qr/session_lifetime in lazysite\.conf|password_min_length in lazysite\.conf/,
        'and the check says nothing about either' );
};

subtest 'VALID: honoured' => sub {
    put( $CONF, "site_name: T\nsession_lifetime: 3600\npassword_min_length: 16\n" );
    like( login(), qr/Set-Cookie:\s*lazysite_auth=[^\n]*Max-Age=3600/, 'the cookie lasts an hour' );
    my $r = users_api( $d, { action => 'add', username => 'bea', password => 'twelve-chars' } );
    ok( !$r->{ok}, 'a 12-character password is short of 16' );
    like( $r->{error} // '', qr/at least 16 characters/, 'and says so' );
};

for my $v ( '0', '10', '99999999999', '1h' ) {
    subtest "INVALID session_lifetime ($v): sign-in and sessions refused" => sub {
        put( $CONF, "site_name: T\nsession_lifetime: $v\n" );
        my $out = login();
        unlike( $out, qr/Set-Cookie:\s*lazysite_auth=[^;\s]/, 'no session cookie issues' );
        like( $out, qr/Location:[^\n]*error=unavailable/, 'sign-in answers error=unavailable' );
        # SM297 (ruling 217), earlier on this line: a session the engine cannot
        # check is refused 503 (cannot-tell) before the page, never rendered as anonymous.
        my $page = page_as_human();
        like( $page, qr/\AStatus: 503/, 'an existing session is refused 503 (cannot-tell)' );
        unlike( $page, qr/USER=/, '...and never reaches the page' );
        like( check(), qr/FAIL.*session_lifetime in lazysite\.conf is '\Q$v\E', which is not a whole number of\s+seconds from 300 to 31536000 - every sign-in and every session is refused/s,
            'lazysite check names the key, the range and what it stops' );
    };
}

for my $v ( '3', '500', 'twelve' ) {
    subtest "INVALID password_min_length ($v): every password set refused" => sub {
        put( $CONF, "site_name: T\npassword_min_length: $v\n" );
        my $r = users_api( $d, { action => 'add', username => "c$v", password => 'a-very-long-password-indeed' } );
        ok( !$r->{ok}, 'a password is refused, however long' ) or diag explain $r;
        like( $r->{error} // '', qr/password policy setting is invalid/, 'as a fault on the host' );
        unlike( $r->{error} // '', qr/\Q$v\E/, 'without naming the value' );
        like( check(), qr/FAIL.*password_min_length in lazysite\.conf is '\Q$v\E', which is not a whole number from 8 to 128 - every password set or reset is refused/s,
            'lazysite check names the key, the range and what it stops' );
        like( login(), qr/Set-Cookie:\s*lazysite_auth=/, 'and signing in with an existing password still works' );
    };
}

done_testing();
