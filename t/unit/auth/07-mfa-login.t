#!/usr/bin/perl
# SM072 batch 4: the login second factor. An MFA-enrolled account needs a
# valid TOTP (or single-use recovery) code before a cookie issues.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

sub login {
    my (%o) = @_;
    my $body = "username=$o{username}&password=" . ( $o{password} // '' )
             . "&code=" . ( $o{code} // '' ) . "&next=/";
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT       => $o{docroot},
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => 'action=login',
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => '',
        LAZYSITE_USERS_TOOL => $utl,
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $pid, 0;
    return $out // '';
}

sub build {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    users_api( $d, { action => 'add', username => 'human', password => 'pw' } );
    return $d;
}

# --- no MFA: normal login works (control) -----------------------------
{
    my $d = build();
    like( login( docroot => $d, username => 'human', password => 'pw' ),
        qr/Set-Cookie:/, 'login without MFA issues a cookie' );
}

# --- MFA enrolled: a code is required ----------------------------------
{
    my $d = build();
    my $e = users_api( $d, { action => 'mfa-enroll', username => 'human' } );

    my $nocode = login( docroot => $d, username => 'human', password => 'pw' );
    unlike( $nocode, qr/Set-Cookie:/, 'no cookie without a 2FA code' );
    like(   $nocode, qr/error=mfa/,   'redirect signals 2FA required' );

    my $code = users_api( $d, { action => 'totp-code', secret => $e->{secret},
                                time => time(), step => 30, digits => 6 } )->{code};
    like( login( docroot => $d, username => 'human', password => 'pw', code => $code ),
        qr/Set-Cookie:/, 'password + valid TOTP issues a cookie' );

    unlike( login( docroot => $d, username => 'human', password => 'pw', code => 'nope' ),
        qr/Set-Cookie:/, 'a wrong 2FA code issues no cookie' );

    like( login( docroot => $d, username => 'human', password => 'pw', code => $e->{recovery_codes}[0] ),
        qr/Set-Cookie:/, 'a recovery code also completes login' );
}

done_testing();
