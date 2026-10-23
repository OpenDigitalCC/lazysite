#!/usr/bin/perl
# SM1288: THE SHIPPED SIGN-IN AND SEARCH PAGES CARRY NO <style> BLOCK.
#
# Ruling 12 (2026-10-22): after SM1251 took the inline <style> out of the
# starter /contact.md, the other shipped pages that carried one - the starter
# /forgot.md and /search-results.md, and the engine's own login, forgot and
# claim pages under lazysite/templates/system/ - move their rules to the
# fallback chrome too. A page's <style> comes after the theme's stylesheet, so
# on a themed site those pages alone wore the engine's blue buttons and grid
# whatever the theme said.
#
# Checked the way t/unit/processor/148 checks the chrome, for each page:
#   - the shipped source has no <style>;
#   - rendered with no layout, the page has no <style> of its own, its body
#     carries the fallback class, and the chrome stylesheet is linked - so the
#     moved rules still reach it;
#   - rendered under a layout and an active theme, the page has no <style> and
#     no fallback class, so none of the moved rules reach it.
# And the moved rules are in the chrome, under the fallback class.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_minimal_site setup_test_site run_processor site_tempdir);

my $ROOT = repo_root();
sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $f, '>:raw', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}

# The page, where the starter ships it, where a site holds it, and the URL.
my @PAGES = (
    [ 'starter/forgot.md',                          'forgot.md',                          '/forgot' ],
    [ 'starter/search-results.md',                  'search-results.md',                  '/search-results' ],
    [ 'starter/lazysite/templates/system/login.md',  'lazysite/templates/system/login.md',  '/login' ],
    [ 'starter/lazysite/templates/system/forgot.md', 'lazysite/templates/system/forgot.md', '/forgot' ],
    [ 'starter/lazysite/templates/system/claim.md',  'lazysite/templates/system/claim.md',  '/claim' ],
);

for my $p (@PAGES) {
    unlike( slurp("$ROOT/$p->[0]"), qr/<style/i, "$p->[0] ships with no <style> block" );
}

# Each moved page's rules are in the chrome, under the fallback.
{
    my $css = slurp("$ROOT/starter/assets/lazysite-chrome.css");
    $css =~ s{/\*.*?\*/}{}gs;
    my %have;
    while ( $css =~ /([^{}]+)\{[^{}]*\}/g ) {
        $have{ s/^\s+|\s+$//gr } = 1 for split /,/, $1;
    }
    for my $want ( '.lazysite-fallback .reset-form', '.lazysite-fallback .reset-form button',
        '.lazysite-fallback .claim-form', '.lazysite-fallback .login-form',
        '.lazysite-fallback .login-context', '.lazysite-fallback .auth-error',
        '.lazysite-fallback .login-context-url', '.lazysite-fallback .search-result',
        '.lazysite-fallback .search-tag', '.lazysite-fallback mark' )
    {
        ok( $have{$want}, "the fallback chrome carries $want" );
    }
}

# A theme the test layout can use, active for the site.
sub with_theme {
    my ($d) = @_;
    spit( "$d/lazysite/layouts/test/themes/plain/theme.json",
        qq({"name":"plain","layouts":["test"],"config":{"colours":{"text":"#111"}}}\n) );
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "theme: plain\n";
    close $cf;
}

for my $p (@PAGES) {
    my ( $src, $at, $uri ) = @$p;
    for my $case ( [ 'no layout', \&setup_minimal_site, 1 ], [ 'a layout and theme', \&setup_test_site, 0 ] ) {
        my ( $what, $setup, $fallback ) = @$case;
        my $d = site_tempdir();
        $setup->($d);
        with_theme($d) unless $fallback;
        spit( "$d/$at", slurp("$ROOT/$src") );
        my $out = run_processor( $d, $uri );
        my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
        $body //= '';

        like( $head, qr/^Status: 200/m, "$src, $what: renders" ) or diag $head;
        unlike( $body, qr/<style/i, "$src, $what: the page carries no <style> block" );
        my ($tag) = $body =~ /(<body\b[^>]*>)/i;
        $tag //= '';
        if ($fallback) {
            like( $tag, qr/\bclass="lazysite-fallback"/,
                "$src, $what: the fallback's body class is there, so the moved rules apply" );
            like( $body, qr{<link rel="stylesheet" href="/assets/lazysite-chrome\.css},
                "$src, $what: and the chrome that holds them is linked" );
        }
        else {
            unlike( $tag, qr/lazysite-fallback/,
                "$src, $what: no fallback class, so none of the moved rules reach the themed page" );
        }
    }
}

done_testing();
