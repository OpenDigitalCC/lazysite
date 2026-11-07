#!/usr/bin/perl
# SM1383 (ruling 132, E): THE SESSION COOKIE IS AN EXTERNAL CONTRACT.
#
# docs/architecture/session-cookie-contract.md states the `lazysite_auth` format
# so that an outside process on the same host can verify a lazysite sign-in
# read-only. Something outside the engine then relies on the format, so a silent
# change to it is a break this suite must see.
#
# THE TEST IS THE DOCUMENT, EXECUTED. A cookie is minted through the real sign-in
# (lazysite-auth.pl), and `outside_verify` below verifies it the way the document
# says an outside process does - Digest::SHA and file reads, no lazysite module.
# It must agree with the engine's own verifier (Lazysite::Auth::Session) on every
# case the document names: the current shape, the legacy three-field shape, the
# attributes, the key, expiry, a revoked sid, a per-user not_before, a tampered
# value, a rotated key, a disabled or removed account, and that the groups in the
# cookie are not the groups that count.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough run_child site_tempdir);
use Lazysite::Auth::Session qw(verify_session_cookie SESSION_COOKIE_NAME);

my $root = repo_root();
my $d    = site_tempdir();
my $lz   = "$d/lazysite";
make_path("$lz/auth");
open my $cf, '>', "$lz/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
    stdin => encode_json( { action => 'add', username => $_, password => 'pw-long-enough' } ), stderr => 'inherit' )
    for qw(alice bob);
spit( "$lz/auth/groups", "editors: alice\n" );

sub login {
    my ($user) = @_;
    my $body = "username=$user&password=pw-long-enough&next=/";
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST',
        QUERY_STRING => 'action=login', CONTENT_LENGTH => length($body),
        CONTENT_TYPE => 'application/x-www-form-urlencoded', REMOTE_ADDR => '127.0.0.1', HTTPS => '' );
    return run_child( [ $^X, "$root/lazysite-auth.pl" ], stdin => $body )->{out} // '';
}

