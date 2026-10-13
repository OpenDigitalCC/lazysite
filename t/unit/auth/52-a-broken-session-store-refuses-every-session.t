#!/usr/bin/perl
# SM1024 follow-up (ruled 2026-10-12, "Close all three"): a session store that
# exists and cannot be read or decoded refuses sessions until it is repaired.
#
# Lazysite::Auth::Session read a broken revoked.json as "nothing is revoked" and
# a broken user-settings.json as "nobody is disabled", both with a WARN. So a
# stray comma in either let a signed-out session or a disabled account straight
# back in. Now each answers CANNOT-TELL: the cookie verifies to no identity with
# the reason `cannot-tell` naming the store, and the Sessions page's readers and
# writers refuse rather than overwrite it. An ABSENT store - a fresh site - is
# still an answer: nothing revoked, nobody disabled.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session;
use Lazysite::Manager::Sessions;

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);
sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$auth/.secret", 'c' x 64 );
put( "$auth/groups",  "staff: ann\n" );
# SM1070: ann exists - a cookie for an account the store does not hold is no
# identity, which would answer before either store below is asked.
put( "$auth/users", "ann:x\n" );

no warnings 'once';
$Lazysite::Auth::Session::LAZYSITE_DIR     = "$d/lazysite";
$Lazysite::Manager::Sessions::LAZYSITE_DIR = "$d/lazysite";

my $SID = 'abcdef0123456789';

sub verify {
    my $payload = 'ann:' . time() . ":$SID:staff";
    local $ENV{HTTP_COOKIE} = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, 'c' x 64 );
    return Lazysite::Auth::Session::verify_session_cookie();
}

# The sign-in gate's question; the sub is new with this change.
sub store_fault {
    my $f = Lazysite::Auth::Session->can('session_store_fault') or return '(no such sub)';
    return $f->();
}

my $BROKEN = '{ "sids": { "x": 1 ';

subtest 'ABSENT stores: a fresh site revokes nothing and disables nobody' => sub {
    my ( $id, $why ) = verify();
    ok( $id, 'the session verifies' ) or diag $why;
    is( store_fault(), '', 'and no store is at fault' );
    my $l = Lazysite::Manager::Sessions::action_sessions_list();
    ok( $l->{ok}, 'the Sessions list answers' );
};

for my $store (qw(revoked.json user-settings.json)) {
    for my $case ( [ 'truncated', $BROKEN ], [ 'empty', '' ], [ 'an array', '[]' ] ) {
        my ( $what, $bytes ) = @$case;
        subtest "BROKEN $store ($what): the session is refused, cannot-tell" => sub {
            put( "$auth/$store", $bytes );
            my ( $id, $why, %detail ) = verify();
            ok( !$id, 'no identity' );
            is( $why,           'cannot-tell',          'the reason is cannot-tell' );
            is( $detail{store}, "lazysite/auth/$store", 'naming the store' );
            is( store_fault(), "lazysite/auth/$store",
                'and session_store_fault names it for the sign-in gate' );
            unlink "$auth/$store";
        };
    }
}

subtest 'BROKEN revoked.json: the Sessions page refuses and writes nothing' => sub {
    put( "$auth/revoked.json", $BROKEN );
    my $l = Lazysite::Manager::Sessions::action_sessions_list();
    is( $l->{kind},  'cannot-tell',                'the list is cannot-tell' );
    is( $l->{store}, 'lazysite/auth/revoked.json', 'naming the store' );
    my $r = Lazysite::Manager::Sessions::action_session_revoke($SID);
    is( $r->{kind}, 'cannot-tell', 'a revoke is refused' );
    $r = Lazysite::Manager::Sessions::action_user_revoke('ann');
    is( $r->{kind}, 'cannot-tell', 'a sign-out-everywhere is refused' );
    open my $fh, '<:raw', "$auth/revoked.json" or die $!;
    is( do { local $/; <$fh> }, $BROKEN, 'and the store is byte-for-byte as it was' );
    unlink "$auth/revoked.json";
};

subtest 'READABLE stores still decide' => sub {
    put( "$auth/revoked.json", qq({"sids":{"$SID":) . time() . '},"not_before":{}}' );
    my ( $id, $why ) = verify();
    is( $why, 'revoked', 'a revoked sid is revoked' );
    unlink "$auth/revoked.json";
    put( "$auth/user-settings.json", '{"ann":{"disabled":1}}' );
    ( $id, $why ) = verify();
    is( $why, 'disabled', 'a disabled account is disabled' );
    unlink "$auth/user-settings.json";
    ( $id, $why ) = verify();
    ok( $id, 'and with both gone again the session verifies' );
};

SKIP: {
    skip 'running as root: chmod 000 does not refuse root', 1 if $> == 0;
    subtest 'UNREADABLE revoked.json is the same cannot-tell' => sub {
        put( "$auth/revoked.json", '{}' );
        chmod 0, "$auth/revoked.json";
        my ( $id, $why ) = verify();
        chmod 0644, "$auth/revoked.json";
        is( $why, 'cannot-tell', 'refused' );
        unlink "$auth/revoked.json";
    };
}

done_testing();
