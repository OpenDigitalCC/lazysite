#!/usr/bin/perl
# SM110: domain aliases - an additional host serving the same site with its
# own site_name / theme / layout / nav. Alias resolution is Host-header
# driven (sanitised), overrides come from a strict whitelist, and (phase 2)
# each alias host caches its renders in its own slot under
# lazysite/cache/hosts/<host>/ - same caching rules as the primary, never
# shared across hosts. Invalidation surfaces must clear host copies too.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor);

# --- Fixture: a site with two declared alias hosts -------------------------
# Layout 'aliastest' renders the vars this feature varies (site_name,
# theme_name, nav, alias_host) as grep-able markers. Two themes so the
# per-host theme override is observable.
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/cache");

# SM434: a KNOWN running version, so the marker assertion below can check the
# value rather than merely the key. Without this the field is the empty string
# and /"version":"/ matches it happily - a green test proving nothing.
{
    open my $is, '>', "$docroot/lazysite/.install-state.json" or die $!;
    print {$is} '{"version":"9.9.9-test"}';
    close $is;
}
make_path("$docroot/lazysite/layouts/aliastest/themes/base");
make_path("$docroot/lazysite/layouts/aliastest/themes/dark");

open my $lt, '>', "$docroot/lazysite/layouts/aliastest/layout.tt" or die $!;
print {$lt} '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
    . '<body>'
    . '<p>SITE=[% site_name %]</p>'
    . '<p>THEME=[% theme_name %]</p>'
    . '<p>ALIAS=[% alias_host %]</p>'
    . '<p>DOMAIN=[% domain %]</p>'
    . '[% FOREACH item IN nav %]<a href="[% item.url %]">NAV:[% item.label %]</a>[% END %]'
    . '[% content %]</body></html>';
close $lt;

for my $theme (qw(base dark)) {
    open my $tj, '>', "$docroot/lazysite/layouts/aliastest/themes/$theme/theme.json"
        or die $!;
    print {$tj} qq({"name":"$theme","layouts":["aliastest"],"config":{}});
    close $tj;
}

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} <<'CONF';
site_name: Primary Site
site_url: http://primary.example
layout: aliastest
theme: base
alias_hosts: brand2.example, other.example
alias.brand2.example.site_name: Brand Two
alias.brand2.example.theme: dark
alias.brand2.example.nav_file: lazysite/brand2-nav.conf
alias.brand2.example.manager: enabled
alias.other.example.site_name: Other Site
CONF
close $cf;

open my $nv, '>', "$docroot/lazysite/nav.conf" or die $!;
print {$nv} "PrimaryHome | /\n";
close $nv;

open my $bn, '>', "$docroot/lazysite/brand2-nav.conf" or die $!;
print {$bn} "BrandTwoHome | /b2\n";
close $bn;

open my $idx, '>', "$docroot/index.md" or die $!;
print {$idx} "---\ntitle: Home\n---\nHome page.\n";
close $idx;

open my $nf, '>', "$docroot/404.md" or die $!;
print {$nf} "---\ntitle: Not Found\n---\nNot found.\n";
close $nf;

my $HOSTS = "$docroot/lazysite/cache/hosts";
sub slot { my ( $host, $page ) = @_; return "$HOSTS/$host/$page.html" }

