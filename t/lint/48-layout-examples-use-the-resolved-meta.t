#!/usr/bin/perl
# SM308: no shipped example shows a layout building <head> from the wrong values.
#
# THE RULE. A layout renders <title> from `page_meta_title` and its description
# from `page_meta_desc`. Those are the engine's resolved values - `meta_title //
# title` and `meta_desc // subtitle` - and the registries use the same ones, so a
# layout that resolves its own will disagree with the site's own sitemap.xml,
# llms.txt and feeds.
#
# WHY THIS IS A TEST, AND WHY IT GUARDS THE DOCUMENTATION RATHER THAN THE CODE.
# There are no layouts in this repository - the catalogue is a separate
# repository on its own cadence. What ships here is the briefing that tells a
# layout author what to do, and its worked example.
#
# That example showed `<title>[% page_title %]</title>`. All 23 catalogue
# layouts do the same thing, and 22 of them write the description from
# `page_subtitle`, because they were written from this example. The result was
# that `meta_title` - a field ADR 0008 FREEZES, and which t/lint/45 asserts is
# read - had no observable effect on any real page for an entire release. The
# processor reads it correctly; every layout then overwrote the output.
#
# So the defect propagated through a document, and the document is where it has
# to be stopped. An example is not illustrative here: it is the template every
# subsequent layout is copied from, which makes it executable in every sense
# that matters.
#
# t/lint/45 asserts a frozen field is READ somewhere. It cannot assert the value
# REACHES the output, because the code that discards it lives in another
# repository. This is the nearest thing that can be checked from here.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

# Every shipped documentation page, at any depth - starter/docs/integrations/ is
# the directory a non-recursive glob missed in 0.10.9 (t/lint/46). Walk it.
my @docs;
find(
    {   no_chdir => 1,
        wanted   => sub { push @docs, $_ if /\.(?:md|html)\z/ && -f $_ },
    },
    "$root/starter/docs"
);
@docs = sort @docs;
cmp_ok( scalar @docs, '>=', 10, 'found the shipped documentation' );

subtest 'no example builds <title> or the description from the body values' => sub {
    my @offenders;

    for my $p (@docs) {
        my $text = slurp($p);
        ( my $rel = $p ) =~ s{\A\Q$root/\E}{};

        # A document explaining this trap has to SHOW the wrong code, so the
        # briefing marks its counter-example and this skips between the markers.
        # Marked rather than inferred: a check that guessed which examples were
        # deliberate would be guessing about the one thing it exists to decide.
        $text =~ s/<!--\s*lint-48:\s*counter-example.*?lint-48:\s*end counter-example\s*-->//gs;

        # A <title> whose TT expression mentions page_title. `site_name` may sit
        # alongside it - that is the site suffix, not the page's title.
        while ( $text =~ m{<title>(.*?)</title>}gs ) {
            my $inner = $1;
            next unless $inner =~ /\[%/;                  # a literal title is fine
            next if     $inner =~ /page_meta_title/;
            push @offenders,
                "$rel: <title> built from " . ( $inner =~ /page_title/ ? 'page_title' : 'no resolved value' )
                . ' - use page_meta_title';
        }

        # A description tag fed from page_subtitle.
        while ( $text =~ m{<meta\s[^>]*name=["']description["'][^>]*>}gis ) {
            my $tag = $&;
            next unless $tag =~ /\[%/;
            next if     $tag =~ /page_meta_desc/;
            push @offenders,
                "$rel: <meta name=\"description\"> built from "
                . ( $tag =~ /page_subtitle/ ? 'page_subtitle' : 'no resolved value' )
                . ' - use page_meta_desc';
        }
    }

    is_deeply( \@offenders, [], 'examples use the resolved meta values' )
        or diag( join "\n  ",
        '',
        @offenders,
        '',
        'The engine injects a description ONLY when the rendered HTML has none,',
        'so a layout writing its own wins - quietly. An example that shows the',
        'wrong variable is the template every layout gets copied from: this is',
        'exactly how meta_title came to have no effect on any site at all.' );
};

# SM312: the five front-matter variables the processor escapes before a template
# sees them. Filtering them again produces `&amp;#39;` for an apostrophe.
my @PRE_ESCAPED
    = qw(page_title page_subtitle page_meta_title page_meta_desc page_author);

subtest 'no example filters an already-escaped variable' => sub {
    # THE FIRST VERSION OF THIS FILE SHIPPED THE DEFECT. The <head> contract
    # section added for SM308 showed
    #
    #     content="[% page_meta_desc | html %]"
    #
    # which is the careful-looking thing a layout author would write, and is
    # wrong: lazysite-processor.pl escapes these at the single point they enter
    # the stash (SEC-2026-07 H5) so that EVERY layout emits them safely,
    # including third-party ones and including a layout that forgets to filter.
    # The cost of that choice is this rule, and the rule was never written down -
    # so the example a site agent would copy taught the double-escape, in a
    # document added to stop examples teaching things.
    #
    # Asserted against the processor rather than against a list kept here: the
    # authority is _esc_html at the point of construction, and a second list
    # would be a second place to forget.
    my $proc = slurp("$root/lazysite-processor.pl");
    for my $v (@PRE_ESCAPED) {
        like( $proc, qr/\b\Q$v\E\s*=>\s*\n?\s*_esc_html\b/,
            "$v really is escaped by the processor" );
    }

    my @offenders;
    for my $p (@docs) {
        my $text = slurp($p);
        ( my $rel = $p ) =~ s{\A\Q$root/\E}{};
        $text
            =~ s/<!--\s*lint-48:\s*counter-example.*?lint-48:\s*end counter-example\s*-->//gs;

        for my $v (@PRE_ESCAPED) {
            push @offenders, "$rel: [% $v | html %]"
                if $text =~ /\[%\s*\Q$v\E\s*\|\s*html\s*%\]/;
        }
    }

    is_deeply( \@offenders, [], 'no example double-escapes' )
        or diag( join "\n  ",
        '',
        @offenders,
        '',
        'These arrive HTML-escaped. Filtering again sends an apostrophe to',
        'search engines as &amp;#39;, which renders as the literal &#39;.',
        'Apostrophes are ordinary in English copy and a meta description is',
        'exactly where copy goes - read by machines, and by nobody in review.' );
};

subtest 'the briefing states the contract, not just the variable names' => sub {
    my $brief = "$root/starter/docs/ai-briefing-layouts.md";
    ok( -f $brief, 'the layouts briefing is present' ) or return;
    my $text = slurp($brief);

    like( $text, qr/page_meta_title/,
        'the briefing names page_meta_title' );
    like( $text, qr/page_meta_desc/,
        'the briefing names page_meta_desc' );

    # Naming the variables is not enough - the reason a layout must use them is
    # that ignoring them fails SILENTLY, and a reader who does not know that has
    # no cause to change what already renders.
    like( $text, qr/only when the rendered HTML has none/i,
        'and explains that the engine defers to a layout that writes its own head' );
};

done_testing();
