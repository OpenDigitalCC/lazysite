#!/usr/bin/perl
# SM1390 (ruling 147): three gaps in the session verifier, found while writing
# the cookie contract (SM1383), closed as hardening.
#
#   1. A value signed for another purpose is not a session. The preview cookie
#      is signed with the same key over `v1:<exp>:<layout>:<theme>:<user>`, and
#      that parsed as a legacy session for an account named `v1` - the preview's
#      expiry, years ahead, serving as its issue time. The preview marker is
#      refused as a first field. (The preview verifier's half, a session shape
#      refused as a preview, is t/integration/361.)
#   2. A timestamp in the future is refused, beyond a stated clock-skew
#      allowance; the lifetime check only asked whether a cookie was too OLD.
#   3. The five-field sliding shape the reader was written for was unreachable
#      (a split with a limit of 4 never yields five fields), so such a cookie
#      verified as legacy with no sid. It is reachable on purpose now.
#
# Each, reverted, fails here; and the legacy three-field cookie still verifies.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session qw(verify_session_cookie SESSION_COOKIE_NAME);

my $d = site_tempdir();
make_path("$d/lazysite/auth");
$Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";

my $SECRET = 'a' x 64;
sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
spit( "$d/lazysite/auth/.secret", "$SECRET\n" );
spit( "$d/lazysite/auth/groups",  "admins: v1, alice\n" );
spit( "$d/lazysite/auth/users",   "alice:x\nv1:x\n" );

sub signed { my ($payload) = @_; return "$payload:" . hmac_sha256_hex( $payload, $SECRET ) }
sub verify { my ($c) = @_; return verify_session_cookie( cookie => SESSION_COOKIE_NAME . "=$c" ) }
my $SID  = 'abcdef0123456789';
my $SKEW = Lazysite::Auth::Session::CLOCK_SKEW();

subtest 'a preview cookie value is not a session, even for an account named v1' => sub {
    # The preview mint's own shape (Lazysite::Manager::Preview), one hour out.
    my $preview = signed( 'v1:' . ( time() + 3600 ) . ':default:plain:alice' );
    my ( $ident, $why ) = verify($preview);
    ok( !$ident, 'refused' ) or diag explain $ident;
    is( $why, 'malformed', 'as not a session cookie at all' );

    # And not only because its timestamp is ahead: a preview that has expired
    # is a legacy-shaped payload with a past timestamp and the same marker.
    ( $ident, $why ) = verify( signed( 'v1:' . ( time() - 10 ) . ':default:plain:alice' ) );
    ok( !$ident, 'an expired preview is refused the same way' );
    is( $why, 'malformed', 'by its marker, before the timestamp is read' );
};

subtest 'a timestamp in the future is refused, beyond the skew allowance' => sub {
    is( $SKEW, 300, 'the allowance the contract states: 300 seconds' );
    my ( $ident, $why, %d ) = verify( signed( 'alice:' . ( time() + $SKEW + 60 ) . ":$SID:admins" ) );
    ok( !$ident, 'a cookie issued six minutes from now is refused' );
    is( $why, 'expired', 'as not valid at this time' );
    ( $ident, $why ) = verify( signed( 'alice:' . ( time() + $SKEW - 60 ) . ":$SID:admins" ) );
    ok( $ident, 'one issued four minutes from now - inside the skew - verifies' ) or diag $why;
    ( $ident, $why ) = verify( signed( 'alice:' . ( time() + $SKEW + 60 ) . ':admins' ) );
    ok( !$ident, 'and a legacy cookie from the future is refused too' );
};

subtest 'the five-field sliding shape is reachable, and read as itself' => sub {
    my $ts   = time() - 3000;
    my $seen = time() - 10;
    my ( $ident, $why ) = verify( signed( "alice:$ts:$seen:$SID:admins" ) );
    ok( $ident, 'user:ts:seen:sid:groups verifies' ) or diag $why;
    is( $ident->{sid}, $SID, 'with its sid - not as a legacy cookie with none' );

    spit( "$d/lazysite/lazysite.conf", "site_name: T\nsession_lifetime: 600\n" );
    %Lazysite::Auth::Session::LIFETIME_CACHE = ();
    ( $ident, $why ) = verify( signed( "alice:$ts:$seen:$SID:admins" ) );
    ok( $ident, 'its age is counted from `seen`: issued 50 minutes ago, seen 10 seconds ago, lifetime 10 minutes' )
        or diag $why;
    ( $ident, $why ) = verify( signed( "alice:$ts:$SID:admins" ) );
    ok( !$ident, 'while the four-field cookie issued 50 minutes ago has expired' );
    is( $why, 'expired', 'as before' );
    ( $ident, $why ) = verify( signed( "alice:$ts:" . ( time() + $SKEW + 60 ) . ":$SID:admins" ) );
    ok( !$ident, 'and a `seen` in the future is refused like a `ts` in the future' );
    unlink "$d/lazysite/lazysite.conf";
    %Lazysite::Auth::Session::LIFETIME_CACHE = ();
};

subtest 'the two issued shapes still verify' => sub {
    my ( $ident, $why ) = verify( signed( 'alice:' . time() . ":$SID:stale" ) );
    ok( $ident, 'the current four-field cookie' ) or diag $why;
    is( $ident->{sid}, $SID, 'with its sid' );
    ( $ident, $why ) = verify( signed( 'alice:' . ( time() - 100 ) . ':stale' ) );
    ok( $ident, 'the legacy three-field cookie' ) or diag $why;
    is( $ident->{sid},    '',       'with no sid' );
    is( $ident->{groups}, 'admins', 'and groups fresh from the file' );
};

done_testing();
