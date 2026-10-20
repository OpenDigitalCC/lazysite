#!/usr/bin/perl
# SM1219 (#339, ruled 2026-10-20): the visitor log records the signed-in account.
#
# "visitor log to record user if user is logged in" - the account NAME, kept as
# long as the rest of the log. The one rule that matters is WHICH identity: the
# one the engine verified (the auth wrapper's session, a listed proxy's header),
# never a header a client typed. So the cases are:
#
#   a verified signed-in visit is recorded with its account (`u`)
#   an anonymous visit has no `u`
#   a forged X-Remote-User on a request nothing vouched for records nobody
#   the same forgery from a peer the proxy list does not name records nobody
#   a listed proxy's user is recorded (it is verified by the peer, SM1129)
#   a CACHE HIT served to a signed-in visitor still records them, and a cache hit
#   served to an anonymous one after it records nobody (the cached page is shared)
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor site_tempdir);

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    spit( "$d/lazysite/lazysite.conf",
        "site_name: T\n" . ( $o{proxy} ? "auth_proxy_trusted: true\nauth_proxy_trusted_from: 198.51.100.0/24\n" : '' ) );
    spit( "$d/index.md", "---\ntitle: Home\n---\nHOME\n" );
    return $d;
}

my ($today) = do { my @t = gmtime; sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };

sub lines {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/logs/access-$today.jsonl" or return ();
    my @l = map { decode_json($_) } <$fh>;
    close $fh;
    return @l;
}

my $UA = 'Mozilla/5.0 (X11; Linux) TestBrowser';

subtest 'the auth wrapper vouches: the account is recorded, an anonymous visit has none' => sub {
    my $d = site();
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.5', HTTP_USER_AGENT => $UA,
        LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => 'alice' );
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.6', HTTP_USER_AGENT => $UA );
    my @l = lines($d);
    is( scalar @l, 2, 'two requests, two lines' );
    is( $l[0]{u}, 'alice', 'the signed-in visit names its account' );
    ok( !exists $l[1]{u}, 'the anonymous visit carries no account field at all' );
};

subtest 'a forged X-Remote-User records nobody' => sub {
    my $d = site();
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.5', HTTP_USER_AGENT => $UA,
        HTTP_X_REMOTE_USER => 'mallory' );
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.5', HTTP_USER_AGENT => $UA,
        HTTP_X_REMOTE_USER => 'mallory', HTTP_X_REMOTE_GROUPS => 'admins' );
    my @l = lines($d);
    is( scalar @l, 2, 'both requests logged' );
    ok( !exists $_->{u}, 'and neither names the header\'s account' ) for @l;
    unlike( join( '', map { encode_json_text($_) } @l ), qr/mallory/, 'the forged name is nowhere in the log' );
};

sub encode_json_text { return JSON::PP->new->canonical->encode( $_[0] ) }

subtest 'a proxy the site trusts vouches only from its listed peer' => sub {
    my $d = site( proxy => 1 );
    run_processor( $d, '/', REMOTE_ADDR => '198.51.100.7', HTTP_USER_AGENT => $UA,
        HTTP_X_REMOTE_USER => 'carol' );
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.9', HTTP_USER_AGENT => $UA,
        HTTP_X_REMOTE_USER => 'mallory' );
    my @l = lines($d);
    is( $l[0]{u}, 'carol', 'the listed proxy\'s user is recorded' );
    ok( !exists $l[1]{u}, 'the same header from an unlisted peer is not' );
};

subtest 'a cache hit still records the signed-in requester, and never leaks them to the next' => sub {
    my $d = site();
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.5', HTTP_USER_AGENT => $UA );    # fills the cache
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.5', HTTP_USER_AGENT => $UA,
        LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => 'alice' );
    run_processor( $d, '/', REMOTE_ADDR => '203.0.113.8', HTTP_USER_AGENT => $UA );
    my @l = lines($d);
    is( scalar @l, 3, 'three lines' );
    is( $l[1]{c}, 1, 'the signed-in request was a cache hit' );
    is( $l[1]{u}, 'alice', '...and is recorded with its account' );
    is( $l[2]{c}, 1, 'the next anonymous request was a cache hit too' );
    ok( !exists $l[2]{u}, '...and carries no account' );
};

done_testing();
