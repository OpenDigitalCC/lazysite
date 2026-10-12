#!/usr/bin/perl
# SM1043 (SM1034 phase 1a): /account is a SYSTEM page - the SM201 fallback set -
# so it renders through the site's own layout, needs a signed-in account,
# restores itself when a site's copy is deleted, and carries the built-in
# ::: account-* components with the helper script that binds them.
# `account_page: disabled` withdraws it, and the processor's copy of the switch
# agrees with Lazysite::Util's for every spelling (ADR 0001 keeps the copy).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root run_processor site_tempdir);
use Lazysite::Util ();

my $root = repo_root();

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    system( 'cp', '-r', "$root/starter/.", $d ) == 0 or die 'copy starter';
    make_path("$d/lazysite/cache");
    make_path("$d/lazysite/layouts/probe");
    open my $lf, '>', "$d/lazysite/layouts/probe/layout.tt" or die $!;
    print $lf '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
        . '<body><header>SITE-LAYOUT-PROBE</header>[% content %]</body></html>';
    close $lf;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: Probe\nlayout: probe\n" . ( $conf // '' );
    close $cf;
    return $d;
}

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }

my %member = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => '',
    LAZYSITE_AUTH_TRUSTED => 1 );

# --- a signed-in member gets the page, in the site's layout -----------------------
{
    my $d = site();
    ok( -f "$d/lazysite/templates/system/account.md", 'the engine default ships with the system pages' );
    ok( !-f "$d/account.md", 'and is not seeded into the content' );

    my $out = run_processor( $d, '/account', %member );
    is( status_of($out), 200, '/account renders for a signed-in member' );
    like( $out, qr/SITE-LAYOUT-PROBE/, 'through the SITE\'s layout, not the manager\'s' );
    like( $out, qr/data-ls-account="password"/, 'with the password component' );
    like( $out, qr/data-ls-account="sessions"/, 'and the sessions component' );
    like( $out, qr{<script src="/assets/lazysite-account\.js\?v=[^"]*" defer></script>},
        'and the helper that binds them, added by the processor' );
    unlike( $out, qr/name="username"[^>]*value="[^"]+"/, 'no account is written into the form by the server' );

    my $anon = run_processor( $d, '/account', HTTP_X_REMOTE_USER => undef,
        LAZYSITE_AUTH_TRUSTED => undef );
    unlike( $anon, qr/data-ls-account/, 'nobody signed in: no account page' );
    isnt( status_of($anon), 200, 'nobody signed in: not a 200' );
}

# --- a site's own copy wins, and deleting it restores the default -------------------
{
    my $d = site();
    open my $fh, '>', "$d/account.md" or die $!;
    print $fh "---\ntitle: Mine\nauth: required\n---\n\nOWN-ACCOUNT-PAGE\n\n::: account-sessions\n:::\n";
    close $fh;
    my $own = run_processor( $d, '/account', %member );
    like( $own, qr/OWN-ACCOUNT-PAGE/,           'a site\'s own /account wins' );
    like( $own, qr/data-ls-account="sessions"/, 'and may use the built-in components' );
    unlink "$d/account.md", "$d/account.html";
    my $back = run_processor( $d, '/account', %member );
    is( status_of($back), 200, 'deleting it restores the engine default' );
    unlike( $back, qr/OWN-ACCOUNT-PAGE/, 'the deleted copy is gone' );
}

# --- a layout may restyle a component -----------------------------------------------
{
    my $d = site();
    make_path("$d/lazysite/layouts/probe/components");
    open my $cf, '>', "$d/lazysite/layouts/probe/components/account-password.tt" or die $!;
    print $cf '<section data-ls-account="password">LAYOUT-OWN-PASSWORD</section>';
    close $cf;
    my $out = run_processor( $d, '/account', %member );
    like( $out, qr/LAYOUT-OWN-PASSWORD/, 'a layout\'s component of the same name wins' );
}

# --- account_page: disabled ----------------------------------------------------------
{
    my $d   = site("account_page: disabled\n");
    my $out = run_processor( $d, '/account', %member );
    is( status_of($out), 404, 'account_page: disabled - /account answers 404' );
    unlike( $out, qr/data-ls-account/, 'and carries no account component' );
}

# --- the processor's switch and Util's agree on every spelling -------------------------
for my $v ( 'disabled', 'off', 'no', 'false', '0', 'enabled', 'on', 'yes', 'DISABLED', 'whatever' ) {
    my $d       = site("account_page: $v\n");
    my $out     = run_processor( $d, '/account', %member );
    my $page_on = status_of($out) == 200 ? 1 : 0;
    is( $page_on, Lazysite::Util::account_page_enabled("$d/lazysite") ? 1 : 0,
        "account_page: $v - the page and the actions agree" );
}

done_testing;