sub read_all {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# --- Primary host: base conf, alias_host empty -----------------------------
{
    my $out = run_processor( $docroot, '/index',
        HTTP_HOST => 'primary.example' );
    like( $out, qr/Status: 200 OK/,    'primary host renders 200' );
    like( $out, qr/SITE=Primary Site/, 'primary gets base site_name' );
    like( $out, qr/THEME=base/,        'primary gets base theme' );
    like( $out, qr/NAV:PrimaryHome/,   'primary gets base nav' );
    like( $out, qr/<p>ALIAS=<\/p>/,    'alias_host TT var empty on primary' );
    like( $out, qr/DOMAIN=primary\.example/, 'domain TT var carries the host on the primary' );
    unlink "$docroot/index.html";    # keep later cache assertions independent
}

# --- SM156: public instance marker (served before auth, CORS-open) ----------
# The domain-check probe fetches this over a candidate host to confirm it lands
# on THIS install. It answers on ANY host (even unregistered) and is the same
# instance id everywhere for one docroot.
{
    my $m1 = run_processor( $docroot, '/.well-known/lazysite-instance.json',
        HTTP_HOST => 'primary.example' );
    like( $m1, qr/Status: 200 OK/,                'marker returns 200' );
    like( $m1, qr/Access-Control-Allow-Origin: \*/, 'marker is CORS-open for the browser probe' );
    like( $m1, qr/"host":"primary\.example"/,     'marker echoes the served host' );
    my ($id1) = $m1 =~ /"instance":"([0-9a-f]+)"/;
    ok( $id1, 'marker carries an instance id' );

    my $m2 = run_processor( $docroot, '/.well-known/lazysite-instance.json',
        HTTP_HOST => 'brand2.example' );
    my ($id2) = $m2 =~ /"instance":"([0-9a-f]+)"/;
    is( $id2, $id1, 'the same install returns the same instance id on every host' );
    like( $m2, qr/"host":"brand2\.example"/, 'marker echoes the alias host too' );

    # SM434: WHAT IS RUNNING, from the thing that is running.
    #
    # Nothing served reported this, and two agents in a row reached for the
    # <meta name="generator"> version instead - which answers a different
    # question and answers it correctly: that meta is baked in AT RENDER TIME
    # and cached with the page, so it reports the build that PRODUCED the
    # artefact, not the one serving it. A page rendered under an older build
    # and still cached is not stale; it is describing itself accurately.
    #
    # This endpoint is never cached, so it can answer honestly. The field goes
    # here rather than into the page chrome for exactly that reason.
    like( $m1, qr/"version":"9\.9\.9-test"/,
        'the marker reports the RUNNING version, read from the install state' )
        or diag( 'Without this the only version anywhere near a served page is '
            . "the generator meta, which answers 'what rendered this' - and "
            . 'was misread as the deployment twice in one week.' );
}

# --- Alias host: whitelisted overrides applied ------------------------------
{
    my $out = run_processor( $docroot, '/index',
        HTTP_HOST => 'brand2.example' );
    like( $out, qr/Status: 200 OK/,   'alias host renders 200' );
    like( $out, qr/SITE=Brand Two/,   'alias site_name override applied' );
    like( $out, qr/THEME=dark/,       'alias theme override applied' );
    like( $out, qr/NAV:BrandTwoHome/, 'alias nav_file override applied' );
    unlike( $out, qr/NAV:PrimaryHome/, 'primary nav not shown on alias' );
    like( $out, qr/ALIAS=brand2\.example/, 'alias_host TT var carries the host' );
    like( $out, qr/DOMAIN=brand2\.example/, 'domain TT var carries the alias host' );
}

# --- Host matching is sanitised: port stripped, case folded ----------------
{
    my $out = run_processor( $docroot, '/index',
        HTTP_HOST => 'Brand2.Example:8443' );
    like( $out, qr/SITE=Brand Two/,
        'Host with port + mixed case still matches the alias' );
}

# --- Per-host isolation: each alias only gets its own overrides ------------
{
    my $out = run_processor( $docroot, '/index',
        HTTP_HOST => 'other.example' );
    like( $out, qr/SITE=Other Site/, 'second alias gets its own site_name' );
    like( $out, qr/THEME=base/,      'second alias keeps base theme (no override)' );
    like( $out, qr/NAV:PrimaryHome/, 'second alias keeps base nav (no override)' );
}

# --- Unlisted host: base conf exactly as the primary ------------------------
{
    my $out = run_processor( $docroot, '/index',
        HTTP_HOST => 'stranger.example' );
    like( $out, qr/SITE=Primary Site/, 'undeclared host gets base conf' );
    like( $out, qr/<p>ALIAS=<\/p>/,    'undeclared host has empty alias_host' );
    unlink "$docroot/index.html";
}

# --- Malformed Host header: falls back to base conf -------------------------
{
    for my $bad ( 'brand2.example/<script>', 'brand2..example', '-brand2.example' ) {
        my $out = run_processor( $docroot, '/index', HTTP_HOST => $bad );
        like( $out, qr/SITE=Primary Site/,
            "malformed Host '$bad' falls back to base conf" );
    }
    unlink "$docroot/index.html";
}

# --- Security: non-whitelisted alias override is ignored --------------------
# alias.brand2.example.manager: enabled must NOT enable the manager. Were it
# honoured, /manager/ (unauthenticated) would 302 to /login; ignored, the
# manager stays disabled and the path is 403.
{
    my $out = run_processor( $docroot, '/manager/',
        HTTP_HOST => 'brand2.example' );
    like( $out, qr/Status: 403/,
        'alias.<host>.manager override is ignored (manager stays disabled)' );
    unlike( $out, qr/Status: 302/, 'no login redirect - key never took effect' );
}

# --- Phase 2: alias warms its OWN cache slot; primary sibling untouched -----
{
    open my $ab, '>', "$docroot/about.md" or die $!;
    print {$ab} "---\ntitle: About\n---\nAbout page.\n";
    close $ab;

    run_processor( $docroot, '/about', HTTP_HOST => 'brand2.example' );
    ok( !-f "$docroot/about.html",
        'alias-host render writes no .html sibling' );
    ok( -f slot( 'brand2.example', 'about' ),
        'alias-host render cached in its own host slot' );
    like( read_all( slot( 'brand2.example', 'about' ) ), qr/SITE=Brand Two/,
        'host slot holds the alias-themed render' );

    run_processor( $docroot, '/about', HTTP_HOST => 'primary.example' );
    ok( -f "$docroot/about.html", 'primary host still writes the sibling cache' );
    like( read_all("$docroot/about.html"), qr/SITE=Primary Site/,
        'sibling cache holds the primary render' );
}

# --- Phase 2: second alias request is served FROM the host slot -------------
# The SM140 first-party access line for the repeat request carries the
# cache-hit flag (c=1), proving the slot was read, not re-rendered.
{
    my ($today) = do {
        my @t = gmtime;
        sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3];
    };
    my $out = run_processor( $docroot, '/about',
        HTTP_HOST       => 'brand2.example',
        REMOTE_ADDR     => '198.51.100.9',
        HTTP_USER_AGENT => 'Mozilla/5.0 (X11; Linux) TestBrowser' );
    like( $out, qr/SITE=Brand Two/, 'repeat alias request serves alias content' );

    my $log = "$docroot/lazysite/logs/access-$today.jsonl";
    open my $lf, '<', $log or die "no access log: $!";
    my @lines = <$lf>;
    close $lf;
    my $last = decode_json( $lines[-1] );
    is( $last->{p}, '/about', 'access line is the repeat alias request' );
    is( $last->{c}, 1,        'repeat alias request flagged as a cache hit' );
}

