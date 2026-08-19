#!/usr/bin/perl
# SM352: the site side ships an ENFORCING Content-Security-Policy.
#
# WHY HASHES AND NOT 'unsafe-inline'. The engine stopped inlining its own script
# and style in steps 1-4, but it is not the only thing on the page. Measured
# against the shipped catalogue when this was written: 22 of 23 layouts inline a
# <script>, 8 distinct bodies between them, one appearing 42 times. A policy of
# `script-src 'self'` would have taken down every site running a shipped layout,
# and `script-src 'self' 'unsafe-inline'` would permit injected script exactly as
# readily as authored script - which is the single thing a CSP exists to stop.
#
# So the engine hashes what is actually in the response. That covers the
# catalogue, the manager's own head script and anything a future layout adds,
# without the engine knowing what any of them are and without the catalogue
# having to change first.
#
# DRIVEN THROUGH THE PROCESSOR, not by calling the header function. The question
# is what a visitor receives, and output_page is the choke point every path
# reaches - fresh render, cache hit and TTL alike - so a policy that is correct
# in the function and absent from the response would pass a unit test and fail
# every browser.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use Digest::SHA  qw(sha256);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# A layout that inlines a script, which is what 22 of 23 shipped layouts do.
my $SCRIPT = q{(function(){var b=document.querySelector('.nav-toggle');if(b){b.click();}})();};
make_path("$docroot/lazysite/layouts/csp");
open my $lt, '>', "$docroot/lazysite/layouts/csp/layout.tt" or die $!;
print {$lt} '<!DOCTYPE html><html><head><title>[% page_title %]</title>'
    . '<script>' . $SCRIPT . '</script>'
    . '<script src="/assets/lazysite-chrome.js"></script>'
    . '</head><body>[% content %]</body></html>';
close $lt;

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: CSP\nlayout: csp\n";
close $cf;

open my $md, '>', "$docroot/index.md" or die $!;
print {$md} "---\ntitle: Home\n---\n\nHello.\n";
close $md;

unlink "$docroot/index.html";
my $out = run_processor( $docroot, '/' );

my ($csp) = $out =~ /^Content-Security-Policy(?:-Report-Only)?:\s*(.+?)\s*$/mi;

subtest 'the header is present, and report-only by default' => sub {
    ok( $csp, 'a CSP is emitted on an HTML response' )
        or do { diag($out); return };

    # SM380 CHANGED THE DEFAULT, and this subtest changes with it. Step 5
    # shipped enforcing with no way to turn it down, and a hash covers a
    # <script> BLOCK and not an inline event-handler ATTRIBUTE - so an
    # enforcing default silently stops the manager's own onclick= controls
    # firing, in a browser, where no test here can see it.
    like( $out, qr/^Content-Security-Policy-Report-Only:/mi,
        'report-only until a site opts in to enforce' )
        or diag( 'An enforcing default is a policy applied to sites nobody has '
            . 'walked. Report-only reports without breaking anything, which is '
            . 'what a rollout window is for.' );
};

subtest 'script-src carries the hash of what the page actually inlined' => sub {
    plan skip_all => 'no CSP' unless $csp;
    # The POLICY is identical in either mode - only the header name differs, so
    # a site that flips to enforce gets exactly what it was already reporting.
    my $want = "'sha256-" . encode_base64( sha256($SCRIPT), '' ) . "'";
    like( $csp, qr/\Q$want\E/,
        'the layout\'s inline script is hashed into script-src' )
        or diag( "wanted $want\ngot: $csp\n"
            . 'Without it the browser blocks the script and the page renders '
            . 'without its navigation - silently, with nothing in the response '
            . 'to say why.' );

    unlike( $csp, qr/script-src[^;]*'unsafe-inline'/,
        'and script-src does not fall back to unsafe-inline' )
        or diag( 'unsafe-inline permits injected script as readily as authored '
            . 'script, which is the one thing this header is for.' );
};

subtest 'the directives that stop an injection doing damage' => sub {
    plan skip_all => 'no CSP' unless $csp;
    like( $csp, qr/\Qobject-src 'none'\E/, 'object-src none' );
    like( $csp, qr/\Qbase-uri 'self'\E/, 'base-uri self - a rewritten <base> redirects every relative URL' );
    like( $csp, qr/\Qform-action 'self'\E/, 'form-action self - an injected form cannot post credentials away' );
    like( $csp, qr/\Qframe-ancestors 'self'\E/, 'frame-ancestors self' );
};

subtest 'a static asset gets no policy, because it governs no script' => sub {
    # SM223: the engine only serves statics when the site HAS an ACL store -
    # otherwise the front end answers them directly and never consults the
    # engine at all. So the fixture needs one, which is also the only condition
    # under which this question is asked in the field.
    make_path("$docroot/lazysite/auth");
    open my $acl, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$acl} "{}\n";
    close $acl;

    make_path("$docroot/lazysite-assets/probe");
    open my $css, '>', "$docroot/lazysite-assets/probe/probe.css" or die $!;
    print {$css} "body{color:red}\n";
    close $css;
    my $sout = run_processor( $docroot, '/lazysite-assets/probe/probe.css' );
    # The fixture is only meaningful if this REALLY served the stylesheet. A
    # 404 is an HTML response and would carry a CSP correctly, so asserting
    # the absence without this would pass on the wrong response entirely -
    # which is exactly what the first version of this subtest did.
    like( $sout, qr{^Content-type: text/css}mi, 'the stylesheet was served' )
        or do { diag($sout); return };
    like( $sout, qr/^X-Content-Type-Options: nosniff/mi,
        'the static path still carries the security header set' );
    unlike( $sout, qr/^Content-Security-Policy:/mi,
        'and no CSP, which nothing would read on a stylesheet' );
};

done_testing();
