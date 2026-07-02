#!/usr/bin/perl
# SM070: lazysite-auth.pl enforces the per-user `ui` access mechanism.
# A ui-disabled account with valid credentials is refused a cookie.
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

# POST /login through the auth wrapper. Returns stdout + stderr.
sub login {
    my (%o) = @_;
    my $body = "username=$o{username}&password=" . ( $o{password} // '' ) . "&next=/";
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT  => $o{docroot},
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => $o{addr} // '127.0.0.1',
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
    print $cf "site_name: T\n";    # no manager_groups: any user manager-capable
    close $cf;
    # An always-UI admin keeps the last-manager guard satisfied so we
    # can disable ui on the test accounts.
    users_api( $d, { action => 'add', username => 'admin', password => 'pw' } );
    return $d;
}

# --- valid password + ui:off => refused, no cookie --------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'bot', password => 'secret' } );
    my $set = users_api( $d,
        { action => 'settings-set', username => 'bot', key => 'ui', value => 'off' } );
    is( $set->{ok}, 1, 'ui disabled for bot' );

    my $r = login( docroot => $d, username => 'bot', password => 'secret' );
    like( $r->{out}, qr/403 Forbidden/, 'ui-disabled login is 403' );
    unlike( $r->{out}, qr/Set-Cookie:/, 'no cookie issued to ui-disabled account' );
    like( $r->{err}, qr/interactive login disabled/i, 'WARN logged' );
}

# --- correct password still required (wrong password => generic fail) --
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'bot', password => 'secret' } );
    users_api( $d,
        { action => 'settings-set', username => 'bot', key => 'ui', value => 'off' } );

    my $r = login( docroot => $d, username => 'bot', password => 'WRONG' );
    # Wrong password fails before the ui check: ordinary login failure,
    # not the ui-disabled 403 (no information leak about the mechanism).
    unlike( $r->{out}, qr/403 Forbidden/, 'wrong password does not reveal ui state' );
    unlike( $r->{out}, qr/Set-Cookie:/, 'wrong password issues no cookie' );
}

# --- ui:on (and absent settings) still log in -------------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'human', password => 'secret' } );

    # absent settings row -> defaults ui on
    my $r = login( docroot => $d, username => 'human', password => 'secret' );
    like( $r->{out}, qr/302 Found/, 'default (no settings) login succeeds' );
    like( $r->{out}, qr/Set-Cookie:/, 'cookie issued' );

    # explicit ui on
    users_api( $d,
        { action => 'settings-set', username => 'human', key => 'ui', value => 'on' } );
    my $r2 = login( docroot => $d, username => 'human', password => 'secret' );
    like( $r2->{out}, qr/Set-Cookie:/, 'explicit ui:on login succeeds' );
}

# --- localhost no-password bypass also respects ui:off ----------------
{
    my $d = build_docroot();
    # No-password account: empty hash row, written directly.
    open my $uf, '>>', "$d/lazysite/auth/users" or die $!;
    print $uf "localbot:\n";
    close $uf;
    # Disable ui for it via the tool (exists-check supports no-password rows).
    my $set = users_api( $d,
        { action => 'settings-set', username => 'localbot', key => 'ui', value => 'off' } );
    is( $set->{ok}, 1, 'ui disabled for no-password account' );

    my $r = login( docroot => $d, username => 'localbot', password => '', addr => '127.0.0.1' );
    like( $r->{out}, qr/403 Forbidden/, 'localhost no-password bypass refused when ui:off' );
    unlike( $r->{out}, qr/Set-Cookie:/, 'no cookie from refused localhost bypass' );
}

# --- no-password localhost bypass still works when ui is on -----------
{
    my $d = build_docroot();
    open my $uf, '>>', "$d/lazysite/auth/users" or die $!;
    print $uf "localadmin:\n";
    close $uf;

    my $r = login( docroot => $d, username => 'localadmin', password => '', addr => '127.0.0.1' );
    like( $r->{out}, qr/302 Found/, 'localhost no-password bypass works with ui default on' );
    like( $r->{out}, qr/Set-Cookie:/, 'cookie issued for localhost bypass' );
}

done_testing();
