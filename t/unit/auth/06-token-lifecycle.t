#!/usr/bin/perl
# SM072 batch 3 (Flow C): the token lifecycle over HTTP in lazysite-auth.pl.
# An agent exchanges a pairing key for an access token, then rotates it -
# both returning {token, expires_at}; one live credential per account.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
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

# Run an auth.pl action; %env overrides the CGI environment. Returns the
# decoded JSON body (headers stripped).
sub run_auth {
    my ( $action, $docroot, %env ) = @_;
    my $body = delete $env{_body} // '';
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT       => $docroot,
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => "action=$action",
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => 'on',
        LAZYSITE_USERS_TOOL => $utl,
        %env,
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $pid, 0;
    $out =~ s/\A.*?\r?\n\r?\n//s;    # strip CGI headers
    return eval { decode_json($out) } // { _raw => $out };
}

sub build_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    return $d;
}

# --- pairing key -> access token (with expiry) ------------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'agent', password => 'pw' } );
    my $pk = users_api( $d, { action => 'pairing-key', username => 'agent' } );
    ok( $pk->{ok} && $pk->{pairing_key}, 'pairing key minted' );

    my $r = run_auth( 'exchange', $d, _body => "username=agent&pairing_key=$pk->{pairing_key}" );
    ok( $r->{ok}, 'exchange ok' );
    like( $r->{token}, qr/^lzs_/, 'returns an access token' );
    ok( $r->{expires_at} && $r->{expires_at} > time(), 'returns a future expires_at' );
    ok( users_api( $d, { action => 'verify-credential', username => 'agent', secret => $r->{token} } )->{ok},
        'the issued token authenticates' );

    my $r2 = run_auth( 'exchange', $d, _body => "username=agent&pairing_key=$pk->{pairing_key}" );
    ok( !$r2->{ok}, 'the pairing key is single-use' );
}

# --- rotate: token -> fresh token, old one dies -----------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'agent', password => 'pw' } );
    my $pk  = users_api( $d, { action => 'pairing-key', username => 'agent' } );
    my $tok = run_auth( 'exchange', $d, _body => "username=agent&pairing_key=$pk->{pairing_key}" )->{token};

    my $basic = 'Basic ' . encode_base64( "agent:$tok", '' );
    my $r = run_auth( 'rotate', $d, HTTP_AUTHORIZATION => $basic );
    ok( $r->{ok}, 'rotate ok' );
    like( $r->{token}, qr/^lzs_/, 'returns a fresh token' );
    isnt( $r->{token}, $tok, 'the token changed' );
    ok( $r->{expires_at} && $r->{expires_at} > time(), 'fresh expires_at' );
    ok(  users_api( $d, { action => 'verify-credential', username => 'agent', secret => $r->{token} } )->{ok},
        'the new token works' );
    ok( !users_api( $d, { action => 'verify-credential', username => 'agent', secret => $tok } )->{ok},
        'the old token is dead (one live credential)' );

    my $bad = run_auth( 'rotate', $d, HTTP_AUTHORIZATION => $basic );   # stale token
    ok( !$bad->{ok}, 'rotation with a stale token is refused' );
}

# --- a bogus pairing key is rejected ----------------------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'agent', password => 'pw' } );
    my $r = run_auth( 'exchange', $d, _body => 'username=agent&pairing_key=lzp_bogus' );
    ok( !$r->{ok}, 'a bogus pairing key is rejected' );
}

done_testing();
