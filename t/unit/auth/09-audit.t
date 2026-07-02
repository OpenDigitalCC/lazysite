#!/usr/bin/perl
# Login / logout and other material auth events are recorded in the audit trail
# (lazysite/logs/audit.log), not just the application log.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
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

# Run the auth wrapper with a given CGI env + optional POST body.
sub run_auth {
    my ( $env, $body ) = @_;
    $body //= '';
    local %ENV = ( env_passthrough(), %$env, CONTENT_LENGTH => length($body),
        CONTENT_TYPE => 'application/x-www-form-urlencoded',
        LAZYSITE_USERS_TOOL => $utl );
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

sub audit_log_text {
    my ($d) = @_;
    my $f = "$d/lazysite/logs/audit.log";
    return '' unless -f $f;
    open my $fh, '<', $f or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
users_api( $d, { action => 'add', username => 'human', password => 'pw' } );

my %base = ( DOCUMENT_ROOT => $d, REMOTE_ADDR => '127.0.0.1', HTTPS => '' );

# --- successful login is audited (capture the session cookie) ---
my $login_out = run_auth(
    { %base, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=login' },
    "username=human&password=pw&next=/" );
like( audit_log_text($d), qr/\|\s*human\s*\|\s*login\s*\|.*\|\s*ok\s*\|/,
    'successful login writes an audit "login … ok" entry' );
my ($session) = $login_out =~ /Set-Cookie:\s*lazysite_auth=([^;]+)/i;
ok( $session, 'login issued a session cookie' );

# --- failed login is audited with a reason ---
run_auth( { %base, REMOTE_ADDR => '10.9.9.9', REQUEST_METHOD => 'POST',
        QUERY_STRING => 'action=login' },
    "username=human&password=WRONG&next=/" );
like( audit_log_text($d),
    qr/\|\s*human\s*\|\s*login\s*\|.*\|\s*fail\s*\|.*invalid-credentials/,
    'failed login writes an audit "login … fail … invalid-credentials" entry' );

# --- an unauthenticated logout (e.g. a scanner) writes NO audit noise ---
my $pre = audit_log_text($d);
run_auth( { %base, REMOTE_ADDR => '45.88.138.44',
        REQUEST_METHOD => 'GET', QUERY_STRING => 'action=logout' } );    # no cookie
is( audit_log_text($d), $pre, 'unauthenticated logout writes no audit entry' );

# --- logout of a VALID session is audited, with the real username ---
run_auth( { %base, REQUEST_METHOD => 'GET', QUERY_STRING => 'action=logout',
        HTTP_COOKIE => "lazysite_auth=$session" } );
like( audit_log_text($d), qr/\|\s*human\s*\|\s*logout\s*\|.*\|\s*ok\s*\|/,
    'logout of a valid session writes an audit "logout … ok" entry' );

done_testing();
