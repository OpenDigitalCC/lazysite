#!/usr/bin/perl
# SM649: a preview cookie does not bypass authentication, an ACL or a draft -
# and nothing in the suite would have noticed if that stopped being true.
#
# THE MECHANISM IS CORRECT AND IS NOT CHANGED BY THIS FILE. check_preview()
# returns only { layout, theme }, merged into %PREVIEW_CONTEXT, which overrides
# how a page is RENDERED. It moves no read boundary. The stop is structural:
# check_preview() is called below the auth gates, inside one sub.
#
# That is a true fact about today's source and nothing more. Before this file:
#
#   t/unit/manager/09-preview-grant.t   mint, verify, render, CSRF, bad
#                                       layout/theme, no-store - no auth or ACL
#   t/integration/06-preview.t          three assertions, none about auth
#
# So a refactor that hoisted preview context into an earlier resolution step
# would have turned a safe mechanism into a content-disclosure hole with the
# whole suite green. The property was true and undefended; this defends it.
#
# The cookie here is MINTED PROPERLY - real HMAC over the real payload against
# the site's own secret - because a test that fakes the cookie measures the
# signature check rather than the gate ordering, and would pass against a
# server that honoured previews before authenticating.
use strict;
use warnings;
use Test::More;
use File::Path   qw(make_path);
use File::Temp   qw(tempdir);
use JSON::PP     qw(encode_json);
use Digest::SHA  qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

my $SECRET = 'preview-secret-for-this-test-only';
open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
print {$sf} "$SECRET\n";
close $sf;

# Three pages, each gated a different way.
open my $a, '>', "$docroot/gated.md" or die $!;
print {$a} "---\ntitle: Gated\nauth: required\n---\nAUTHSECRET body.\n";
close $a;
open my $b, '>', "$docroot/acled.md" or die $!;
print {$b} "---\ntitle: Acled\n---\nACLSECRET body.\n";
close $b;
open my $d, '>', "$docroot/drafty.md" or die $!;
print {$d} "---\ntitle: Drafty\n---\nDRAFTSECRET body.\n";
close $d;
open my $c, '>', "$docroot/open.md" or die $!;
print {$c} "---\ntitle: Open\n---\nOPENBODY here.\n";
close $c;

# An ACL over one of them, readable only by a named account.
open my $af, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$af} encode_json( {
    'acled.md'  => { owner => 'sjm', read => ['sjm'] },
    'drafty.md' => { owner => 'sjm', draft => 1 },
} );
close $af;

# A REAL preview cookie: v1:<expiry>:<layout>:<theme>:<user>, HMAC-SHA256.
sub preview_cookie {
    my $payload = 'v1:' . ( time() + 3600 ) . ':default:default:sjm';
    return "$payload:" . hmac_sha256_hex( $payload, $SECRET );
}

sub get {
    my ( $uri, %env ) = @_;
    return run_processor( $docroot, $uri, %env );
}
sub get_previewing {
    my ($uri) = @_;
    return get( $uri, HTTP_COOKIE => 'lzs_preview=' . preview_cookie() );
}

# --- the cookie must actually be honoured, or nothing below tests anything --
# If the cookie were rejected outright, every assertion here would pass for the
# wrong reason: a rejected cookie opens no gate because it does nothing at all.
my $open_preview = get_previewing('/open');
like( $open_preview, qr/OPENBODY/, 'a public page still renders while previewing' );
like( $open_preview, qr/no-store/i,
    'and the preview render is marked no-store - proof the cookie was READ, '
        . 'so the refusals below are the gate and not a rejected cookie' );

# --- auth: required ---------------------------------------------------------
my $gated = get_previewing('/gated');
unlike( $gated, qr/AUTHSECRET/,
    'a preview cookie does not reveal a page behind auth: required' );
like( $gated, qr/^Status: 30[12]/m, 'it is redirected, as an anonymous visitor is' );

# --- an ACL rule ------------------------------------------------------------
my $acled = get_previewing('/acled');
unlike( $acled, qr/ACLSECRET/,
    'a preview cookie does not reveal a page an ACL withholds' );

# --- a draft section --------------------------------------------------------
# The third gate SM649 names, and the one a preview is most plausibly ABOUT:
# previewing an unpublished page is exactly what somebody would expect a
# preview grant to be for. It is not - the cookie carries a layout and a theme,
# not a right to see held-back content.
my $draft = get_previewing('/drafty');
unlike( $draft, qr/DRAFTSECRET/,
    'a preview cookie does not reveal a page held back as draft' );

# --- and the same requests without the cookie behave identically ------------
# The comparison is what makes this a statement about the PREVIEW rather than
# about the gates: if previewing changed nothing, these must match.
my $gated_plain = get('/gated');
my $acled_plain = get('/acled');
is( ( $gated =~ /AUTHSECRET/ ? 1 : 0 ), ( $gated_plain =~ /AUTHSECRET/ ? 1 : 0 ),
    'previewing changes nothing about what auth: required discloses' );
is( ( $acled =~ /ACLSECRET/ ? 1 : 0 ), ( $acled_plain =~ /ACLSECRET/ ? 1 : 0 ),
    'previewing changes nothing about what an ACL discloses' );

# --- the ordering itself ----------------------------------------------------
# The property above holds because check_preview() is called BELOW the auth
# gates. Asserted structurally as well, so a reviewer moving that call sees a
# test naming the reason rather than discovering it from a failure elsewhere.
my $src = do {
    open my $fh, '<', "$FindBin::Bin/../../lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};
my ($auth_at)    = $src =~ /\A(.*?)\bcheck_auth\(/s;
my ($preview_at) = $src =~ /\A(.*?)\bif \( my \$pv = check_preview\(\) \)/s;
ok( defined $auth_at && defined $preview_at,
    'both call sites can be located' );
cmp_ok( length($auth_at), '<', length($preview_at),
    'check_preview is called AFTER check_auth - hoisting it above would make '
        . 'a preview cookie an authentication bypass' );

done_testing();
