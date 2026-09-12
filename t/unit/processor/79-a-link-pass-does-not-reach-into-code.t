#!/usr/bin/perl
# SM853: the post-TT Markdown-link pass converts TEXT, and text is not the whole
# document.
#
# `convert_p_links` exists for one narrow case: a Markdown link whose URL holds a
# TT variable is parsed by MultiMarkdown BEFORE TT runs, which strips the
# variable out of the URL, so the link has to be converted again afterwards. Its
# name said `<p>`; its pattern was `s{\[([^\]]+)\]\(([^)]+)\)}{...}g` over the
# whole rendered page.
#
# `x[i](y)` is ordinary JavaScript, ordinary CSS and ordinary code prose. The
# Handlers page shipped in 0.13.13 with `BUILD[listId](key)` in its only script:
# the anchor this pass spliced in broke the parse of all 26KB of it, so every
# panel stayed at "Loading...", every button was inert, and nothing was logged -
# the engine had eaten the page it was serving. The site agent found it from
# outside, by compiling the script in the browser.
#
# Nothing in the suite asked what this pass did to a script, a code sample or an
# attribute, so the answer was never wrong until it mattered.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir run_processor setup_test_site);

load_processor( site_tempdir() );

subtest 'it still does the job it exists for' => sub {
    is( main::convert_p_links('<p>See [the guide](/docs/guide).</p>'),
        '<p>See <a href="/docs/guide">the guide</a>.</p>',
        'a link left in paragraph text is converted' );
    is( main::convert_p_links('<li>[Docs](/docs/a-b_c?x=1&amp;y=2)</li>'),
        '<li><a href="/docs/a-b_c?x=1&amp;y=2">Docs</a></li>',
        'and in a list item - text is text wherever it sits' );
    is( main::convert_p_links('<p>[A](/a) then [B](/b)</p>'),
        '<p><a href="/a">A</a> then <a href="/b">B</a></p>',
        'two in one paragraph' );
};

subtest 'and it reaches into nothing else' => sub {
    my %leave = (
        'a script' => "<script>\nbody.innerHTML = BUILD[listId](key);\n</script>",
        'a script with attributes' =>
            qq{<script type="text/javascript" defer>var f = fns[name](arg);</script>},
        'a style'            => "<style>\n/* [a](b) */\n.x { color: red }\n</style>",
        'inline code'        => '<p>Call <code>arr[i](x)</code> here.</p>',
        'a fenced block'     => "<pre><code>var y = fns[name](arg);\n</code></pre>",
        'an attribute value' => '<div data-shape="[a](b)">t</div>',
        'an alt text'        => '<img src="/a.png" alt="[a](b)">',
    );
    for my $what ( sort keys %leave ) {
        is( main::convert_p_links( $leave{$what} ), $leave{$what},
            "$what is left exactly as it was" );
    }
};

subtest 'the page a browser receives' => sub {
    # Driven through the processor, because the unit answer above was already
    # "protected" in convert_md and the page still arrived mangled: the damage
    # was done by a later pass on the whole document.
    my $d = site_tempdir();
    setup_test_site($d);
    my $line = 'body.innerHTML = BUILD[listId](key);';

    open my $fh, '>', "$d/probe.md" or die $!;
    print {$fh} "---\ntitle: Probe\n---\n\nProse with [a link](/x).\n\n<script>\n$line\n</script>\n";
    close $fh;

    my $out = run_processor( $d, '/probe' );
    like( $out, qr/\Q$line\E/, 'the script reaches the browser as written' );
    unlike( $out, qr/BUILD<a /, 'with no anchor spliced into it' );
    like( $out, qr{<a href="/x">a link</a>}, 'and the prose link is still a link' );
};

done_testing();
