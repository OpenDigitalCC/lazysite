#!/usr/bin/perl
# SM151 phase 1: first-class multi-site content roots. One docroot serves
# several domains, each rooted at its own content subtree via
# `alias.<host>.content_root`. This suite is the security gate: it proves the
# per-domain content root is a HARD public boundary. The spec's invariants:
#   S1  served paths are confined under the domain's content root (no escape
#       by traversal or by a symlink leaving the subtree);
#   S2  a content root can never be, contain, or alias into lazysite/ (auth,
#       secret, ACLs are never web-reachable through any domain root);
#   S6  a bad/missing content root degrades that host to the docroot root with
#       a WARN - it never 500s, never leaks a sibling, never takes the
#       instance down.
# Plus the functional half: each domain serves its own subtree as '/', and one
# domain can never see another's pages.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor);

# --- Fixture --------------------------------------------------------------
# A docroot with two real client subtrees, an agency root page, a secret
# under lazysite/auth, and four deliberately-broken domains (symlink out of
# the docroot, traversal, a root inside lazysite/, and a missing root).
my $docroot = tempdir( CLEANUP => 1 );
my $outside = tempdir( CLEANUP => 1 );    # a tree OUTSIDE the docroot

make_path("$docroot/lazysite/cache");
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/templates/registries");
make_path("$docroot/sites/clienta");
make_path("$docroot/sites/clientb");

# A minimal per-domain sitemap registry template (P3). Emits each registered
# page's absolute URL from the per-host site_url + content-root-relative url.
_write( "$docroot/lazysite/templates/registries/sitemap.xml.tt", <<'TT' );
<?xml version="1.0" encoding="UTF-8"?>
<urlset>[% FOREACH p IN pages %]
<url><loc>[% site_url %][% p.url %]</loc></url>[% END %]
</urlset>
TT

# Agency root (what a domain with no/invalid content_root falls back to).
_write( "$docroot/index.md", "---\ntitle: Agency\n---\nAGENCY_ROOT_HOME\n" );
_write( "$docroot/404.md",   "---\ntitle: NF\n---\nAGENCY_404\n" );
# A secret that must NEVER be reachable through any domain root (S2).
_write( "$docroot/lazysite/auth/secret", "TOP_SECRET_MATERIAL\n" );
# A static file at the bare docroot root - must NOT leak onto an alias host (P6).
_write( "$docroot/agency-only.txt", "AGENCY_ONLY_ASSET\n" );

# Client A subtree. Pages register for the sitemap (P3).
_write( "$docroot/sites/clienta/index.md", "---\ntitle: A\nregister:\n  - sitemap.xml\n---\nCLIENT_A_HOME\n" );
_write( "$docroot/sites/clienta/about.md", "---\ntitle: A2\nregister:\n  - sitemap.xml\n---\nCLIENT_A_ABOUT\n" );
# A static asset in client A's subtree (P6: should serve at the domain URL).
_write( "$docroot/sites/clienta/logo.svg", "<svg>CLIENT_A_LOGO</svg>\n" );
# Client B subtree (has a page that A does not).
_write( "$docroot/sites/clientb/index.md",  "---\ntitle: B\nregister:\n  - sitemap.xml\n---\nCLIENT_B_HOME\n" );
_write( "$docroot/sites/clientb/only-b.md", "---\ntitle: B2\nregister:\n  - sitemap.xml\n---\nCLIENT_B_ONLY\n" );

# Per-domain search endpoints (P4): each scans /**/*.md, which must resolve
# against the requesting domain's own content root.
my $find_page =
      "---\ntitle: Find\napi: true\ncontent_type: text/plain\n"
    . "tt_page_var:\n  results: scan:/**/*.md sort=filename\n---\n"
    . "[% FOREACH p IN results %]URL:[% p.url %]\n[% END %]\n";
_write( "$docroot/sites/clienta/find.md", $find_page );
_write( "$docroot/sites/clientb/find.md", $find_page );

# Content OUTSIDE the docroot, reached by a symlink inside sites/ (S1/S2).
_write( "$outside/evil.md", "---\ntitle: E\n---\nOUTSIDE_CONTENT\n" );
symlink( $outside, "$docroot/sites/evil" )
    or plan skip_all => "symlink unsupported on this filesystem";
