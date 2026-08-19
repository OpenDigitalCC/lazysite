#!/usr/bin/perl
# SM411: session verification is ONE chain in Lazysite::Auth::Session, and it
# is the FULL chain.
#
# Extracted so a surface that cannot sit behind the auth wrapper can still hold
# a real identity - SM402 measured the alternative: the form handler recorded
# X-Remote-User exactly as the client sent it, because it had no way to verify.
# The data endpoint (SM410 DP-3) is the second caller by design.
#
# THE RISK OF EXTRACTION is quiet weakening: auth.pl had TWO verifiers - the
# full chain in handle_request and a SUBSET in _session_identity that skipped
# the disabled-account and revoked-session checks. If the extraction had
# packaged the subset, every future caller would inherit the gap. So this test
# drives the module through every stage with REAL state files, not by reading
# the source: a real HMAC cookie against a real secret, a real
# user-settings.json, a real revoked.json, a real groups file.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Session qw(verify_session_cookie SESSION_COOKIE_NAME);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
$Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";

my $SECRET = 'a' x 64;
sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
spit( "$d/lazysite/auth/.secret", "$SECRET\n" );
spit( "$d/lazysite/auth/groups",  "admins: alice\neditors: alice, bob\n" );

sub cookie_for {
    my (%o) = @_;
    my $payload = join ':',
        $o{user} // 'alice',
        $o{ts}   // time(),
        ( exists $o{sid} ? $o{sid} : 'abcdef0123456789' ),
        $o{groups} // 'stale-baked-group';
    my $sig = hmac_sha256_hex( $payload, $o{secret} // $SECRET );
    return "$payload:$sig";
}

sub verify_with {
    my ($cookie) = @_;
    local $ENV{HTTP_COOKIE} =
        defined $cookie ? SESSION_COOKIE_NAME . "=$cookie" : '';
    return verify_session_cookie();
}

subtest 'a valid cookie yields the identity, with FRESH groups' => sub {
    my ( $ident, $why ) = verify_with( cookie_for() );
    ok( $ident, 'verified' ) or diag $why;
    is( $ident->{user}, 'alice',            'user' );
    is( $ident->{sid},  'abcdef0123456789', 'sid' );
    is( $ident->{groups}, 'admins,editors',
        'groups come from the groups FILE, not the cookie - the baked '
            . '"stale-baked-group" is nowhere (SEC-2026-07 M5)' );
};

subtest 'a legacy 3-field cookie stays valid, with no sid' => sub {
    my $payload = 'alice:' . time() . ':some,groups';
    my ( $ident, $why )
        = verify_with( "$payload:" . hmac_sha256_hex( $payload, $SECRET ) );
    ok( $ident, 'verified' ) or diag $why;
    is( $ident->{sid}, '', 'legacy cookie carries no sid' );
};

subtest 'each failure stage refuses with its own reason' => sub {
    my %case = (
        'no-cookie' => undef,
        'malformed' => 'not-a-cookie-shape',
        'signature' => cookie_for( secret => 'b' x 64 ),
        'expired'   => cookie_for( ts     => time() - 90_000 ),
    );
    for my $want ( sort keys %case ) {
        my ( $ident, $why ) = verify_with( $case{$want} );
        ok( !$ident, "$want: refused" );
        is( $why, $want, "$want: named" );
    }

    # Tampering: flip one payload character, keep the signature.
    my $c = cookie_for();
    substr( $c, 0, 1 ) = 'z';
    my ($ident) = verify_with($c);
    ok( !$ident, 'tampered payload refused' );
};

subtest 'THE CHECKS THE OLD SUBSET SKIPPED are in the one chain' => sub {
    # Disabled account: a valid cookie is not an identity.
    spit( "$d/lazysite/auth/user-settings.json",
        '{"alice":{"disabled":1}}' );
    my ( $ident, $why, %detail ) = verify_with( cookie_for() );
    ok( !$ident, 'disabled account refused despite a valid cookie' );
    is( $why,          'disabled', 'named' );
    is( $detail{user}, 'alice',    'and the caller can log who' );
    unlink "$d/lazysite/auth/user-settings.json";

    # Revoked sid.
    spit( "$d/lazysite/auth/revoked.json",
        '{"sids":{"abcdef0123456789":1}}' );
    ( $ident, $why ) = verify_with( cookie_for() );
    ok( !$ident, 'revoked session refused' );
    is( $why, 'revoked', 'named' );

    # not_before kills a LEGACY cookie too (it has no sid to revoke).
    spit( "$d/lazysite/auth/revoked.json",
        '{"not_before":{"alice":' . ( time() + 10 ) . '}}' );
    my $payload = 'alice:' . time() . ':grp';
    ( $ident, $why )
        = verify_with( "$payload:" . hmac_sha256_hex( $payload, $SECRET ) );
    ok( !$ident, 'not_before revokes a legacy cookie' );
    is( $why, 'revoked', 'named' );
    unlink "$d/lazysite/auth/revoked.json";
};

subtest 'verification never mints the secret' => sub {
    my $d2 = tempdir( CLEANUP => 1 );
    make_path("$d2/lazysite/auth");
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$d2/lazysite";
    my ( $ident, $why ) = verify_with( cookie_for() );
    ok( !$ident, 'no secret, no identity' );
    is( $why, 'signature', 'refused as unverifiable' );
    ok( !-f "$d2/lazysite/auth/.secret",
        'and NO secret was created - verification is read-only' );
};

# The wrapper delegates rather than keeping a second copy of the chain.
subtest 'lazysite-auth.pl carries no verifier of its own' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-auth.pl" or die $!;
        local $/; <$fh>;
    };
    like( $src, qr/verify_session_cookie/, 'the wrapper calls the module' );
    unlike( $src, qr/sub _session_revoked/,
        'the revocation reader lives only in the module' );
    unlike( $src, qr/sub account_disabled/,
        'so does the disabled-account reader' );
};

done_testing();
