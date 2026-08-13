#!/usr/bin/perl
# SM179 P3: the generated sitemap.xml advertises a page's language alternates as
# <xhtml:link rel="alternate" hreflang=...> entries (the sitemaps.org way to
# declare translations to search engines). Each language's own sitemap lists the
# full set - including itself - and omits a language whose counterpart is absent.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $repo = "$FindBin::Bin/../..";
my $d    = tempdir( CLEANUP => 1 );
make_path(
    "$d/lazysite/templates/registries",
    "$d/sites/en", "$d/sites/de",
);

# The real sitemap registry template drives generation.
copy( "$repo/starter/lazysite/templates/registries/sitemap.xml.tt",
    "$d/lazysite/templates/registries/sitemap.xml.tt" )
    or die "copy sitemap.tt: $!";

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c <<'CONF';
site_name: T
lang: en
lang_group: providers
site_url: https://en.example
content_root: sites/en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.site_url: https://de.example
alias.de.example.content_root: sites/de
CONF
close $c;

# /compare exists in both languages and registers for the sitemap; /only-en
# exists (and registers) only in English.
for my $root (qw(en de)) {
    open my $p, '>', "$d/sites/$root/compare.md" or die $!;
    print $p "---\ntitle: compare\nregister:\n  - sitemap.xml\n---\n\nbody\n";
    close $p;
    open my $i, '>', "$d/sites/$root/index.md" or die $!;
    print $i "---\ntitle: home\n---\n\nhome\n";
    close $i;
}
open my $o, '>', "$d/sites/en/only-en.md" or die $!;
print $o "---\ntitle: only\nregister:\n  - sitemap.xml\n---\n\nbody\n";
close $o;

# SM293 step 3: the sitemap is GENERATED ON REQUEST and served by the engine -
# it is no longer written into the content root, because a file at the docroot
# root is resolved by the front end before the engine is asked which domain was
# requested (that is SM248). So fetch it the way a crawler would.
my $xml = run_processor( $d, '/sitemap.xml', HTTP_HOST => 'en.example' );

like( $xml, qr{xmlns:xhtml="http://www\.w3\.org/1999/xhtml"},
    'urlset declares the xhtml namespace' );
like( $xml, qr{<loc>https://en\.example/compare</loc>}, 'the en page is listed' );
like(
    $xml,
    qr{<xhtml:link rel="alternate" hreflang="en" href="https://en\.example/compare"/>},
    'the page lists itself (en) as an alternate'
);
like(
    $xml,
    qr{<xhtml:link rel="alternate" hreflang="de" href="https://de\.example/compare"/>},
    'the page lists its de sibling as an alternate'
);

# only-en has no de counterpart: it must NOT advertise a de alternate.
unlike( $xml, qr{hreflang="de" href="https://de\.example/only-en"},
    'an untranslated page advertises no missing-language alternate' );

done_testing;
