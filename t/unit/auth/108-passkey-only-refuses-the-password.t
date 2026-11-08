#!/usr/bin/perl
# SM1352: "passkey only" is one group key, `passkey_only`, checked in the password
# branch of sign-in and nowhere else.
#   - a member of a passkey-only group is refused the password, after it matched,
#     with ?error=passkey-only and no session; the audit says why
#   - the same account signs in with its passkey
#   - an account in no such group, and the group with the key off, sign in by password
#   - a group store that exists and cannot be read refuses the password (cannot tell)
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require PasskeyFixture;

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";
my $HOST = 'site.example';
my %PW   = ( alice => 'alice-first-password', bob => 'bob-first-password-x' );

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub cgi {
    my ( $d, $action, $body ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => "action=$action",
        CONTENT_LENGTH => length $body, REMOTE_ADDR => '192.0.2.41', HTTP_HOST => $HOST, HTTPS => 'on',
        LAZYSITE_USERS_TOOL => $utl );
    return run_child( [ $^X, $auth ], stdin => $body, stderr => 'inherit' )->{out} // '';
}

sub password { my ( $d, $u ) = @_; return cgi( $d, 'login', "username=$u&password=$PW{$u}&next=/" ) }
sub cookie   { my ($out) = @_; return $out =~ /^Set-Cookie: lazysite_auth=([^;]+)/m ? $1 : '' }
sub location { my ($out) = @_; return $out =~ /^Location: (\S+)/m ? $1 : '' }

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nauth_redirect: /login\n";
    close $cf;
}
uapi( $d, { action => 'add', username => $_, password => $PW{$_} } ) for qw(alice bob);
uapi( $d, { action => 'group-create', group => 'phones' } );
uapi( $d, { action => 'group-add', username => 'alice', group => 'phones' } );
my $k = PasskeyFixture::key(-7);
uapi( $d, { action => 'passkey-add', username => 'alice', passkey => PasskeyFixture::stored($k) } );

like( cookie( password( $d, 'alice' ) ), qr/\Aalice/, 'before the key: alice signs in by password' );

my $set = uapi( $d, { action => 'group-settings-set', group => 'phones', key => 'passkey_only', value => 'on' } );
ok( $set->{ok} && $set->{passkey_only}, 'the group key is set like any group setting' ) or diag explain $set;

my $out = password( $d, 'alice' );
is( cookie($out), '', 'passkey only: the right password gets no session' );
like( location($out), qr/error=passkey-only/, 'and the page is told to use a passkey' );
{
    open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!;
    my $log = do { local $/; <$fh> };
    close $fh;
    like( $log, qr/\|\s*alice\s*\|\s*login\s*\|.*\|\s*fail\s*\|.*passkey-only/, 'the audit says why' );
}
my $wrong = cgi( $d, 'login', 'username=alice&password=not-her-password&next=/' );
like( location($wrong), qr/error=1\b/, 'a wrong password is answered as any wrong password: nothing about the group' );

like( cookie( password( $d, 'bob' ) ), qr/\Abob/, 'an account in no passkey-only group signs in by password' );

my $c = do {
    my ($jb) = cgi( $d, 'passkey-challenge', 'purpose=signin' ) =~ /\r?\n\r?\n(.*)/s;
    decode_json($jb);
};
like( cookie( cgi( $d, 'passkey-login', PasskeyFixture::form( PasskeyFixture::asserted( $k,
                    challenge => $c->{challenge}, origin => "https://$HOST", rp => $HOST, count => 1 ), next => '/' ) ) ),
    qr/\Aalice/, 'passkey only: alice signs in with her passkey' );

uapi( $d, { action => 'group-settings-set', group => 'phones', key => 'passkey_only', value => 'off' } );
like( cookie( password( $d, 'alice' ) ), qr/\Aalice/, 'the key off: the password works again' );

SKIP: {
    skip 'running as root: a mode cannot hide a file', 2 if $> == 0;
    uapi( $d, { action => 'group-settings-set', group => 'phones', key => 'passkey_only', value => 'on' } );
    my $gs = "$d/lazysite/auth/groups-settings.json";
    chmod 0000, $gs;
    my $o = password( $d, 'bob' );
    chmod 0660, $gs;
    is( cookie($o), '', 'a group store that cannot be read: no password session (cannot tell)' );
    like( location($o), qr/error=unavailable/, 'and the page says sign-in is unavailable' );
}

done_testing();
