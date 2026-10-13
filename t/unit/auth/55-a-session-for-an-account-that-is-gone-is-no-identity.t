#!/usr/bin/perl
# SM1070 (n562, ruled 2026-10-13 "Probe, then fix"): a signed session cookie for
# an account that no longer exists is not an identity.
#
# verify_session_cookie checked the signature, the expiry, the disabled flag and
# the revocation list, and never asked whether the account was still in
# lazysite/auth/users. Removing an account deletes its line, its groups and its
# settings row - so its disabled flag went with it - and the cookie kept
# verifying as that name until it expired: the members' pages, /account, the
# bell, a form's rate-limit waiver and a personal row owned in the removed name.
#
# Now the chain asks the account store, after the signature and before the
# other stores, and answers:
#
#   no-account   the store answered and the name is not in it (an absent store
#                is a site with no accounts, which is an answer too)
#   cannot-tell  the store exists and cannot be read - SM1024's rule: never
#                "exists", never "gone"; named as lazysite/auth/users
#
# A passwordless account is flagged on the identity (no_password), so the auth
# wrapper takes the flag from this one read instead of reading the store again.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session;

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);
sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$auth/.secret", 'c' x 64 );
put( "$auth/groups",  "staff: ann, bob\n" );

no warnings 'once';
$Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";

sub verify {
    my ( $user, $sid ) = @_;
    my $payload = "$user:" . time() . ':' . ( $sid // 'abcdef0123456789' ) . ':staff';
    local $ENV{HTTP_COOKIE} = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, 'c' x 64 );
    return Lazysite::Auth::Session::verify_session_cookie();
}

my $USERS = "# accounts\nann:\$argon2id\$x\nbob:\n";

subtest 'an account in the store verifies' => sub {
    put( "$auth/users", $USERS );
    my ( $id, $why ) = verify('ann');
    ok( $id, 'ann verifies' ) or diag $why;
    is( $id->{user},   'ann',   'as ann' );
    is( $id->{groups}, 'staff', 'with her groups, read fresh' );
    ok( !$id->{no_password}, 'an account with a password is not flagged passwordless' );
    my ($b) = verify('bob');
    ok( $b && $b->{no_password}, 'a passwordless account is flagged on the identity' );
};

subtest 'an account REMOVED from the store is no identity' => sub {
    put( "$auth/users", "ann:\$argon2id\$x\n" );
    my ( $id, $why, %detail ) = verify('bob');
    ok( !$id, 'no identity for bob' );
    is( $why,          'no-account', 'the reason is no-account' );
    is( $detail{user}, 'bob',        'naming the account' );
    my ($ann) = verify('ann');
    ok( $ann, 'ann, still in the store, still verifies' );
};

subtest 'a name that is only a PREFIX of an account is no account' => sub {
    put( "$auth/users", "annabel:\$argon2id\$x\n" );
    my ( $id, $why ) = verify('ann');
    ok( !$id, 'ann is not annabel' );
    is( $why, 'no-account', 'no-account' );
};

subtest 'an ABSENT account store is a site with no accounts' => sub {
    unlink "$auth/users";
    my ( $id, $why ) = verify('ann');
    ok( !$id, 'no identity' );
    is( $why, 'no-account', 'no-account, not cannot-tell: absence is an answer' );
};

SKIP: {
    skip 'root reads a mode-0 file', 4 if $> == 0;
    subtest 'an UNREADABLE account store is cannot-tell, never "exists"' => sub {
        put( "$auth/users", $USERS );
        chmod 0000, "$auth/users";
        my ( $id, $why, %detail ) = verify('ann');
        chmod 0600, "$auth/users";
        ok( !$id, 'no identity' );
        is( $why,           'cannot-tell',         'cannot-tell' );
        is( $detail{store}, 'lazysite/auth/users', 'naming the store' );
    };
}

subtest 'disabled and revoked still answer as they did' => sub {
    put( "$auth/users",              $USERS );
    put( "$auth/user-settings.json", '{"ann":{"disabled":1}}' );
    my ( $id, $why ) = verify('ann');
    ok( !$id, 'a disabled account is no identity' );
    is( $why, 'disabled', 'disabled' );
    unlink "$auth/user-settings.json";
    put( "$auth/revoked.json", '{"sids":{"abcdef0123456789":' . time() . '}}' );
    ( $id, $why ) = verify('ann');
    is( $why, 'revoked', 'a revoked session is revoked' );
    unlink "$auth/revoked.json";
};

done_testing();
