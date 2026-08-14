#!/usr/bin/perl
# SM299 + SM300: the llms.txt entries resolve, and a description is separable
# from the visible subheading.
#
# SM299. The template appended `.md` to every page URL. That is right for
# `/about` and wrong for an INDEX page, whose URL already ends in a slash - so
# `/docs/integrations/` became `/docs/integrations/.md`, which is not a file.
# The homepage is an index page, so the FIRST entry of every site's llms.txt was
# a dead link, and it is the entry an AI client is most likely to follow first.
# lazysite's own shipped documentation carried the same fault.
#
# SM300. `subtitle` was simultaneously the visible subheading, the
# <meta name="description">, and the llms.txt description. On a page with a
# designed hero a subtitle renders directly above the hero, so the author's only
# options were an unwanted subheading or NO description anywhere. A live site's
# homepage took the second: no meta description, and the only description-less
# entry in its llms.txt.
#
# `meta_desc` and `meta_title` are what ADR 0008 already froze and neither
# existed. They now override, falling back to subtitle/title, so every existing
# page renders exactly as before.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Copy qw(copy);
use TestHelper qw(setup_test_site run_processor repo_root);

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 ) . '/public_html';
make_path($d);
setup_test_site($d);

# Install the SHIPPED registry templates, not a copy written here. The defect is
# in the shipped template, so a fixture that carried its own would assert
# nothing about what operators actually receive.
make_path("$d/lazysite/templates/registries");
for my $tt ( glob "$root/starter/lazysite/templates/registries/*.tt" ) {
    ( my $base = $tt ) =~ s{.*/}{};
    copy( $tt, "$d/lazysite/templates/registries/$base" ) or die "copy $tt: $!";
}

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

# A layout that prints BOTH variables, so the separation is directly
# observable. The fixture's default layout renders neither, and the shipped
# fallback layout renders only one - neither would show whether the two values
# had been conflated, which is the entire property under test.
spit( "$d/lazysite/layouts/test/layout.tt", <<'TT' );
<html><head>
[% IF page_meta_desc %]<meta name="description" content="[% page_meta_desc %]">[% END %]
<title>[% page_meta_title %]</title></head>
<body>
[% IF page_subtitle %]<p class="sub">[% page_subtitle %]</p>[% END %]
[% content %]
</body></html>
TT

# A homepage with a designed hero: no subtitle by choice, an explicit
# description. This is the page the report was about.
spit( "$d/index.md", <<'MD' );
---
title: Home
meta_desc: The description a hero page could not previously have.
register:
  - sitemap.xml
  - llms.txt
---
Body.
MD

# An index page in a subdirectory - the URL ends in a slash.
spit( "$d/docs/index.md", <<'MD' );
---
title: Docs
subtitle: Documentation index
register:
  - sitemap.xml
  - llms.txt
---
Docs body.
MD

# An ordinary leaf page, to prove the common case is unchanged.
spit( "$d/about.md", <<'MD' );
---
title: About
subtitle: Who we are
register:
  - sitemap.xml
  - llms.txt
---
About body.
MD

my $llms = run_processor( $d, '/llms.txt' );

subtest 'SM299: every llms.txt link points at a file that exists' => sub {
    my @links = ( $llms =~ m{\]\((\S+?)\)}g );
    cmp_ok( scalar @links, '>=', 3, 'the registry lists the pages' )
        or diag($llms);

    unlike( $llms, qr{/\.md},
        'no entry ends in "/.md" - the index-page bug, and it was the FIRST '
            . 'line of every site\'s llms.txt' );

    # Each link must correspond to a real source file under the docroot.
    for my $l (@links) {
        ( my $rel = $l ) =~ s{\A https?://[^/]+ }{}x;
        ok( -f "$d$rel", "$l resolves to a file in the docroot" );
    }
};

subtest 'SM299: an index page links to its index.md' => sub {
    like( $llms, qr{\Q/docs/index.md\E},
        'the docs index links to /docs/index.md, not /docs/.md' );
    like( $llms, qr{\Q/index.md\E},
        'and the homepage likewise' );
    like( $llms, qr{\Q/about.md\E},
        'while an ordinary page is unchanged - the fix must not "repair" the '
            . 'case that was already right' );
};

subtest 'SM300: meta_desc describes without printing a subheading' => sub {
    my $home = run_processor( $d, '/' );

    like( $home, qr{<meta name="description" content="The description a hero},
        'the explicit description reaches the meta tag' );
    unlike( $home, qr{<p class="sub">},
        'and NO subheading is printed - which is the whole reason the page '
            . 'could not have a description before: its only option was a '
            . 'subtitle it did not want' );

    like( $llms, qr{The description a hero page could not previously have},
        'and it is the description in llms.txt too, so the two agree' );
};

subtest 'SM300: subtitle still does everything it used to' => sub {
    my $about = run_processor( $d, '/about' );

    like( $about, qr{<meta name="description" content="Who we are"},
        'a page with only a subtitle still gets a meta description from it' );
    like( $about, qr{<p class="sub">Who we are</p>},
        'and still prints it as a subheading - the fallback must not have '
            . 'turned subtitle into a description-only field' );
    like( $llms, qr{Who we are},
        'and still describes it in llms.txt - every existing page is unchanged' );
};

done_testing();
