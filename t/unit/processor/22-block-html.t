#!/usr/bin/perl
# Block-level HTML (e.g. a hero <section> with Markdown inside) must not be
# paragraph-wrapped by Text::MultiMarkdown into invalid <p><section>..</p>.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# A hero section with Markdown inside (the barn-site pattern).
my $html = main::convert_md(qq{<section class="hero">\n# Welcome\n\nSome text.\n</section>\n});
unlike( $html, qr/<p>\s*<section/,        'no <p> hugging the opening <section>' );
unlike( $html, qr{</section>\s*</p>},     'no </p> hugging the closing </section>' );
like(   $html, qr/<section class="hero">/, 'the section element survives' );

for my $tag (qw(section div article figure header footer ul table style)) {
    my $h = main::convert_md("<$tag>\ncontent\n</$tag>\n");
    unlike( $h, qr/<p>\s*<$tag\b/, "no spurious <p> before <$tag>" );
}

# Direct + deterministic.
is( main::unwrap_block_html('<p><section class="x">hi</section></p>'),
    '<section class="x">hi</section>', 'unwrap_block_html strips both ends' );

# Ordinary paragraphs are still wrapped (no over-reach).
like( main::convert_md("Just a paragraph.\n"), qr{<p>Just a paragraph\.</p>},
    'normal paragraphs are still <p>-wrapped' );

done_testing();