# A symlink INSIDE client A's tree that escapes back to the docroot root (S1).
symlink( $docroot, "$docroot/sites/clienta/escape" )
    or plan skip_all => "symlink unsupported on this filesystem";
# A SIBLING content dir whose name is a STRING-SUPERSET of client A's content
# root (sites/clienta vs sites/clienta-secret), plus an in-tree symlink into it.
# A bare index($real, $croot)==0 prefix check would treat clienta-secret as
# "inside clienta" and serve it; the boundary check ("$croot/") must not (S1).
make_path("$docroot/sites/clienta-secret");
_write( "$docroot/sites/clienta-secret/leak.md",
    "---\ntitle: L\n---\nSUPERSTRING_SIBLING_SECRET\n" );
symlink( "$docroot/sites/clienta-secret", "$docroot/sites/clienta/peek" )
    or plan skip_all => "symlink unsupported on this filesystem";

_write( "$docroot/lazysite/lazysite.conf", <<'CONF' );
site_name: Agency Home
site_url: https://agency.example
alias_hosts: clienta.example, clientb.example, badroot.example, introot.example, missroot.example, travroot.example
alias.clienta.example.content_root: sites/clienta
alias.clienta.example.site_name: Client A
alias.clienta.example.site_url: https://www.clienta.example
alias.clientb.example.content_root: sites/clientb
alias.clientb.example.site_name: Client B
alias.clientb.example.site_url: https://clientb.example
alias.badroot.example.content_root: sites/evil
alias.introot.example.content_root: lazysite/auth
alias.missroot.example.content_root: sites/does-not-exist
alias.travroot.example.content_root: ../../etc
CONF

sub _write {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# =========================================================================
# Functional: each domain serves its own subtree as '/'.
# =========================================================================
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clienta.example' );
    like( $out, qr/Status: 200 OK/, 'client A / renders 200' );
    like( $out, qr/CLIENT_A_HOME/,  'client A / serves its own subtree index' );
    unlike( $out, qr/AGENCY_ROOT_HOME/, 'client A / does NOT serve the agency root index' );
    unlike( $out, qr/CLIENT_B_HOME/,    'client A / does NOT serve client B' );
}
{
    my $out = run_processor( $docroot, '/about', HTTP_HOST => 'clienta.example' );
    like( $out, qr/CLIENT_A_ABOUT/, 'client A serves a deeper page in its subtree' );
}
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clientb.example' );
    like( $out, qr/CLIENT_B_HOME/, 'client B / serves its own subtree' );
    unlike( $out, qr/CLIENT_A_HOME/, 'client B / does not serve client A' );
}

# A page that exists only in B's tree is 404 on A's host (no cross-domain read).
{
    my $out = run_processor( $docroot, '/only-b', HTTP_HOST => 'clienta.example' );
    unlike( $out, qr/CLIENT_B_ONLY/,  'B-only page is not served on client A' );
    unlike( $out, qr/Status: 200 OK/, 'B-only page on A is not a 200' );
}

# Superset: an undeclared host (no content_root) is unchanged - docroot root.
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'agency.example' );
    like( $out, qr/AGENCY_ROOT_HOME/, 'undeclared host serves docroot root (unchanged behaviour)' );
}

