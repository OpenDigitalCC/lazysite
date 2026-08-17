#!/usr/bin/perl
# SM352: the header set, asserted through the engine rather than read off it.
#
# WHY THIS EXISTS SEPARATELY FROM t/lint/55. That lint proves the processor's
# copy of the set matches the module's. Neither of them proves a response
# carries it: a header printed into a branch nothing reaches is a line of source
# that looks correct from any distance. The standing rule in this project is
# that a text match proves a line exists, never that it behaves.
#
# AND THAT IS EXACTLY HOW THE DEFECT SURVIVED. The field probe measured the
# homepage, found nosniff, X-Frame-Options and Referrer-Policy, and reported all
# three set correctly. They were correct on ONE of four response paths. The
# static path - every stylesheet, script, SVG and image the processor serves -
# carried one of the three, and probing the homepage could not have shown it.
#
# So the case that matters most here is the STATIC one, and it is first.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(setup_test_site run_processor);
use Lazysite::SecurityHeaders ();

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

open my $ix, '>', "$docroot/index.md" or die $!;
print {$ix} "---\ntitle: Home\n---\nHome.\n";
close $ix;

# The static path the processor serves ITSELF is the content-rooted one
# (SM151 P6, _serve_content_static). A static in the primary docroot is the web
# server's to hand over, so putting the fixture there would have exercised
# nothing - the request 404s from the engine and the assertion would have been
# about a response the defect never touched.
make_path("$docroot/sites/clienta/assets");
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "alias_hosts: clienta.example\n"
    . "alias.clienta.example.content_root: sites/clienta\n";
close $cf;

open my $ci, '>', "$docroot/sites/clienta/index.md" or die $!;
print {$ci} "---\ntitle: Client A\n---\nHello.\n";
close $ci;
open my $css, '>', "$docroot/sites/clienta/assets/site.css" or die $!;
print {$css} "body { color: #333 }\n";
close $css;

sub static_get {
    my (%env) = @_;
    return run_processor( $docroot, '/assets/site.css',
        HTTP_HOST => 'clienta.example', %env );
}

# The set the engine is supposed to produce, asked of the authority rather than
# spelled out again here - so adding a header to the module extends this test
# instead of leaving it asserting a stale list.
sub expected_names {
    my ($https) = @_;
    return map { (/^([^:]+):/)[0] }
        Lazysite::SecurityHeaders::security_headers( https => $https );
}

sub carries {
    my ( $out, $https, $what ) = @_;
    for my $name ( expected_names($https) ) {
        like( $out, qr/^\Q$name\E:\s*\S/mi, "$what carries $name" );
    }
    return;
}

subtest 'a static file - the path that was short by two' => sub {
    my $out = static_get();
    like( $out, qr/Status: 200/, 'served' );
    carries( $out, 0, 'a stylesheet' );
};

subtest 'a rendered page' => sub {
    my $out = run_processor( $docroot, '/' );
    carries( $out, 0, 'a page' );
};

subtest 'a 404' => sub {
    my $out = run_processor( $docroot, '/no-such-page' );
    like( $out, qr/Status: 404/, 'is a 404' );
    carries( $out, 0, 'a 404' );
};

subtest 'HSTS follows the connection, not the configuration' => sub {
    # Over plain HTTP the header is ABSENT rather than present-and-ignored. A
    # browser would ignore it either way, so this is not about the browser: it
    # is about the response not asserting a policy the connection cannot carry,
    # and about an instance genuinely served over HTTP never being handed a
    # directive that would lock it out of its own site.
    my $plain = run_processor( $docroot, '/' );
    unlike( $plain, qr/^Strict-Transport-Security:/mi,
        'no HSTS over plain HTTP' );

    my $tls = run_processor( $docroot, '/', HTTPS => 'on' );
    like( $tls, qr/^Strict-Transport-Security:\s*max-age=300\s*$/mi,
        'HSTS over TLS, at the short starting max-age' );
    unlike( $tls, qr/^Strict-Transport-Security:.*(?:includeSubDomains|preload)/mi,
        'and neither of the two qualifiers that cannot be withdrawn' );

    # The same question on the static path, because that is the one that had
    # its own header list and would be the one to drift again.
    my $tls_css = static_get( HTTPS => 'on' );
    like( $tls_css, qr/^Strict-Transport-Security:/mi,
        'a stylesheet gets it too' );
};

subtest 'Permissions-Policy denies what the platform never uses' => sub {
    my $out = run_processor( $docroot, '/' );
    my ($pp) = $out =~ /^Permissions-Policy:\s*(.+)$/mi;
    ok( $pp, 'the header is present' ) or return;

    for my $f (qw(camera microphone geolocation)) {
        like( $pp, qr/\b\Q$f\E=\(\)/, "$f is denied" );
    }

    # Not tidiness. "No trackers" is a codified feature of this product, and
    # browsing-topics is the browser offering the page an interest profile of
    # its visitor. A site that cannot ask is a stronger claim than one that
    # merely does not.
    like( $pp, qr/\bbrowsing-topics=\(\)/,
        'and so is the Topics API' );

    # Denying these would be the engine overruling an author about their own
    # video, which is not what a security default is for.
    unlike( $pp, qr/\b(?:autoplay|fullscreen|picture-in-picture)=/,
        'while the capabilities a page might legitimately want are untouched' );
};

subtest 'and no enforcing CSP, because the engine would violate it' => sub {
    # t/lint/56 holds the inventory - ten across the engine, eight of them in the processor.
    # Emitting a policy the engine breaks on every page would be a security
    # header that says something the response does not do.
    my $out = run_processor( $docroot, '/' );
    unlike( $out, qr/^Content-Security-Policy:/mi, 'absent, deliberately' );
};

done_testing();
