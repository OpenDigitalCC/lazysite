#!/usr/bin/perl
# SM072 batch 1: the public claim-redemption endpoint in lazysite-auth.pl.
# A holder of a setup claim sets their own password (or mints a token);
# the operator never sees it. Failures are generic and single-use holds.
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

# POST action=claim through the auth wrapper.
sub claim {
    my (%o) = @_;
    my $body = "username=$o{username}&claim=$o{claim}&password=" . ( $o{password} // '' );
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT       => $o{docroot},
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => 'action=claim',
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => $o{addr} // '127.0.0.1',
        HTTPS               => '',
        LAZYSITE_USERS_TOOL => $utl,
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

# --- a set-password claim: user sets their own password ---------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'newbie', password => '' } );
    my $c = users_api( $d, { action => 'claim-create', username => 'newbie' } );
    ok( $c->{ok} && $c->{claim}, 'claim minted for newbie' );

    my $r = claim( docroot => $d, username => 'newbie', claim => $c->{claim}, password => 'chosen-pw' );
    like( $r->{out}, qr{Location:[^\n]*/login\?claimed=1}, 'set-password claim redirects to login' );

    my $v = users_api( $d, { action => 'verify-credential', username => 'newbie', secret => 'chosen-pw' } );
    ok( $v->{ok}, 'the password the user set authenticates' );
}

# --- a bogus claim is a generic error, sets nothing -------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'newbie', password => '' } );
    users_api( $d, { action => 'claim-create', username => 'newbie' } );

    my $r = claim( docroot => $d, username => 'newbie', claim => 'lzc_bogus', password => 'x' );
    like( $r->{out}, qr{Location:[^\n]*/claim\?[^\n]*error=1}, 'bad claim redirects to the error page' );
    my $v = users_api( $d, { action => 'verify-credential', username => 'newbie', secret => 'x' } );
    ok( !$v->{ok}, 'no password set from a bad claim' );
}

# --- single-use: a redeemed claim cannot be reused --------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'once', password => '' } );
    my $c = users_api( $d, { action => 'claim-create', username => 'once' } );

    claim( docroot => $d, username => 'once', claim => $c->{claim}, password => 'first' );
    my $r2 = claim( docroot => $d, username => 'once', claim => $c->{claim}, password => 'second' );
    like( $r2->{out}, qr{error=1}, 'a redeemed claim cannot be reused' );

    ok(  users_api( $d, { action => 'verify-credential', username => 'once', secret => 'first'  } )->{ok},
        'the first password stands' );
    ok( !users_api( $d, { action => 'verify-credential', username => 'once', secret => 'second' } )->{ok},
        'the second attempt set nothing' );
}

done_testing();
