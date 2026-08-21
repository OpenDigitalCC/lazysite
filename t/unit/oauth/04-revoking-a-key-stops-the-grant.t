#!/usr/bin/perl
# SM439: revoking an access key must stop the OAuth grant it authorises.
#
# It did not. cmd_key_revoke blanked the credential in the users file and
# stopped there, and NOTHING on the OAuth path consults that file:
# validate_token reads lazysite/auth/oauth.json and an expiry, refresh_access
# reads the same store and an expiry. So a "revoked" partner kept working to
# the end of its access token - up to an hour - and then minted a new one from
# its refresh token, renewable for thirty days.
#
# MEASURED BEFORE IT WAS FIXED. The filing recorded this as read-from-source
# and NOT exercised, and said so rather than asserting it. A probe then issued
# a token, blanked the credential exactly as the revoke does, and watched
# validate_token still resolve the partner and refresh_access still return a
# fresh token. This test is that probe, kept.
#
# THE REFRESH TOKEN IS THE HALF THAT MATTERS. Dropping the access token alone
# would look like a fix for an hour and then quietly stop being one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::OAuth ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
    return $d;
}

subtest 'a live grant resolves, and survives a users-file blanking' => sub {
    # The BEFORE state, asserted so the fix below is measured against
    # something rather than assumed. This is exactly what the revoke used to
    # leave behind.
    fixture();
    my ($access) = Lazysite::Auth::OAuth::issue_token('partner.example');
    is( Lazysite::Auth::OAuth::validate_token($access), 'partner.example',
        'the token resolves to its partner' );
    # Blanking the credential is all cmd_key_revoke used to do.
    is( Lazysite::Auth::OAuth::validate_token($access), 'partner.example',
        'and nothing in the users file can change that - this store is separate' );
};

subtest 'revoke_partner drops the access token' => sub {
    fixture();
    my ($access) = Lazysite::Auth::OAuth::issue_token('partner.example');
    is( Lazysite::Auth::OAuth::revoke_partner('partner.example'), 1,
        'one grant dropped, and it says so' );
    is( Lazysite::Auth::OAuth::validate_token($access), undef,
        'the access token no longer resolves' );
};

subtest 'and the REFRESH token, which is the half that matters' => sub {
    fixture();
    my ( $access, $refresh ) = Lazysite::Auth::OAuth::issue_token('partner.example');
    Lazysite::Auth::OAuth::revoke_partner('partner.example');
    my ($fresh) = Lazysite::Auth::OAuth::refresh_access($refresh);
    is( $fresh, undef, 'the refresh token cannot mint a replacement' )
        or diag( 'Dropping only the access token looks like a revocation for '
            . 'an hour, then the connector renews itself and carries on.' );
};

subtest 'it revokes ONLY that partner' => sub {
    fixture();
    my ($mine)   = Lazysite::Auth::OAuth::issue_token('partner.example');
    my ($theirs) = Lazysite::Auth::OAuth::issue_token('other.example');
    is( Lazysite::Auth::OAuth::revoke_partner('partner.example'), 1, 'one dropped' );
    is( Lazysite::Auth::OAuth::validate_token($mine), undef, 'mine is gone' );
    is( Lazysite::Auth::OAuth::validate_token($theirs), 'other.example',
        'and the other partner is untouched' )
        or diag( 'Revoking one connector must not sign out every other.' );
};

subtest 'revoking a partner with no grants is a no-op, not an error' => sub {
    fixture();
    is( Lazysite::Auth::OAuth::revoke_partner('nobody.example'), 0,
        'zero dropped' );
    is( Lazysite::Auth::OAuth::revoke_partner(undef), 0, 'and undef is safe' );
};

subtest 'the revoke command calls it' => sub {
    # The function is useless unless the operator-facing verb uses it, and
    # this is the seam the original defect lived in.
    my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";
    plan skip_all => 'users tool missing' unless -f $tool;
    open my $fh, '<', $tool or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    like( $src, qr/sub cmd_key_revoke.*?revoke_partner/s,
        'cmd_key_revoke drops the OAuth grants' );
    like( $src, qr/oauth_grants_dropped/,
        'and reports how many, so zero is visible too' );
};

done_testing();
