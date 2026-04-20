#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

# We can't `do` lazysite-auth.pl in-process — it calls handle_request at
# load time and exec()s the processor. Test sanitise_next by copying its
# definition (it's a small pure function) to pin the contract. This copy
# MUST mirror the real sanitise_next exactly.

*sanitise_next = sub {
    my ($next) = @_;
    return '/' unless defined $next && length $next;
    # H-1: reject protocol-relative and backslash forms before the main
    # character-class check. Otherwise //evil.com matches \A/[\w/.-]*\z.
    return '/' if $next =~ m{\A(?://|\\)};
    return '/' unless $next =~ m{\A/[\w/.-]*\z};
    return $next;
};

# --- allowed paths ---
is( sanitise_next('/about'),         '/about',         'relative path accepted' );
is( sanitise_next('/docs/install'),  '/docs/install',  'subpath accepted' );
is( sanitise_next('/a-b_c.d'),       '/a-b_c.d',       'safe chars allowed' );

# --- rejected patterns → / ---
is( sanitise_next('https://evil.com'), '/', 'absolute URL rejected' );

is( sanitise_next('//evil.com'),   '/', 'protocol-relative //host rejected' );
is( sanitise_next('///evil.com'),  '/', 'triple-slash rejected' );
is( sanitise_next('\\evil.com'),   '/', 'backslash rejected' );

is( sanitise_next('../../../etc'),     '/', 'path traversal rejected' );
is( sanitise_next(''),                 '/', 'empty string → /' );
is( sanitise_next(undef),              '/', 'undef → /' );
is( sanitise_next('javascript:void'),  '/', 'javascript: scheme rejected' );

# --- cookie signing shape: payload:hex64 ---
{
    my $secret  = 'test-secret';
    my $payload = 'alice:1234567890:admins';
    my $sig     = hmac_sha256_hex( $payload, $secret );
    is( length $sig, 64, 'hmac_sha256_hex signature is 64 hex chars' );
    my $cookie  = "$payload:$sig";
    like( $cookie, qr/^.+:[a-f0-9]{64}$/, 'cookie matches expected shape' );

    # Tamper detection
    my $tampered = $payload . 'X';
    isnt( hmac_sha256_hex( $tampered, $secret ), $sig,
        'any payload change changes signature' );

    # Wrong secret does not match
    isnt( hmac_sha256_hex( $payload, 'wrong' ), $sig,
        'wrong secret yields different signature' );
}

# --- auth script exists and has expected sub defined (sanity) ---
{
    my $auth_src = repo_root() . '/lazysite-auth.pl';
    ok( -f $auth_src, 'lazysite-auth.pl exists' );
    open my $fh, '<', $auth_src; my $src = do { local $/; <$fh> }; close $fh;
    like( $src, qr/sub sanitise_next/, 'sanitise_next defined in source' );
    like( $src, qr/COOKIE_MAX\s*=\s*86400/, 'cookie max-age is 24h' );
}

done_testing();
