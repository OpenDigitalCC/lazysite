#!/usr/bin/perl
# SM1295 (#340, SM1128 and SM1160's follow-up): A READY-MADE SIGN-IN PAGE FOR A
# SITE WHOSE SIGN-IN IS THE PERSON'S ODOO LOGIN.
#
# SM1160 left "a login page for an opted-in site" to the operator: set
# auth_redirect to a page carrying a data-ls-odoo-signin button. /odoo-signin is
# now that page, a system page in the SM201 fallback chain like login and forgot:
# served from the engine's default while odoo_site_signin is on (with the Odoo
# extension enabled) and 404 otherwise, a site's own copy winning, rendered in the
# site's layout with the Odoo helper that binds its button, and carrying no
# inline style - the fallback chrome and the form classes style it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_processor site_tempdir index_extensions);

my $root = repo_root();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub site {
    my (%o) = @_;
    # SM1369 X5: the component and the helper are the extension's, found through
    # the hook index the manager writes on enable; built here as it would be.
    my $d = site_tempdir( extensions => 1 );
    system( 'cp', '-r', "$root/starter/.", $d ) == 0 or die 'copy starter';
    make_path("$d/lazysite/cache");
    my $conf = "site_name: Probe\n";
    if ( $o{layout} ) {
        make_path("$d/lazysite/layouts/probe");
        spit( "$d/lazysite/layouts/probe/layout.tt", '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
                . '<body><header>SITE-LAYOUT-PROBE</header>[% content %]</body></html>' );
        $conf .= "layout: probe\n";
    }
    $conf .= "extensions:\n  - extensions/odoo.pl\n" if $o{extension};
    spit( "$d/lazysite/lazysite.conf", $conf );
    spit( "$d/lazysite/odoo.conf", "odoo_site_signin: $o{signin}\n" ) if defined $o{signin};
    index_extensions($d) if $o{extension};
    return $d;
}
sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }

my $page = "$root/starter/lazysite/templates/system/odoo-signin.md";
my $comp = "$root/extensions/odoo/templates/components/odoo-signin.tt";

subtest 'the engine default ships with the system pages, with no inline style' => sub {
    ok( -f $page, 'lazysite/templates/system/odoo-signin.md' );
    ok( -f $comp, 'and the component it uses, the extension\'s own extensions/odoo/templates/components/odoo-signin.tt (SM1369 X5)' );
    like( do { open my $fh, '<', $page or die $!; local $/; <$fh> }, qr/^::: odoo-signin\n:::$/m, 'the page uses it' );
    my $src = join '', map { open my $fh, '<', $_ or die $!; local $/; <$fh> } $page, $comp;
    unlike( $src, qr/<style\b/i, 'no <style> block' );
    unlike( $src, qr/\bstyle\s*=/i, 'no style attribute' );
    like( $src, qr/<button type="button" data-ls-odoo-signin data-ls-odoo-next>/, 'a button the Odoo helper binds' );
    like( $src, qr/class="lazysite-form"/, 'inside the form class the stylesheets style' );
    ok( !-f "$root/starter/odoo-signin.md", 'and it is not seeded into the content' );
};