# =========================================================================
# S1: no escape from the content root.
# =========================================================================
# Traversal in the request URI (sanitise_uri already strips it) - must not
# climb into a sibling subtree.
{
    my $out = run_processor( $docroot, '/../clientb/index', HTTP_HOST => 'clienta.example' );
    unlike( $out, qr/CLIENT_B_HOME/,  'traversal URI cannot reach a sibling subtree' );
    unlike( $out, qr/Status: 200 OK/, 'traversal URI is not a 200' );
}
# A symlink inside A's tree that points back to the docroot root: the realpath
# confinement must reject it (would otherwise serve the agency index).
{
    my $out = run_processor( $docroot, '/escape/index', HTTP_HOST => 'clienta.example' );
    unlike( $out, qr/AGENCY_ROOT_HOME/, 'in-tree symlink escaping the content root is denied' );
    unlike( $out, qr/Status: 200 OK/, 'symlink-escape request is not a 200' );
}
# The superstring-sibling case: a symlink into sites/clienta-secret (a sibling
# whose name is a prefix-superset of sites/clienta) must NOT be served to A -
# the boundary check rejects it where a bare-prefix check would have leaked it.
{
    my $out = run_processor( $docroot, '/peek/leak', HTTP_HOST => 'clienta.example' );
    unlike( $out, qr/SUPERSTRING_SIBLING_SECRET/,
        'a prefix-superset sibling is not served via an in-tree symlink' );
    unlike( $out, qr/Status: 200 OK/, 'superstring-sibling request is not a 200' );
}
# A content_root that is a symlink OUT of the docroot: rejected -> fall back to
# the docroot root; the outside tree is never served.
{
    my $out = run_processor( $docroot, '/evil', HTTP_HOST => 'badroot.example' );
    unlike( $out, qr/OUTSIDE_CONTENT/, 'content_root symlinked outside the docroot is not served' );
}
# A content_root with traversal is rejected before touching the filesystem.
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'travroot.example' );
    like( $out, qr/AGENCY_ROOT_HOME/, 'traversal content_root degrades to docroot root' );
}

# =========================================================================
# S2: the lazysite/ management tree is never reachable through a domain root.
# =========================================================================
{
    # content_root: lazysite/auth is rejected -> docroot-root fallback.
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'introot.example' );
    unlike( $out, qr/TOP_SECRET_MATERIAL/, 'content_root into lazysite/ never serves secrets' );
    like( $out, qr/AGENCY_ROOT_HOME/, 'content_root into lazysite/ degrades to docroot root' );
}
{
    # Even asking for the secret by name through that host must not serve it.
    my $out = run_processor( $docroot, '/secret', HTTP_HOST => 'introot.example' );
    unlike( $out, qr/TOP_SECRET_MATERIAL/, 'secret is not served by name through a lazysite-rooted host' );
}

# =========================================================================
# S6: bad/missing roots degrade safely and in isolation.
# =========================================================================
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'missroot.example' );
    unlike( $out, qr/Status: 5\d\d/, 'missing content_root does not 500' );
    like( $out, qr/AGENCY_ROOT_HOME/, 'missing content_root degrades to docroot root' );
}
# Fault isolation: after hitting every broken domain, a good domain still works.
{
    run_processor( $docroot, '/index', HTTP_HOST => 'badroot.example' );
    run_processor( $docroot, '/index', HTTP_HOST => 'introot.example' );
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clienta.example' );
    like( $out, qr/CLIENT_A_HOME/, 'a good domain still serves after broken siblings were hit' );
}

# =========================================================================
# P2: per-host canonical from the declared site_url (never the request Host).
# site_url is set to a host DIFFERENT from the request Host to prove the
# canonical is config-driven, not spoofable via Host.
# =========================================================================
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clienta.example' );
    like( $out, qr{<link rel="canonical" href="https://www\.clienta\.example/">},
        'client A / canonical uses its declared site_url, index collapsed to /' );
    unlike( $out, qr{canonical[^>]*clienta\.example/index},
        'canonical does not carry the /index suffix' );
}
{
    my $out = run_processor( $docroot, '/about', HTTP_HOST => 'clienta.example' );
    like( $out, qr{<link rel="canonical" href="https://www\.clienta\.example/about">},
        'client A deep page canonical is site_url + clean path' );
}
{
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'clientb.example' );
    like( $out, qr{<link rel="canonical" href="https://clientb\.example/">},
        'client B canonical uses its own declared site_url' );
    unlike( $out, qr{canonical[^>]*clienta}, 'client B canonical never carries client A host' );
}
{
    # Undeclared host falls back to the base site_url for its canonical.
    my $out = run_processor( $docroot, '/index', HTTP_HOST => 'agency.example' );
    like( $out, qr{<link rel="canonical" href="https://agency\.example/">},
        'undeclared host canonical uses the base site_url' );
}

