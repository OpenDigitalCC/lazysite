#!/usr/bin/perl
# 2026-07-10 review D1 (cross-flagged D6): six user-settings.json readers in
# lazysite-auth.pl opened the file :utf8 and then decode_json'd the decoded
# string - decode_json takes OCTETS, so any non-ASCII byte in the file made
# every reader die inside its eval and default OPEN: account_disabled,
# token_expired, account_expired and mfa_enrolled all returned "fine" for
# every account. Pins the fixed :raw behaviour: a disabled account stays
# disabled when the settings file contains non-ASCII.
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
    my $body = "username=$o{username}&password=" . ( $o{password} // '' ) . "&next=/";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $o{docroot},
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => '127.0.0.1',
        HTTPS          => '',
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '' };
}

sub build_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    users_api( $d, { action => 'add', username => 'admin', password => 'pw' } );
    return $d;
}

# Inject a non-ASCII value into user-settings.json alongside the real
# settings, as an operator note or display name legitimately would.
sub poison_settings {
    my ($d) = @_;
    my $path = "$d/lazysite/auth/user-settings.json";
    my $raw  = '{}';
    if ( open my $fh, '<:raw', $path ) {
        $raw = do { local $/; <$fh> };
        close $fh;
    }
    my $data = decode_json($raw);
    $data->{"caf\x{e9}-owner"} = { note => "espresso caf\x{e9} \x{2615}" };
    open my $out, '>:raw', $path or die $!;
    print {$out} JSON::PP->new->utf8->canonical->encode($data);
    close $out;
    return;
}

# --- disabled + non-ASCII in the file: the gate must still hold --------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'bob', password => 'secret' } );
    my $set = users_api( $d,
        { action => 'account-disable', username => 'bob' } );
    is( $set->{ok}, 1, 'bob disabled' );
    poison_settings($d);

    my $r = login( docroot => $d, username => 'bob', password => 'secret' );
    unlike( $r->{out}, qr/Set-Cookie: lazysite_auth=bob/,
        'disabled account refused a cookie despite non-ASCII settings' );
}

# --- positive control: same non-ASCII file, enabled account logs in ----
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'ann', password => 'secret' } );
    poison_settings($d);

    my $r = login( docroot => $d, username => 'ann', password => 'secret' );
    like( $r->{out}, qr/Set-Cookie: lazysite_auth=ann/,
        'enabled account logs in - the non-ASCII file parses cleanly' );
}

done_testing;