subtest 'switched on: the page renders, in the site\'s layout' => sub {
    my $d   = site( layout => 1, extension => 1, signin => 'on' );
    my $out = run_processor( $d, '/odoo-signin' );
    is( status_of($out), 200, '/odoo-signin answers' );
    like( $out, qr/SITE-LAYOUT-PROBE/, 'through the site\'s layout' );
    like( $out, qr/data-ls-odoo-signin/, 'with the sign-in button' );
    like( $out, qr/data-ls-odoo-in hidden>Signed in as <strong data-ls-odoo-name><\/strong>/,
        'and the signed-in line the helper fills' );
    like( $out, qr{<section class="lz-odoo-signin"><div class="lazysite-form" data-ls-odoo-out><p class="form-field form-submit"><button}, '...as one block the Markdown pass leaves whole' );
    unlike( $out, qr{<p></section>|</p></p>}, '...with no stray paragraph tags' );
    like( $out, qr{<script src="/assets/lazysite-odoo\.js\?v=[^"]*" data-ls-odoo-display-name="Odoo" defer></script>},
        'and the Odoo helper, added by the processor (SM1328: carrying the name it says)' );
    my ($body) = $out =~ /<header>SITE-LAYOUT-PROBE<\/header>(.*)<\/body>/s;
    unlike( $body // '', qr/\bstyle\s*=|<style\b/i, 'the page itself carries no inline style' );
};

subtest 'under the fallback layout it wears the fallback chrome and its form rules' => sub {
    my $d   = site( extension => 1, signin => 'on' );
    my $out = run_processor( $d, '/odoo-signin' );
    is( status_of($out), 200, 'served' );
    like( $out, qr/<body class="lazysite-fallback">/, 'the fallback page' );
    like( $out, qr{/assets/lazysite-chrome\.css}, 'with the chrome stylesheet' );
    my $css = do { open my $fh, '<', "$root/starter/assets/lazysite-chrome.css" or die $!; local $/; <$fh> };
    like( $css, qr/\.lazysite-fallback \.lazysite-form \.form-field\.form-submit > button \{/,
        'which styles the button in this markup' );
};

subtest 'not switched on: no page' => sub {
    for my $case ( [ 'the opt-in off', extension => 1, signin => 'off' ],
        [ 'no opt-in at all', extension => 1 ],
        [ 'the extension not enabled', signin => 'on' ] )
    {
        my ( $why, %o ) = @$case;
        my $out = run_processor( site( layout => 1, %o ), '/odoo-signin' );
        is( status_of($out), 404, "$why: /odoo-signin answers 404" );
        unlike( $out, qr/data-ls-odoo-signin/, '...and carries no sign-in button' );
    }
};

subtest 'a layout\'s own component of the name wins' => sub {
    my $d = site( layout => 1, extension => 1, signin => 'on' );
    make_path("$d/lazysite/layouts/probe/components");
    spit( "$d/lazysite/layouts/probe/components/odoo-signin.tt", '<div data-ls-odoo-signin>LAYOUT-OWN-SIGNIN</div>' );
    like( run_processor( $d, '/odoo-signin' ), qr/LAYOUT-OWN-SIGNIN/, 'the layout restyles the sign-in' );
};

subtest 'SM1299 (ruling 38): /login offers the Odoo sign-in on an opted-in site, carrying next' => sub {
    my $d   = site( layout => 1, extension => 1, signin => 'on' );
    my $out = run_processor( $d, '/login', QUERY_STRING => 'next=/wholesale' );
    is( status_of($out), 200, '/login answers' );
    like( $out, qr{<p class="login-odoo" data-ls-auth-in><a href="/odoo-signin\?next=%2Fwholesale">Sign in with Odoo</a></p>},
        'with a link to /odoo-signin that carries next' );
    like( $out, qr{action="/cgi-bin/lazysite-auth\.pl\?action=login"}, 'and the local form stays' );
    my ($line) = $out =~ m{(<p class="login-odoo"[^\n]*)};
    unlike( $line // '', qr/\bstyle\s*=/i, 'the link carries no inline style' );
    like( run_processor( $d, '/login' ), qr{<a href="/odoo-signin">Sign in with Odoo</a>}, 'with no next, a bare link' );
    my $odd = run_processor( $d, '/login', QUERY_STRING => 'next=/a%20b%26c%3D1' );
    like( $odd, qr{<a href="/odoo-signin\?next=%2Fa%20b%26[^"&<>]*">}, 'a next with query characters is carried encoded, inside the href' );
    for my $case ( [ 'the opt-in off', extension => 1, signin => 'off' ], [ 'the extension not enabled', signin => 'on' ] ) {
        my ( $why, %o ) = @$case;
        unlike( run_processor( site( layout => 1, %o ), '/login' ), qr/Sign in with Odoo/, "$why: no link" );
    }
};

subtest 'SM1299 (ruling 39): /odoo-signin is reachable during maintenance, as /login is' => sub {
    require Lazysite::Maintenance;
    # SM1369 X4: the sign-in pages the enabled identity providers declare are passed in
    ok( Lazysite::Maintenance::exempt( '/odoo-signin', {}, undef, ['/odoo-signin'] ), 'the decision exempts a provider\'s sign-in page' );
    ok( Lazysite::Maintenance::exempt( '/odoo-signin?next=/x', {}, undef, ['/odoo-signin'] ), '...with its query' );
    ok( !Lazysite::Maintenance::exempt( '/odoo-signin', {} ), '...and no page no provider declares' );
    my $d = site( layout => 1, extension => 1, signin => 'on' );
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "maintenance: on\n";
    close $cf;
    spit( "$d/elsewhere.md", "---\ntitle: E\n---\nELSEWHERE\n" );
    my $away = run_processor( $d, '/elsewhere' );
    like( $away, qr/Status: 302/, 'a page is sent to the maintenance page' );
    my $out = run_processor( $d, '/odoo-signin' );
    is( status_of($out), 200, '/odoo-signin is served' );
    like( $out, qr/data-ls-odoo-signin/, '...with its button' );
};

subtest 'a site\'s own copy wins, and deleting it restores the default' => sub {
    my $d = site( layout => 1, extension => 1, signin => 'on' );
    spit( "$d/odoo-signin.md", "---\ntitle: Mine\nauth: none\n---\n\nOWN-SIGNIN-PAGE\n" );
    like( run_processor( $d, '/odoo-signin' ), qr/OWN-SIGNIN-PAGE/, 'the site\'s own page' );
    unlink "$d/odoo-signin.md", "$d/odoo-signin.html";
    my $back = run_processor( $d, '/odoo-signin' );
    unlike( $back, qr/OWN-SIGNIN-PAGE/, 'deleted: gone' );
    like( $back, qr/data-ls-odoo-signin/, '...and the engine\'s page is back' );
};

done_testing;