# =========================================================================
# P3: per-domain registries. Each domain's sitemap is written INTO its own
# content root, lists only that subtree, and uses the domain's own site_url.
# The sitemaps are generated as a side effect of the render tests above.
# =========================================================================
{
    my $smA = "$docroot/sites/clienta/sitemap.xml";
    ok( -f $smA, 'client A sitemap is written into its own content root' );
    my $a = _slurp($smA);
    like( $a, qr{https://www\.clienta\.example/</loc>},
        'A sitemap uses A site_url with its index collapsed to /' );
    like( $a, qr{https://www\.clienta\.example/about},
        'A sitemap lists A about page' );
    unlike( $a, qr{clientb|CLIENT_B|/only-b},
        'A sitemap contains none of client B' );
    unlike( $a, qr{/sites/|/escape/},
        'A sitemap did not leak the docroot via the escape symlink' );
}
{
    my $smB = "$docroot/sites/clientb/sitemap.xml";
    ok( -f $smB, 'client B sitemap is written into its own content root' );
    my $b = _slurp($smB);
    like( $b, qr{https://clientb\.example/only-b},
        'B sitemap lists the B-only page with B site_url' );
    unlike( $b, qr{clienta|www\.clienta},
        'B sitemap contains none of client A' );
}

# =========================================================================
# P4: per-domain search is boxed to the requesting domain's content root -
# a search on one domain never returns another domain's pages, and result
# URLs are domain-relative.
# =========================================================================
{
    my $out = run_processor( $docroot, '/find', HTTP_HOST => 'clienta.example' );
    like( $out, qr{URL:/about\b}, 'client A search includes its own /about' );
    like( $out, qr{^URL:/$}m,     'client A search includes its own index (/)' );
    unlike( $out, qr{only-b|clientb|CLIENT_B},
        'client A search excludes every client B page' );
    unlike( $out, qr{URL:/sites/},
        'client A search URLs are domain-relative, not docroot-relative' );
}
{
    my $out = run_processor( $docroot, '/find', HTTP_HOST => 'clientb.example' );
    like( $out, qr{URL:/only-b\b}, 'client B search includes its B-only page' );
    unlike( $out, qr{URL:/about\b}, 'client B search excludes client A /about' );
}

# =========================================================================
# P5: the first-party access log records the requesting Host, so per-domain
# visitor stats are possible later (splitting is deferred; the field is not).
# =========================================================================
{
    run_processor( $docroot, '/index', HTTP_HOST => 'clienta.example' );
    my ($log) = glob("$docroot/lazysite/logs/access-*.jsonl");
    ok( $log && -f $log, 'first-party access log is written' );
    my $lines = _slurp( $log // '' );
    like( $lines, qr{"h":"clienta\.example"},
        'access log line records the requesting host' );
}

# =========================================================================
# P6: the processor serves static files (sitemap, feeds, assets) from the
# domain's content root - so each domain's own SEO artefacts and assets serve
# at its URL - confined to the content root.
# =========================================================================
{
    my $out = run_processor( $docroot, '/sitemap.xml', HTTP_HOST => 'clienta.example' );
    like( $out, qr{Status: 200 OK},                     'client A /sitemap.xml served' );
    like( $out, qr{Content-type: application/xml},      'sitemap served with an xml content-type' );
    like( $out, qr{https://www\.clienta\.example/about}, 'the served sitemap is client A\x27s own' );
    unlike( $out, qr{clientb|only-b},                    'served sitemap has none of client B' );
}
{
    my $out = run_processor( $docroot, '/logo.svg', HTTP_HOST => 'clienta.example' );
    like( $out, qr{Content-type: image/svg\+xml}, 'a subtree asset serves with its own content-type' );
    like( $out, qr{CLIENT_A_LOGO},                'the asset body is client A\x27s' );
}
{
    # A static file at the bare docroot root must NOT leak onto an alias host:
    # the alias is confined to its content root, where the file does not exist.
    my $out = run_processor( $docroot, '/agency-only.txt', HTTP_HOST => 'clienta.example' );
    unlike( $out, qr{AGENCY_ONLY_ASSET}, 'a docroot-root static does not leak onto an alias host' );
    unlike( $out, qr{Status: 200 OK},    'the docroot-root static is not served on the alias host' );
}
{
    # Client B has no logo.svg - an alias must not serve a sibling's asset.
    my $out = run_processor( $docroot, '/logo.svg', HTTP_HOST => 'clientb.example' );
    unlike( $out, qr{CLIENT_A_LOGO},  'client B does not serve client A\x27s asset' );
    unlike( $out, qr{Status: 200 OK}, 'client B has no such asset' );
}

done_testing();
