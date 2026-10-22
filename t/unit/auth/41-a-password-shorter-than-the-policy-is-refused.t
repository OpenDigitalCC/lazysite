#!/usr/bin/perl
# SM1041 (ruled 2026-10-12, "Min 12, configurable"): `password_min_length` in
# lazysite.conf, default 12, applied to EVERY way a password is set - the users
# tool's add, passwd and account-create, a redeemed setup or reset link (through
# the auth CGI too), setup-sysop - while a password set before the policy keeps
# signing in until it is changed.
#
# Before this the only refusal was an empty password: `add alice pw` and a
# claim redeemed with `x` both succeeded.
use strict;
use warnings;
use utf8;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);
use Lazysite::Auth::Credential qw(hash_password password_min_length password_policy_refusal);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub cli {
    my ( $d, @args ) = @_;
    my ( $out, $err ) = @{ run_child( [ $^X, $utl, '--docroot', $d, @args ] ) }{qw(out err)};
    return { rc => $? >> 8, out => $out // '', err => $err // '' };
}

sub auth_post {
    my ( $d, $qs, $body ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT       => $d,
        REQUEST_METHOD      => 'POST',
        QUERY_STRING        => $qs,
        CONTENT_LENGTH      => length($body),
        CONTENT_TYPE        => 'application/x-www-form-urlencoded',
        REMOTE_ADDR         => '127.0.0.1',
        HTTPS               => '',
        LAZYSITE_USERS_TOOL => $utl );
    my $out = run_child( [ $^X, $auth ], stdin => $body )->{out};
    return $out // '';
}

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n" . ( $conf // '' );
    close $cf;
    return $d;
}

sub users_line {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or return '';
    my ($l) = grep {/^\Q$u\E:/} <$fh>;
    close $fh;
    return $l // '';
}

my $eleven = 'abcdefghijk';
my $twelve = 'abcdefghijkl';

# --- the reader ------------------------------------------------------------------
{
    is( password_min_length( site() . '/lazysite' ), 12, 'the default is 12' );
    is( password_min_length( site("password_min_length: 16\n") . '/lazysite' ), 16,
        'lazysite.conf sets it' );
    for my $bad ( '4', '500', 'twelve', '0' ) {
        is( password_min_length( site("password_min_length: $bad\n") . '/lazysite' ), 12,
            "a value of '$bad' is not a policy - the default stands" );
    }
    is( password_policy_refusal( 'é' x 12, undef ), undef,
        'twelve accented characters are twelve, not twenty-four bytes' );
    like( password_policy_refusal( 'é' x 11, undef ) // '', qr/at least 12 characters/,
        'eleven accented characters are refused although they are 22 bytes' );
}

# --- the users tool: add, passwd, account-create ------------------------------------
{
    my $d = site();
    my $r = uapi( $d, { action => 'add', username => 'alice', password => $eleven } );
    ok( !$r->{ok}, 'add: an 11-character password is refused' );
    like( $r->{error} // '', qr/at least 12 characters/, 'add: the refusal names the length' );
    is( users_line( $d, 'alice' ), '', 'add: no account was created' );

    ok( uapi( $d, { action => 'add', username => 'alice', password => $twelve } )->{ok},
        'add: a 12-character password is accepted' );
    ok( uapi( $d, { action => 'add', username => 'agent', password => '' } )->{ok},
        'add: an empty password is still a token-only account, not a password' );

    my $before = users_line( $d, 'alice' );
    my $p = uapi( $d, { action => 'passwd', username => 'alice', password => $eleven } );
    ok( !$p->{ok}, 'passwd: an 11-character password is refused' );
    is( users_line( $d, 'alice' ), $before, 'passwd: the old password stands' );
    ok( !-e "$d/lazysite/auth/revoked.json",
        'passwd: a refused password signs nobody out (SM1040 runs after the policy)' );

    my $c = cli( $d, 'passwd', 'alice', $eleven );
    isnt( $c->{rc}, 0, 'CLI passwd: refused with a non-zero exit' );
    like( $c->{err}, qr/at least 12 characters/, 'CLI passwd: says why' );

    my $l = site("password_min_length: 16\n");
    ok( !uapi( $l, { action => 'add', username => 'bob', password => 'fifteen-chars-x' } )->{ok},
        'a site that asks for 16 refuses 15' );
    ok( uapi( $l, { action => 'add', username => 'bob', password => 'sixteen-chars-xy' } )->{ok},
        'a site that asks for 16 accepts 16' );
}

# --- setup-sysop -------------------------------------------------------------------
{
    my $d = site();
    my $c = cli( $d, 'setup-sysop', $eleven, '--user', 'root1' );
    isnt( $c->{rc}, 0, 'setup-sysop: a short password is refused' );
    like( $c->{err}, qr/at least 12 characters/, 'setup-sysop: says why' );
    my $ok = cli( $d, 'setup-sysop', $twelve, '--user', 'root1' );
    is( $ok->{rc}, 0, 'setup-sysop: a long enough password is accepted' ) or diag $ok->{err};
    my $l = site("password_min_length: 40\n");
    my $g = cli( $l, 'setup-sysop', '--user', 'root2', '--link' );
    is( $g->{rc}, 0, 'setup-sysop --link works whatever the policy (its placeholder is long)' )
        or diag $g->{err};
}

# --- a redeemed link: refused, and the link is NOT spent ------------------------------
{
    my $d = site();
    uapi( $d, { action => 'add', username => 'carol', password => '' } );
    my $cl = uapi( $d, { action => 'claim-create', username => 'carol' } );
    ok( $cl->{claim}, 'a setup link is issued' );

    my $out = auth_post( $d, 'action=claim', "username=carol&claim=$cl->{claim}&password=$eleven" );
    like( $out, qr{Location: /claim\?u=carol&c=\Q$cl->{claim}\E&error=short&min=12},
        'auth CGI: a short password goes back to the form, saying the length' );
    is( users_line( $d, 'carol' ), "carol:\n", 'auth CGI: no password was set' );

    my $ok = auth_post( $d, 'action=claim', "username=carol&claim=$cl->{claim}&password=$twelve" );
    like( $ok, qr{Location: /login\?claimed=1}, 'the same link then sets a long enough password' );
    unlike( users_line( $d, 'carol' ), qr/^carol:$/, 'and the password is set' );
}

# --- a password set before the policy still signs in ------------------------------------
{
    my $d = site();
    open my $uf, '>', "$d/lazysite/auth/users" or die $!;
    print $uf 'olduser:' . hash_password('pw') . "\n";
    close $uf;
    my $out = auth_post( $d, 'action=login', 'username=olduser&password=pw&next=/' );
    like( $out, qr/302 Found/,                 'a two-character password set before the policy signs in' );
    like( $out, qr/Set-Cookie: lazysite_auth=/, 'and gets a session' );
}

done_testing;