# --- the outside process, exactly as the document describes it --------------
#
# Read-only: it opens files and writes nothing. It knows the engine tree's path
# and nothing else about lazysite.
sub outside_verify {
    my ($value) = @_;
    my ( $enc, $sig ) = ( $value // '' ) =~ /\A(.+):([a-f0-9]{64})\z/ or return ( undef, 'malformed' );
    ( my $payload = $enc ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;

    my $key = slurp("$lz/auth/.secret") // return ( undef, 'no key' );
    ($key) = split /\n/, $key;
    my $want = hmac_sha256_hex( $payload, $key );
    my $diff = length($sig) ^ length($want);
    $diff |= ord( substr $sig, $_, 1 ) ^ ord( substr $want, $_, 1 ) for 0 .. length($want) - 1;
    return ( undef, 'signature' ) if $diff;

    my @f = split /:/, $payload, 4;
    my ( $user, $ts, $sid ) = ( $f[0], $f[1], '' );
    $sid = $f[2] if @f == 4 && $f[2] =~ /\A[0-9a-f]{16}\z/;
    return ( undef, 'expired' ) unless defined $ts && $ts =~ /\A\d+\z/;

    my ($life) = ( slurp("$lz/lazysite.conf") // '' ) =~ /^\s*session_lifetime\s*:\s*(\d+)\s*$/m;
    $life = 86400 unless defined $life && $life >= 300 && $life <= 31_536_000;
    return ( undef, 'expired' ) if time() - $ts >= $life;

    return ( undef, 'no-account' )
        unless grep { /\A\Q$user\E:/ } split /\n/, ( slurp("$lz/auth/users") // '' );
    my $settings = decode_json( slurp("$lz/auth/user-settings.json") // '{}' );
    return ( undef, 'disabled' ) if ref $settings->{$user} eq 'HASH' && $settings->{$user}{disabled};

    my $rev = decode_json( slurp("$lz/auth/revoked.json") // '{}' );
    return ( undef, 'revoked' ) if length $sid && exists( ( $rev->{sids} || {} )->{$sid} );
    my $nb = ( $rev->{not_before} || {} )->{$user};
    if ( defined $nb && $ts < $nb ) {
        my $kept = ( $rev->{kept} || {} )->{$user};
        return ( undef, 'revoked' )
            unless length $sid && ref $kept eq 'HASH' && ( $kept->{sid} // '' ) eq $sid && ( $kept->{nb} // -1 ) == $nb;
    }

    my @groups = map { /\A([^:]+):\s*(.*)\z/ && grep( { s/\s+//gr eq $user } split /,/, $2 ) ? $1 : () }
        split /\n/, ( slurp("$lz/auth/groups") // '' );
    return ( { user => $user, sid => $sid, groups => join ',', @groups }, undef );
}

sub engine_verify {
    my ($value) = @_;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $lz;
    %Lazysite::Auth::Session::LIFETIME_CACHE = ();
    return verify_session_cookie( cookie => SESSION_COOKIE_NAME . "=$value" );
}

sub agree {
    my ( $value, $want, $name ) = @_;
    my ( $o, $owhy ) = outside_verify($value);
    my ( $e, $ewhy ) = engine_verify($value);
    if ( defined $want ) {
        ok( $o && $e, "$name: both verify" ) or diag "outside: " . ( $owhy // '' ) . ", engine: " . ( $ewhy // '' );
        is( $o->{user}, $want->{user}, "$name: the outside process reads the user" );
        is( $o->{sid},  $want->{sid},  "$name: and the sid" );
        is( $e->{sid} // '', $want->{sid}, "$name: as the engine does" );
    }
    else {
        ok( !$o, "$name: the outside process refuses it" );
        ok( !$e, "$name: and so does the engine" ) or diag explain $e;
    }
    return ( $o, $e );
}

sub mint {
    my ($payload) = @_;
    my ($key) = split /\n/, slurp("$lz/auth/.secret");
    return $payload . ':' . hmac_sha256_hex( $payload, $key );
}

# --- the current shape, minted by the real sign-in ---------------------------
my $out = login('alice');
my ($set) = $out =~ /^Set-Cookie:\s*(lazysite_auth=[^\r\n]*)/m;
my ($value) = ( $set // '' ) =~ /\Alazysite_auth=([^;]+);/;
my ( $enc ) = ( $value // '' ) =~ /\A(.+):[a-f0-9]{64}\z/;
( my $payload = $enc // '' ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
my @f = split /:/, $payload, 4;

subtest 'the cookie: name, attributes, value' => sub {
    ok( defined $value, 'the sign-in sets lazysite_auth' ) or diag $out;
    like( $set, qr/; HttpOnly; SameSite=Lax; Path=\/; Max-Age=86400(?:; Secure)?\z/,
        'HttpOnly, SameSite=Lax, Path=/, Max-Age = the session lifetime (86400 by default), Secure over HTTPS' );
    like( $out, qr/^Set-Cookie: lzs_session=1; SameSite=Lax; Path=\/; Max-Age=86400/m,
        'beside it the lzs_session=1 marker, which carries no identity' );
    like( $value, qr/\A[A-Za-z0-9_.~:%-]+:[a-f0-9]{64}\z/,
        'the value is the percent-encoded payload, a colon, and 64 lowercase hex' );
};

subtest 'the payload: username:timestamp:sid:groups' => sub {
    is( scalar @f, 4, 'four fields' );
    is( $f[0], 'alice', 'the account name' );
    ok( $f[1] =~ /\A\d+\z/ && abs( $f[1] - time() ) < 60, 'the issue time, in epoch seconds' );
    like( $f[2], qr/\A[0-9a-f]{16}\z/, 'a session id of exactly 16 lowercase hex' );
    is( $f[3], 'editors', 'the groups at sign-in, comma-separated' );
};

subtest 'the key: lazysite/auth/.secret, as text, compared in constant time' => sub {
    my $raw = slurp("$lz/auth/.secret");
    like( $raw, qr/\A[0-9a-f]{64}\n\z/, 'one line of 64 lowercase hex' );
    my $mode = ( stat "$lz/auth/.secret" )[2] & 0777;
    is( $mode & 0007, 0, 'with no world bits' );
    my ($key) = split /\n/, $raw;
    is( substr( $value, -64 ), hmac_sha256_hex( $payload, $key ), 'the signature is HMAC-SHA256 over the decoded payload, keyed by the hex TEXT' );
    isnt( substr( $value, -64 ), hmac_sha256_hex( $payload, pack( 'H*', $key ) ), 'not by the bytes it spells' );
    my $src = slurp("$root/lib/Lazysite/Auth/Session.pm");
    like( $src, qr/const_eq\(\s*\$sig,\s*hmac_sha256_hex\(\s*\$payload,\s*\$secret\s*\)\s*\)/,
        'and the engine compares it with const_eq' );
};

subtest 'the outside process and the engine agree' => sub {
    agree( $value, { user => 'alice', sid => $f[2] }, 'a fresh cookie' );
    my ( $o, $e ) = engine_verify($value);
    is( $o->{groups}, 'editors', 'the engine resolves groups' );
    spit( "$lz/auth/groups", "editors: bob\nadmins: alice\n" );
    ($o) = outside_verify($value);
    ($e) = engine_verify($value);
    is( $e->{groups}, 'admins', 'FRESH from the groups file - the cookie still says editors' );
    is( $o->{groups}, 'admins', 'and the outside process reads them the same way' );

    my $legacy = mint( 'alice:' . ( time() - 100 ) . ':editors' );
    agree( $legacy, { user => 'alice', sid => '' }, 'a legacy three-field cookie' );

    my $tampered = $value;
    substr( $tampered, 0, 5 ) = 'bob%3';
    agree( $tampered, undef, 'a tampered payload' );
    agree( mint( 'alice:' . ( time() - 86_400 ) . ":$f[2]:editors" ), undef, 'a cookie a lifetime old' );
    agree( mint( 'alice:' . ( time() - 86_400 ) . ':editors' ), undef, 'a legacy cookie a lifetime old' );

    spit( "$lz/lazysite.conf", "site_name: T\nsession_lifetime: 600\n" );
    agree( mint( 'alice:' . ( time() - 601 ) . ":$f[2]:editors" ), undef, 'past a configured session_lifetime' );
    agree( mint( 'alice:' . ( time() - 30 ) . ":$f[2]:editors" ), { user => 'alice', sid => $f[2] }, 'inside it' );
    spit( "$lz/lazysite.conf", "site_name: T\n" );

    agree( mint( 'carol:' . time() . ':0123456789abcdef:' ), undef, 'an account the users file does not hold' );
    spit( "$lz/auth/user-settings.json", '{"alice":{"disabled":1}}' );
    agree( $value, undef, 'a disabled account' );
    unlink "$lz/auth/user-settings.json";
};

subtest 'revoked.json: revoked sids and a per-user not_before' => sub {
    spit( "$lz/auth/revoked.json", encode_json( { sids => { $f[2] => time() }, not_before => {} } ) );
    agree( $value, undef, 'a revoked sid' );
    my $other = mint( 'alice:' . time() . ':fedcba9876543210:editors' );
    agree( $other, { user => 'alice', sid => 'fedcba9876543210' }, 'another session of the same account' );

    spit( "$lz/auth/revoked.json", encode_json( { sids => {}, not_before => { alice => time() + 5 } } ) );
    agree( $other, undef, 'not_before ends every session issued before it' );
    agree( mint( 'alice:' . time() . ':editors' ), undef, 'legacy ones included' );
    agree( mint( 'bob:' . time() . ':fedcba9876543211:' ), { user => 'bob', sid => 'fedcba9876543211' },
        'another account is untouched' );

    spit( "$lz/auth/revoked.json", encode_json( { sids => {}, not_before => { alice => time() + 5 },
                kept => { alice => { sid => 'fedcba9876543210', nb => time() + 5 } } } ) );
    agree( $other, { user => 'alice', sid => 'fedcba9876543210' }, 'except the one session kept beside that not_before' );
    unlink "$lz/auth/revoked.json";
};

subtest 'verifying writes nothing, and a rotated key ends every cookie' => sub {
    my %before = map { $_ => ( stat $_ )[9] } glob "$lz/auth/* $lz/auth/.secret";
    engine_verify($value);
    outside_verify($value);
    my %after = map { $_ => ( stat $_ )[9] } glob "$lz/auth/* $lz/auth/.secret";
    is_deeply( \%after, \%before, 'the auth store is unchanged by a verification' );

    spit( "$lz/auth/.secret", ( 'b' x 64 ) . "\n" );
    agree( $value, undef, 'a cookie signed with the previous key' );
};

done_testing();
