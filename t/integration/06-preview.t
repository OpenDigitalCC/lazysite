use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);
use Digest::SHA qw(hmac_sha256_hex);

# SM071 Phase 1: theme/layout preview. A signed preview cookie overrides
# the active layout/theme for the requesting session only, and the
# request must be uncacheable (no-store, no cache file written).

my $docroot = tempdir( CLEANUP => 1 );

# Layout 'base' with two themes: 'live' (active) and 'candidate'.
make_path("$docroot/lazysite/layouts/base/themes/live");
make_path("$docroot/lazysite/layouts/base/themes/candidate");
make_path("$docroot/lazysite/auth");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\nsite_url: http://localhost\nlayout: base\ntheme: live\n";
close $cf;

# layout.tt emits a marker of the resolved layout + theme name.
open my $lt, '>', "$docroot/lazysite/layouts/base/layout.tt" or die $!;
print $lt '<!DOCTYPE html><html><body>'
        . 'MARK:[% layout_name %]/[% theme_name %]:KRAM'
        . '[% content %]</body></html>';
close $lt;

for my $t (qw(live candidate)) {
    open my $tj, '>', "$docroot/lazysite/layouts/base/themes/$t/theme.json" or die $!;
    print $tj qq({"name":"$t","layouts":["base"]});
    close $tj;
}

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nHome body.\n";
close $idx;

open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nnf\n";
close $nf;

# Known auth secret so the test can mint a valid preview cookie with the
# same HMAC primitive the manager UI / control API will use.
my $secret = 'testsecret0123456789abcdef0123456789abcdef0123456789abcdef012345';
open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;

sub preview_cookie {
    my ( $exp, $layout, $theme, $user ) = @_;
    my $payload = "v1:$exp:$layout:$theme:$user";
    my $sig     = hmac_sha256_hex( $payload, $secret );
    return "lzs_preview=$payload:$sig";
}

# --- No cookie: active theme renders, page is cacheable. ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    my $out = run_processor( $docroot, '/index' );
    like( $out, qr{MARK:base/live:KRAM}, 'no cookie: active theme renders' );
    unlike( $out, qr{Cache-Control:\s*no-store}i, 'no cookie: not no-store' );
    ok( -f "$docroot/index.html", 'no cookie: cache file written' );
}

# --- Valid preview cookie: candidate theme overrides, uncacheable. ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    my $cookie = preview_cookie( time() + 3600, 'base', 'candidate', 'tester' );
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => $cookie );
    like( $out, qr{MARK:base/candidate:KRAM},
        'preview: candidate theme overrides the active theme' );
    like( $out, qr{Cache-Control:\s*no-store}i, 'preview: no-store header' );
    ok( !-f "$docroot/index.html", 'preview: no cache file written' );
}

# --- Layout-only preview (empty theme): overrides, still uncacheable. ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    my $cookie = preview_cookie( time() + 3600, 'base', '', 'tester' );
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => $cookie );
    like( $out, qr{MARK:base/:KRAM}, 'preview: empty theme renders no theme styling' );
    ok( !-f "$docroot/index.html", 'preview (no theme): no cache file written' );
}

# --- Tampered signature: override ignored, active theme renders. ---
{
    my $good = preview_cookie( time() + 3600, 'base', 'candidate', 'tester' );
    ( my $bad = $good ) =~ s/[a-f0-9]{64}$/'0' x 64/e;
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => $bad );
    like( $out, qr{MARK:base/live:KRAM},
        'tampered signature: preview ignored, active theme renders' );
}

# --- Expired cookie: override ignored. ---
{
    my $cookie = preview_cookie( time() - 10, 'base', 'candidate', 'tester' );
    my $out = run_processor( $docroot, '/index', HTTP_COOKIE => $cookie );
    like( $out, qr{MARK:base/live:KRAM},
        'expired cookie: preview ignored, active theme renders' );
}

# --- Malformed cookie (no signature): override ignored. ---
{
    my $out = run_processor( $docroot, '/index',
        HTTP_COOKIE => 'lzs_preview=v1:9999999999:base:candidate:tester' );
    like( $out, qr{MARK:base/live:KRAM},
        'malformed cookie (no sig): preview ignored' );
}

done_testing();
