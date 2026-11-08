#!/usr/bin/perl
# SM1352: the first passkey is enrolled through the existing emailed one-time link
# (/claim), in place of a password.
#   - the claim challenge is bound to the account the link is for; the answer must
#     be a webauthn.create for this origin, answering it
#   - a refused passkey leaves the link unspent; a good one spends it, stores the
#     passkey, and sends the person to sign in (?claimed=passkey)
#   - the account then has a locked password marker, never an empty one: no
#     password signs it in, the localhost no-password door included
#   - the passkey signs the account in
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

my $root   = repo_root();
my $auth   = "$root/lazysite-auth.pl";
my $utl    = "$root/tools/lazysite-users.pl";
my $HOST   = 'site.example';
my $ORIGIN = "https://$HOST";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub cgi {
    my ( $d, $action, $body, %env ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST', QUERY_STRING => "action=$action",
        CONTENT_LENGTH => length $body, REMOTE_ADDR => '192.0.2.42', HTTP_HOST => $HOST, HTTPS => 'on',
        LAZYSITE_USERS_TOOL => $utl, %env );
    return run_child( [ $^X, $auth ], stdin => $body, stderr => 'inherit' )->{out} // '';
}

sub challenge {
    my ( $d, $purpose, $user ) = @_;
    my ($jb) = cgi( $d, 'passkey-challenge', "purpose=$purpose&username=$user" ) =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // {};
}
sub location { my ($out) = @_; return $out =~ /^Location: (\S+)/m ? $1 : '' }
sub cookie   { my ($out) = @_; return $out =~ /^Set-Cookie: lazysite_auth=([^;]+)/m ? $1 : '' }

sub claim_with {
    my ( $d, $user, $claim, %reg ) = @_;
    my %f = ( username => $user, claim => $claim, map { ( "pk_$_" => $reg{$_} ) } keys %reg );
    return cgi( $d, 'claim', PasskeyFixture::form(%f) );
}

sub passkeys_of {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/user-settings.json" or die $!;
    my $all = decode_json( do { local $/; <$fh> } );
    close $fh;
    return scalar @{ $all->{$u}{passkeys} || [] };
}

sub hash_of {
    my ( $d, $u ) = @_;
    open my $fh, '<', "$d/lazysite/auth/users" or die $!;
    my ($line) = grep { /^\Q$u\E:/ } <$fh>;
    close $fh;
    chomp $line;
    return ( split /:/, $line, 2 )[1];
}

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nauth_redirect: /login\n";
    close $cf;
}
uapi( $d, { action => 'add', username => $_, password => "$_-first-password-x" } ) for qw(alice bob);
my $claim = uapi( $d, { action => 'claim-create', username => 'alice', revoke => 1 } )->{claim};
ok( length( $claim // '' ), 'fixture: alice has a setup link and no credential' );
is( hash_of( $d, 'alice' ), '', 'fixture: her stored credential is empty' );

my $k = PasskeyFixture::key(-7);

# --- refusals leave the link unspent ------------------------------------------------------------
my $cb = challenge( $d, 'claim', 'bob' );
is( $cb->{user_name}, 'bob', 'a claim challenge names the account it is for' );
my $o = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k, challenge => $cb->{challenge}, origin => $ORIGIN, rp => $HOST ) );
like( location($o), qr{^/claim\?.*error=passkey\b}, "a challenge issued for bob does not enrol alice" );

my $cs = challenge( $d, 'signin', '' );
$o = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k, challenge => $cs->{challenge}, origin => $ORIGIN, rp => $HOST ) );
like( location($o), qr/error=passkey\b/, 'a sign-in challenge does not enrol' );

my $ca = challenge( $d, 'claim', 'alice' );
$o = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k, challenge => $ca->{challenge}, origin => 'https://evil.example', rp => $HOST ) );
like( location($o), qr/error=passkey\b/, 'an answer made for another origin does not enrol' );

$ca = challenge( $d, 'claim', 'alice' );
$o = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k, challenge => $ca->{challenge}, origin => $ORIGIN, rp => $HOST, type => 'webauthn.get' ) );
like( location($o), qr/error=passkey\b/, 'a sign-in answer (webauthn.get) does not enrol' );
is( passkeys_of( $d, 'alice' ), 0, 'nothing was stored by any of them' );

# --- the good answer ----------------------------------------------------------------------------
$ca = challenge( $d, 'claim', 'alice' );
$o  = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k, challenge => $ca->{challenge}, origin => $ORIGIN, rp => $HOST ) );
is( location($o), '/login?claimed=passkey', 'the link enrols the passkey and sends her to sign in' );
is( hash_of( $d, 'alice' ), '!passkey', 'her credential is the locked marker, not empty' );
is( passkeys_of( $d, 'alice' ), 1, 'and the passkey is in her record' );

$ca = challenge( $d, 'claim', 'alice' );
my $k2 = PasskeyFixture::key(-7);
$o = claim_with( $d, 'alice', $claim,
    PasskeyFixture::created( $k2, challenge => $ca->{challenge}, origin => $ORIGIN, rp => $HOST ) );
like( location($o), qr{^/claim\?.*error=1}, 'the link is spent: a second passkey is not enrolled through it' );

# --- no password opens it; the passkey does -------------------------------------------------------
is( cookie( cgi( $d, 'login', 'username=alice&password=&next=/', REMOTE_ADDR => '127.0.0.1' ) ), '',
    'no empty password from localhost: the marker is not a no-password account' );
is( cookie( cgi( $d, 'login', 'username=alice&password=!passkey&next=/' ) ), '',
    'and the marker is not a password' );
my $cg = challenge( $d, 'signin', '' );
like( cookie( cgi( $d, 'passkey-login', PasskeyFixture::form( PasskeyFixture::asserted( $k,
                    challenge => $cg->{challenge}, origin => $ORIGIN, rp => $HOST, count => 1 ), next => '/' ) ) ),
    qr/\Aalice/, 'the enrolled passkey signs her in' );

done_testing();
