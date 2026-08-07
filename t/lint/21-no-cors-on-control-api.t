#!/usr/bin/perl
# SM230 DRIFT GUARD: the control API is deliberately not callable from a browser
# page. That position is easy to erode by accident - one Access-Control-Allow-
# Origin added to "make the manager work from a dev server" would open the whole
# authenticated surface to any origin, and nothing would fail. This pins the
# position mechanically.
#
# The two .well-known discovery documents in the processor ARE intentionally
# cross-origin (they carry no account data and exist for a browser-side
# onboarding probe), so they are the declared exceptions and everything else is
# refused.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

# --- the authenticated surfaces emit no CORS header at all -------------------
for my $f (qw(lazysite-manager-api.pl lazysite-mcp.pl lazysite-dav.pl
    lazysite-oauth.pl lazysite-auth.pl))
{
    my $path = "$root/$f";
    next unless -f $path;
    my $src = slurp($path);
    # Match EMISSION (the header inside a quoted string), not any mention of it -
    # the comment explaining why the header is absent must not fail this test.
    unlike( $src, qr/["']Access-Control-Allow-/i,
        "$f emits no Access-Control-Allow-* header" );
}

# --- the processor's exceptions are exactly the two discovery documents ------
{
    my $src   = slurp("$root/lazysite-processor.pl");
    my @lines = ( $src =~ /^.*Access-Control-Allow-.*$/mg );
    is( scalar @lines, 2,
        'the processor carries exactly two cross-origin responses' );
    like( $_, qr/Access-Control-Allow-Origin: \*/,
        'each is a plain open-origin discovery response' ) for @lines;

    # Both must sit in the .well-known branches, which carry no account data.
    # The route patterns are /x regexes with escaped dots, so match the document
    # names rather than a literal path.
    like( $src, qr/well-known.{0,40}lazysite-instance/s,
        'the instance marker is a well-known route' );
    like( $src, qr/well-known.{0,40}ai-partner/s,
        'the ai-partner bootstrap is a well-known route' );
}

# --- the preflight is answered explicitly, and grants nothing ----------------
{
    my $src = slurp("$root/lazysite-manager-api.pl");
    like( $src, qr/REQUEST_METHOD.*?eq 'OPTIONS'/s,
        'the control API answers OPTIONS explicitly' );
    like( $src, qr/405 Method Not Allowed/,
        'and refuses it rather than failing opaquely' );
    like( $src, qr/browser-origin preflight refused/,
        'and logs the attempt so an operator can correlate it' );
}

done_testing();
