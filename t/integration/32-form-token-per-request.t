#!/usr/bin/perl
# SM252: the form timing token must be per-VISITOR, not per-render.
#
# It used to be minted while the page was rendered and then baked into the cached
# HTML, so every visitor received the same timestamp until the source changed.
# That broke the check in both directions at once: the minimum-dwell test passed
# unconditionally (the interval had elapsed before anyone loaded the page) and the
# two-hour expiry could be spent before a visitor arrived, rejecting a genuine
# submission filled in immediately. A control that always passes is worse than no
# control, because it reads as coverage.
#
# The property under test is not "a token exists" but "two responses from the SAME
# CACHED PAGE carry different tokens" - which is the thing the cache broke.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# A page carrying a form. The form block needs its name in the front matter.
open my $fh, '>', "$docroot/contact.md" or die $!;
print {$fh} <<'PAGE';
---
title: Contact
form: contact
---

# Contact

:::form
name  | Name  | required
email | Email | required email
submit | Send
:::
PAGE
close $fh;

sub token_of {
    my ($out) = @_;
    my ($ts) = $out =~ /name="_ts"\s+value="([^"]*)"/;
    my ($tk) = $out =~ /name="_tk"\s+value="([^"]*)"/;
    return ( $ts, $tk );
}

# --- first render: writes the cache, and carries a real token ---------------
my ( $ts1, $tk1 );
{
    my $out = run_processor( $docroot, '/contact' );
    ( $ts1, $tk1 ) = token_of($out);
    ok( -f "$docroot/contact.html", 'the page cached' );
    like( $ts1 // '', qr/^\d+$/, 'the served page carries a numeric timestamp' );
    like( $tk1 // '', qr/^[0-9a-f]{64}$/, 'and an HMAC token' );

    # The PLACEHOLDER must never reach a visitor.
    unlike( $out, qr/__LAZYSITE_FORM_T[SK]__/,
        'the placeholder is substituted, never served' );
}

# --- the CACHED FILE holds the placeholder, not a token ---------------------
# This is the fix: what is stored is a page, not one visitor's token.
{
    open my $c, '<', "$docroot/contact.html" or die $!;
    my $cached = do { local $/; <$c> };
    close $c;
    like( $cached, qr/__LAZYSITE_FORM_TS__/,
        'the cached HTML holds the placeholder' );
    unlike( $cached, qr/name="_ts"\s+value="\d+"/,
        'and NOT a minted timestamp - that is what leaked to every visitor' );
}

# --- second request, served from that cache, gets a DIFFERENT token ---------
{
    # The timestamp has one-second granularity, so wait for the clock to move -
    # otherwise a passing result would only prove the two ran in the same second.
    my $t0 = time();
    sleep 1 while time() == $t0;

    my $out = run_processor( $docroot, '/contact' );
    my ( $ts2, $tk2 ) = token_of($out);
    like( $ts2 // '', qr/^\d+$/, 'the cache hit still carries a token' );
    isnt( $ts2, $ts1, 'a SECOND visitor gets a different timestamp' );
    isnt( $tk2, $tk1, 'and a different HMAC' );
    cmp_ok( $ts2, '>', $ts1, 'minted now, not when the page was rendered' );
}

# --- a form page is not publicly cacheable ---------------------------------
# Minting per response fixes the server cache and achieves nothing if a shared
# HTTP cache then hands one response to everyone.
{
    my $out = run_processor( $docroot, '/contact' );
    like( $out, qr/Cache-Control:\s*no-store/i,
        'a page carrying a form is no-store, whatever its page TTL' );
    unlike( $out, qr/Cache-Control:\s*public/i,
        'and never public' );
}

# --- a page WITHOUT a form is unaffected ------------------------------------
# The substitution and the header change must both be confined to form pages, or
# this fix silently disables caching for the whole site.
{
    my $out = run_processor( $docroot, '/index' );
    unlike( $out, qr/name="_ts"/, 'an ordinary page has no form token' );
    unlike( $out, qr/Cache-Control:\s*no-store/i,
        'and keeps its ordinary caching - the fix is scoped to form pages' );
}

done_testing();