# --- Phase 2: two alias hosts get distinct slots -----------------------------
{
    run_processor( $docroot, '/about', HTTP_HOST => 'other.example' );
    ok( -f slot( 'other.example', 'about' ), 'second alias has its own slot' );
    like( read_all( slot( 'other.example', 'about' ) ), qr/SITE=Other Site/,
        'second alias slot holds its own render' );
    unlike( read_all( slot( 'other.example', 'about' ) ), qr/SITE=Brand Two/,
        'slots do not bleed across alias hosts' );
}

# --- Slot separation: a warm primary cache is never served to an alias ------
# (Phase 1 proved this with NOCACHE; phase 2 proves slot separation.)
{
    unlink "$docroot/index.html";
    unlink slot( 'brand2.example', 'index' );
    my $primary = run_processor( $docroot, '/index',
        HTTP_HOST => 'primary.example' );
    ok( -f "$docroot/index.html", 'cache warmed by the primary host' );
    like( $primary, qr/SITE=Primary Site/, 'warm render is the primary one' );

    my $alias = run_processor( $docroot, '/index',
        HTTP_HOST => 'brand2.example' );
    like( $alias, qr/SITE=Brand Two/,
        'alias request renders its own view - never the primary cache' );
    like( $alias, qr/THEME=dark/, 'alias render carries the alias theme' );
    isnt( $alias, $primary, 'primary and alias responses differ' );

    like( read_all("$docroot/index.html"), qr/SITE=Primary Site/,
        'sibling cache still holds the primary render' );
    unlike( read_all("$docroot/index.html"), qr/SITE=Brand Two/,
        'alias render never overwrote the sibling' );
    like( read_all( slot( 'brand2.example', 'index' ) ), qr/SITE=Brand Two/,
        'alias render landed in its own slot' );
}

