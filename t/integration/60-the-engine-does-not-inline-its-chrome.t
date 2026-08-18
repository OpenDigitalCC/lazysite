#!/usr/bin/perl
# SM352 step 1: the engine's own chrome is served, not inlined.
#
# A Content-Security-Policy worth setting cannot coexist with the engine
# inlining style and script on every page - under `script-src 'self'` every page
# violated it ten times before a layout or any content was considered. t/lint/56
# holds the inventory; this is the behaviour half of the first five leaving it.
#
# TWO FILES, which was the operator's call. A rule that only matters on a page
# with a multi-step form costs nothing to carry, while a second request costs a
# round trip on every page that has one. The JS bundle is self-contained - each
# behaviour looks for its own elements and does nothing when they are absent -
# which is what lets one reference serve three callers.
#
# WHAT THE LINT CANNOT SEE is whether a response actually carries them, which is
# why this exists beside it: a count in a source file is not a rendered page.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
make_path("$docroot/assets");
for my $f (qw(lazysite-chrome.css lazysite-chrome.js)) {
    open my $out, '>', "$docroot/assets/$f" or die $!;
    print {$out} "/* $f */\n";
    close $out;
}
open my $ix, '>', "$docroot/index.md" or die $!;
print {$ix} "---\ntitle: Home\n---\n\nHome.\n";
close $ix;

subtest 'a rendered page carries no inline script or style' => sub {
    my $out = run_processor( $docroot, '/' );
    my ($body) = $out =~ /\r?\n\r?\n(.*)/s;
    $body //= '';

    my @inline = $body =~ /<(script|style)(?![^>]*\bsrc=)[^>]*>/g;
    is_deeply( \@inline, [],
        'nothing inline in the response' )
        or diag( "Found: @inline\nUnder script-src 'self' each of these is a "
            . 'violation on every page that carries it.' );
};

subtest 'and references the script bundle instead' => sub {
    my $out = run_processor( $docroot, '/' );
    like( $out, qr{<script[^>]+/assets/lazysite-chrome\.js\?v=[^>]*\bdefer\b},
        'the script, deferred so it never blocks the render' )
        or diag( 'Every behaviour in the bundle adjusts an element already on '
            . 'the page - none writes content - so deferring costs nothing and '
            . 'removes the parser stall an inline head script imposes.' );
};

subtest 'the stylesheet goes where its rules are needed, and not elsewhere'
    => sub {
    # NOT on every page, and that is deliberate rather than the oversight my
    # first assertion took it for. The bundle holds the FALLBACK page chrome and
    # the multi-step form rules: a themed page has its own stylesheet and needs
    # neither, so linking it there would be a request for rules that cannot
    # match anything.
    #
    # A BARE docroot - no layout at all - is what exercises the fallback, and
    # setup_test_site does not give one. Built by hand for that reason.
    my $bare = tempdir( CLEANUP => 1 );
    make_path( "$bare/lazysite", "$bare/assets" );
    open my $cf, '>', "$bare/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://x\n";
    close $cf;
    open my $c, '>', "$bare/assets/lazysite-chrome.css" or die $!;
    print {$c} "/* x */\n";
    close $c;
    open my $p2, '>', "$bare/index.md" or die $!;
    print {$p2} "---\ntitle: Bare\n---\n\nBare.\n";
    close $p2;

    my $out = run_processor( $bare, '/' );
    like( $out, qr{<link[^>]+/assets/lazysite-chrome\.css\?v=},
        'the fallback path links the chrome stylesheet' )
        or diag( 'Without a layout this is the only stylesheet the page gets. '
            . 'Losing it is an unstyled site, not a CSP improvement.' );

    my ($body) = $out =~ /\r?\n\r?\n(.*)/s;
    unlike( $body // '', qr/<style[^>]*>/,
        'and still inlines nothing' );
    };

subtest 'the script bundle is referenced exactly once' => sub {
    # Three callers wanted a script and one file serves all three. Injecting it
    # per caller would put three identical tags on an operator's page - one
    # request, but a page that looks like a mistake and invites someone to
    # "fix" it by splitting the bundle again.
    my $out   = run_processor( $docroot, '/' );
    my $count = () = $out =~ m{/assets/lazysite-chrome\.js}g;
    is( $count, 1, 'one reference' );
};

subtest 'a page rendered through a layout gets it too' => sub {
    # The fallback template is not the only path. A site with a real theme never
    # goes through it, and would have got no chrome script at all if the
    # reference lived only there - which is why it is injected on the response
    # rather than emitted by the template.
    make_path("$docroot/lazysite/layouts/plain");
    open my $lt, '>', "$docroot/lazysite/layouts/plain/layout.tt" or die $!;
    print {$lt} "<html><head><title>[% page_title %]</title></head>"
        . "<body>[% content %]</body></html>\n";
    close $lt;
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "layout: plain\n";
    close $cf;

    my $out = run_processor( $docroot, '/' );
    like( $out, qr{/assets/lazysite-chrome\.js},
        'the chrome script is present on a themed page' )
        or diag( 'A themed site would silently lose the auth-control sync - '
            . 'the control that decides whether a cached page shows Sign in or '
            . 'Sign out.' );
};

subtest 'a page with a form inlines nothing either' => sub {
    # STEP 2. Both form scripts used the form NAME to select the form, and
    # `data-form` is already on the element - so iterating `.lazysite-form`
    # does the same job for one form or five, and the name stopped being a
    # reason to generate code per page.
    #
    # An interpolated script is exactly the case that would otherwise need a
    # nonce or a per-page hash. This one turned out not to be interpolated in
    # any way that mattered, which is why the bundle could take it.
    make_path("$docroot/lazysite/forms");
    open my $f, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
    print {$f} "contact: mailto\n";
    close $f;
    open my $pg, '>', "$docroot/contact.md" or die $!;
    print {$pg} "---\ntitle: Contact\n---\n\n::: form contact\nemail: Email\n:::\n";
    close $pg;

    my $out = run_processor( $docroot, '/contact' );
    my ($body) = $out =~ /\r?\n\r?\n(.*)/s;
    $body //= '';

    my @inline = $body =~ /<(script|style)(?![^>]*\bsrc=)[^>]*>/g;
    is_deeply( \@inline, [],
        'a form page carries nothing inline' )
        or diag( "Found: @inline\nThe form scripts were two of the ten, and "
            . 'the two that looked hardest to move.' );
};

done_testing();
