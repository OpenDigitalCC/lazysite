#!/usr/bin/perl
# SM1352: the shipped pages offer a passkey where it is used.
#   - /login: "Sign in with a passkey", a form posting to ?action=passkey-login, shown
#     by the account helper only to a browser that can use one; the helper is added
#   - /claim: "Use a passkey instead", posting the same setup link's username and
#     claim to ?action=claim
#   - /account: the ::: account-passkeys component
#   - the installed app signs in through the same page: the worker never answers the
#     sign-in page or the auth wrapper, so the passkey sign-in reaches the server
#   (a server without CryptX: the challenge refuses, t/unit/auth/107; the pages ask
#   _passkeys_available, which looks the library up on @INC)
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_processor site_tempdir);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };

my $root = repo_root();

sub site {
    my $d = site_tempdir();
    system( 'cp', '-r', "$root/starter/.", $d ) == 0 or die 'copy starter';
    make_path("$d/lazysite/cache");
    make_path("$d/lazysite/layouts/probe");
    open my $lf, '>', "$d/lazysite/layouts/probe/layout.tt" or die $!;
    print $lf '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
        . '<body>[% content %]</body></html>';
    close $lf;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Probe\nlayout: probe\napp_name: Probe\napp_icon_192: /favicon.png\n";
    close $cf;
    return $d;
}

my $d = site();

my $login = run_processor( $d, '/login' );
like( $login, qr/data-ls-account="passkey-signin"/, '/login carries the passkey region' );
like( $login, qr{action="/cgi-bin/lazysite-auth\.pl\?action=passkey-login"}, 'posting to passkey-login' );
like( $login, qr/>Sign in with a passkey</, 'with a button that says what it does' );
like( $login, qr{/assets/lazysite-account\.js}, 'and the helper that binds it' );
like( $login, qr/data-ls-account="passkey-signin"[^>]*hidden/, 'hidden until the helper finds a browser that can use one' );

my $claim = run_processor( $d, '/claim', QUERY_STRING => 'u=alice&c=abc123' );
like( $claim, qr/data-ls-account="passkey-claim"/, '/claim carries the passkey region' );
like( $claim, qr/>Use a passkey instead</, 'offering it instead of the password' );
like( $claim, qr/name="claim" value="abc123"/, 'through the same setup link' );

my $acct = run_processor( $d, '/account', HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => '',
    LAZYSITE_AUTH_TRUSTED => 1 );
like( $acct, qr/data-ls-account="passkeys"/, '/account carries ::: account-passkeys' );

my $sw = run_processor( $d, '/lazysite-sw.js' );
like( $sw, qr/"never":\[[^\]]*"\/login"/, 'the installed app\'s worker never answers the sign-in page' );
like( $sw, qr/lazysite-\[a-z0-9-\]\+\\\.pl/, 'nor the auth wrapper the passkey answer is posted to' );

done_testing();