# --- Editing the .md invalidates BOTH the sibling and the host copies -------
# (mtime comparison is per-slot: a source newer than a cached render forces a
# re-render on the next request for that host.)
{
    open my $e, '>', "$docroot/index.md" or die $!;
    print {$e} "---\ntitle: Home\n---\nHome page v2.\n";
    close $e;
    my $t = time + 10;
    utime $t, $t, "$docroot/index.md";

    my $primary = run_processor( $docroot, '/index',
        HTTP_HOST => 'primary.example' );
    like( $primary, qr/Home page v2/, 'primary re-renders after the edit' );
    like( read_all("$docroot/index.html"), qr/Home page v2/,
        'sibling cache refreshed' );

    my $alias = run_processor( $docroot, '/index',
        HTTP_HOST => 'brand2.example' );
    like( $alias, qr/Home page v2/,   'alias re-renders after the edit' );
    like( $alias, qr/SITE=Brand Two/, 'alias re-render keeps its overrides' );
    like( read_all( slot( 'brand2.example', 'index' ) ), qr/Home page v2/,
        'host slot refreshed' );
}

# --- Invalidation surfaces clear host copies (manager actions) --------------
{
    require Lazysite::Manager::Themes;
    no warnings 'once';    # context vars normally set by the API dispatcher
    local $ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';    # quiet action log lines in TAP
    $Lazysite::Manager::Themes::DOCROOT      = $docroot;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = "$docroot/lazysite";

    # Warm sibling + two host slots for /about.
    run_processor( $docroot, '/about', HTTP_HOST => 'primary.example' );
    run_processor( $docroot, '/about', HTTP_HOST => 'brand2.example' );
    run_processor( $docroot, '/about', HTTP_HOST => 'other.example' );
    ok( -f "$docroot/about.html" && -f slot( 'brand2.example', 'about' ),
        'sibling and host slots warm before invalidation' );

    # Per-page invalidate removes the sibling AND every host copy.
    my $r = Lazysite::Manager::Themes::action_cache_invalidate('/about');
    ok( $r->{ok},                  'cache-invalidate /about ok' );
    ok( !-f "$docroot/about.html", 'sibling removed by per-page invalidate' );
    ok( !-f slot( 'brand2.example', 'about' ),
        'brand2 host copy removed by per-page invalidate' );
    ok( !-f slot( 'other.example', 'about' ),
        'other host copy removed by per-page invalidate' );

    # Clear-all removes the whole hosts tree.
    run_processor( $docroot, '/about', HTTP_HOST => 'primary.example' );
    run_processor( $docroot, '/about', HTTP_HOST => 'brand2.example' );
    ok( -f slot( 'brand2.example', 'about' ), 'host slot re-warmed' );
    my $ca = Lazysite::Manager::Themes::action_cache_invalidate('*');
    ok( $ca->{ok},                 'clear-all ok' );
    ok( !-f "$docroot/about.html", 'clear-all removed the sibling' );
    ok( !-e $HOSTS,                'clear-all removed the per-host cache tree' );
}

done_testing();
