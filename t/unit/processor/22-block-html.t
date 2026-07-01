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

# <style>/<script> content is NOT Markdown-processed: CSS/JS emphasis would mangle
# it. The `*/ ... /*` between two CSS comments used to pair into <em>...</em> and
# swallow the rules in between - the login-page styling regression.
{
    my $css = "<style>\n"
        . "/* note one */\n.login-form { color: #111; }\n"
        . "/* note two */\n.login-form button { color: #222; }\n"
        . "</style>\n";
    my $out = main::convert_md($css);
    unlike( $out, qr/<em>/, 'no <em> injected into a <style> block' );
    like(   $out, qr/\.login-form \{ color: #111; \}/, 'CSS rule after a comment survives intact' );
    like(   $out, qr/\.login-form button \{ color: #222; \}/, 'later CSS rule survives' );

    my $js = "<script>\nvar a = 2 * 3 * 4;\n</script>\n";
    unlike( main::convert_md($js), qr/<em>/, 'no <em> injected into a <script> block' );
    like( main::convert_md($js), qr/2 \* 3 \* 4/, 'JS multiplication survives (not emphasis)' );
}

done_testing();
