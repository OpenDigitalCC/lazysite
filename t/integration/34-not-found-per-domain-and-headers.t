#!/usr/bin/perl
# SM253: a 404 belongs to the domain that was asked, and carries the same
# baseline headers as every other response.
#
# Two defects shared one short function. `_system_page_md` has always taken a
# content root and resolves three tiers - the domain's root, the docroot, the
# shipped default - and the 404 call site never passed one, so the first tier
# collapsed into the second: a visitor who mistyped a URL on a secondary domain
# got the PRIMARY site's 404, with the primary's branding and navigation. The
# cache slot was hard-coded to the docroot too, so one domain's rendered 404
# could be served to another.
#
# And `not_found` printed its own status line and content type, bypassing
# output_page - so the one response most likely to be reached by a scanner or a
# crawler was the only one served without X-Content-Type-Options and the rest.
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

# A secondary domain with its own content root AND its own 404.
make_path("$docroot/sites/clienta");
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "alias_hosts: clienta.example\n"
    . "alias.clienta.example.content_root: sites/clienta\n";
close $cf;

open my $p404, '>', "$docroot/404.md" or die $!;
print {$p404} "---\ntitle: Primary missing\n---\n\nPRIMARY-404-BODY\n";
close $p404;

open my $c404, '>', "$docroot/sites/clienta/404.md" or die $!;
print {$c404} "---\ntitle: Client A missing\n---\n\nCLIENTA-404-BODY\n";
close $c404;

# --- the secondary domain serves ITS OWN 404 --------------------------------
{
    my $out = run_processor( $docroot, '/no-such-page',
        HTTP_HOST => 'clienta.example' );
    like( $out, qr/Status: 404/, 'a missing page is a 404' );
    like( $out, qr/CLIENTA-404-BODY/,
        "the DOMAIN's own 404 is served - the whole defect" );
    unlike( $out, qr/PRIMARY-404-BODY/,
        "and the primary's 404 does not leak onto someone else's domain" );
}

# --- the primary still serves its own ---------------------------------------
{
    my $out = run_processor( $docroot, '/no-such-page' );
    like( $out, qr/Status: 404/, 'the primary 404s too' );
    like( $out, qr/PRIMARY-404-BODY/, 'with its own page' );
}

# --- a domain with NO 404 of its own still inherits --------------------------
# The three-tier resolution must keep working: this is the SM110 chrome-only
# case, and breaking it would trade one defect for another.
{
    make_path("$docroot/sites/clientb");
    open my $c, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$c} "alias.clientb.example.content_root: sites/clientb\n";
    close $c;
    # alias_hosts must list it too.
    my $conf = do {
        open my $r, '<', "$docroot/lazysite/lazysite.conf" or die $!;
        local $/; <$r>;
    };
    $conf =~ s/^alias_hosts: .*$/alias_hosts: clienta.example, clientb.example/m;
    open my $w, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$w} $conf;
    close $w;

    my $out = run_processor( $docroot, '/no-such-page',
        HTTP_HOST => 'clientb.example' );
    like( $out, qr/PRIMARY-404-BODY/,
        'a domain with no 404 of its own inherits the docroot copy' );
}

# --- the cache slot is per-domain -------------------------------------------
# Hard-coding it to the docroot would serve one domain's rendered 404 to
# another, which is the same defect one layer down.
{
    run_processor( $docroot, '/nope', HTTP_HOST => 'clienta.example' );
    ok( -f "$docroot/sites/clienta/404.html",
        "the domain's 404 caches under ITS content root" );
}

# --- baseline security headers ----------------------------------------------
{
    my $out = run_processor( $docroot, '/no-such-page',
        HTTP_HOST => 'clienta.example' );
    like( $out, qr/X-Content-Type-Options:\s*nosniff/i,
        'a 404 carries nosniff, as every 200 does' );
    like( $out, qr/X-Frame-Options:\s*SAMEORIGIN/i, 'and X-Frame-Options' );
    like( $out, qr/Referrer-Policy:/i,              'and Referrer-Policy' );
    like( $out, qr/Status: 404 Not Found/,
        'while still being a 404 - the status is not lost to output_page' );
}

# --- the bare fallback (no 404.md anywhere) also gets them ------------------
{
    my $bare = tempdir( CLEANUP => 1 );
    setup_test_site($bare);
    unlink "$bare/404.md";
    my $out = run_processor( $bare, '/missing' );
    like( $out, qr/Status: 404/, 'the bare fallback is a 404' );
    like( $out, qr/X-Content-Type-Options:\s*nosniff/i,
        'and carries the headers too' );
}

# --- a 200 is unaffected ----------------------------------------------------
# output_page gained a status parameter; every existing caller must keep
# emitting 200.
{
    my $out = run_processor( $docroot, '/index' );
    like( $out, qr/Status: 200 OK/, 'an ordinary page is still 200 OK' );
}

done_testing();
