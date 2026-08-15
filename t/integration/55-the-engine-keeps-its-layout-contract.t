#!/usr/bin/perl
# SM320: render a layout and assert what actually comes out.
#
# A layout is the last thing between the engine and the visitor, and until now it
# was the only major component with no behavioural test. t/integration/13
# COMPILES layouts; t/lint/32 checks the manager guide covers the nav. Nothing
# rendered through a layout and looked at the result.
#
# One week of field work produced four filings that all live in that gap:
#
#   no layout renders nav.conf
#   layouts render demo content in place of the page body
#   every shipped layout double-escapes the description
#   meta_title / meta_desc are shadowed, so SM300 reaches almost nobody
#
# WHAT THIS FILE CAN AND CANNOT ASSERT, stated plainly because the nomination
# asked for something this repository cannot do. There are no catalogue layouts
# here - they live in lazysite-layouts, on its own release cadence. A test here
# that claimed to check "every shipped layout" would be checking an empty set and
# reporting a pass, which is the defect this whole programme is about.
#
# So this asserts the ENGINE's half: that a layout is OFFERED everything it needs
# to be correct, in the form the contract promises. Whether a given catalogue
# layout uses what it is offered is that repository's assertion to make, and the
# proposal there says so.
#
# The fixture layout is deliberately minimal and CORRECT - it is the worked
# example a layout author should be able to copy. If the engine's side regresses,
# this fails; if it does not, an author copying this shape gets a working layout.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# A layout that does everything the contract asks: renders the nav with its
# children, renders the page body, and takes the two <head> values from the
# RESOLVED variables WITHOUT re-escaping them.
open my $lay, '>', "$docroot/lazysite/layouts/test/layout.tt" or die $!;
print $lay <<'TT';
<!DOCTYPE html><html><head>
<title>[% page_meta_title %]</title>
[% IF page_meta_desc %]<meta name="description" content="[% page_meta_desc %]">[% END %]
</head><body>
<nav>[% FOREACH item IN nav %]<a href="[% item.url %]">[% item.label %]</a>
[% FOREACH kid IN item.children %]<a class="kid" href="[% kid.url %]">[% kid.label %]</a>[% END %]
[% END %]</nav>
<main>[% content %]</main>
</body></html>
TT
close $lay;

open my $nav, '>', "$docroot/lazysite/nav.conf" or die $!;
print $nav "Home | /\nDocs | /docs/\n  Guide | /docs/guide\n";
close $nav;

# One page carrying every value the contract covers, with the characters that
# break when something escapes twice.
my $SUBTITLE = q{A client's brief, R&D notes and a "quoted" phrase.};
open my $pg, '>', "$docroot/contract.md" or die $!;
print $pg <<"MD";
---
title: The Page Title
subtitle: $SUBTITLE
meta_title: A Different Title For Search
meta_desc: A description that isn't the subtitle.
---

UNIQUE-BODY-MARKER and some ordinary prose.
MD
close $pg;

my $out = run_processor( $docroot, '/contract' ) // '';
$out =~ s/\A.*?\r?\n\r?\n//s;

subtest 'the engine offers the navigation, with children' => sub {
    like( $out, qr{<a href="/">Home</a>},      'a top-level nav item renders' );
    like( $out, qr{<a href="/docs/">Docs</a>}, 'and the second one' );
    like( $out, qr{class="kid" href="/docs/guide">Guide},
        'and a child item, which is what makes nav.conf worth having' )
        or diag( 'nav.conf is the documented way to give a site its navigation '
            . 'and [% nav %] the documented way to render it.' );
};

subtest 'the engine offers the page body' => sub {
    # A layout that renders its own demo content in place of the page was one of
    # the four filings. The engine's half is that `content` carries the page.
    like( $out, qr/UNIQUE-BODY-MARKER/,
        'the page body reaches the layout through [% content %]' );
};

subtest 'meta_title and meta_desc reach the head, resolved' => sub {
    # SM300 shipped these and SM308 found they reached no real page. The engine
    # resolves meta_title // title and meta_desc // subtitle; this asserts the
    # resolution arrives, which is the part this repository owns.
    like( $out, qr{<title>A Different Title For Search</title>},
        'page_meta_title carries meta_title, not title' );
    like( $out, qr{content="A description that isn&#39;t the subtitle\.">},
        'page_meta_desc carries meta_desc, not subtitle' );
};

subtest 'the values are escaped EXACTLY ONCE' => sub {
    # SM312. The processor escapes at the single point these enter the stash, so
    # a layout must not filter again. This is the assertion that would have
    # caught the double-escape across every shipped layout: decode once and the
    # author's characters must come back.
    my ($desc) = $out =~ m{<meta name="description" content="([^"]*)">};
    ok( defined $desc, 'a description tag was emitted' ) or return;

    unlike( $desc, qr/&amp;#\d+;/,
        'no entity is itself escaped' )
        or diag( "Got: $desc\n\n"
            . "&amp;#39; renders as the literal text &#39;. Apostrophes are\n"
            . "ordinary in English copy and a meta description is exactly where\n"
            . "copy goes - read by machines, and by nobody in review." );

    # Decode once: the author's characters must be what comes back.
    my $decoded = $desc;
    $decoded =~ s/&#39;/'/g;
    $decoded =~ s/&quot;/"/g;
    $decoded =~ s/&amp;/&/g;
    is( $decoded, q{A description that isn't the subtitle.},
        'decoding once returns exactly what the author wrote' );
};

subtest 'a subtitle with hostile characters survives the same way' => sub {
    # subtitle shares the code path, and is what most layouts actually use, so
    # it gets the same round trip rather than being assumed equivalent.
    open my $p2, '>', "$docroot/subtitle-only.md" or die $!;
    print $p2 "---\ntitle: Plain\nsubtitle: $SUBTITLE\n---\n\nBody.\n";
    close $p2;

    my $o2 = run_processor( $docroot, '/subtitle-only' ) // '';
    $o2 =~ s/\A.*?\r?\n\r?\n//s;

    my ($d2) = $o2 =~ m{<meta name="description" content="([^"]*)">};
    ok( defined $d2, 'the subtitle becomes the description when meta_desc is absent' )
        or return;
    unlike( $d2, qr/&amp;#\d+;/, 'and is not double-escaped either' );

    my $dec = $d2;
    $dec =~ s/&#39;/'/g;
    $dec =~ s/&quot;/"/g;
    $dec =~ s/&amp;/&/g;
    is( $dec, $SUBTITLE, 'the author\'s apostrophe, ampersand and quotes return' );
};

done_testing();
