#!/usr/bin/perl
# SM498: the worked example in the authoring briefing RENDERS, executably.
#
# The GS12 gallery example shipped in 0.10.28 using Markdown image syntax
# with TT expressions inside - which cannot work: the body becomes HTML
# first and TT runs second, so the image converter meets the raw TT tag,
# fails, and renders a literal '!' and a link. Nobody rendered the example
# before shipping it; the field agent did, on the build it documented, and
# every copy of it produced a gallery with no pictures.
#
# This file is the missing discipline: the documented shape, published
# against a real docroot with the example's own JSON, must produce real
# <img> tags with the row's src and alt. And the briefing itself must never
# regress to a copy-pasteable broken example line.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
make_path("$docroot/gallery");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Gallery\n";
close $cf;
open my $jf, '>', "$docroot/gallery/paintings.json" or die $!;
print {$jf} <<'JSON';
{
  "paintings": [
    { "title": "Harbour, dusk", "file": "harbour.jpg",
      "year": 2024, "medium": "oil on board", "sold": false },
    { "title": "Two chairs",    "file": "chairs.jpg",
      "year": 2023, "medium": "acrylic",      "sold": true }
  ]
}
JSON
close $jf;
open my $pf, '>', "$docroot/gallery/index.md" or die $!;
print {$pf} <<'MD';
---
title: Paintings
tt_page_var:
  art: json:/gallery/paintings.json
---
[% FOREACH p IN art.paintings %]
::: card
<img src="/gallery/img/[% p.file %]" alt="[% p.title %]">

**[% p.title %]** - [% p.medium %], [% p.year %][% IF p.sold %] - *sold*[% END %]
:::
[% END %]
MD
close $pf;

my $out = run_processor( $docroot, '/gallery/' );

subtest 'THE DOCUMENTED SHAPE PRODUCES REAL IMAGES' => sub {
    like( $out, qr{<img src="/gallery/img/harbour\.jpg" alt="Harbour, dusk">},
        'row one: an <img> with the row\'s src and alt' )
        or diag( 'If this is a bang and a link, the example regressed to '
            . 'Markdown image syntax, which cannot carry a TT expression.' );
    like( $out, qr{<img src="/gallery/img/chairs\.jpg" alt="Two chairs">},
        'row two as well - the loop multiplied the rendered fence' );
    my $imgs = () = $out =~ /<img /g;
    is( $imgs, 2, 'exactly one image per row' );
    unlike( $out, qr/<p>!\s*<a /, 'no stranded exclamation marks anywhere' );
    like( $out, qr/sold/, 'the conditional renders for the sold row' );
};

subtest 'the briefing itself carries the working form' => sub {
    open my $bf, '<', "$root/starter/docs/ai-briefing-authoring.md" or die $!;
    my $doc = do { local $/; <$bf> };
    close $bf;

    # Line-anchored: an EXAMPLE line an agent would copy (the 0.10.28 form
    # was an indented code line). The limitation paragraph legitimately
    # quotes the broken shape mid-sentence, and the first run of this very
    # assertion caught that quotation - the narrowing is deliberate, not lax.
    unlike( $doc, qr/^\s*!\[\[%/m,
        'no copy-pasteable example line wraps a TT expression in image syntax' )
        or diag( 'The example exists because agents could not find json:; an '
            . 'agent that finds THIS and copies it gets a gallery with no pictures.' );
    like( $doc, qr/Markdown image syntax cannot carry a template expression/,
        'and the limitation is stated in its own right' );
};

done_testing();
