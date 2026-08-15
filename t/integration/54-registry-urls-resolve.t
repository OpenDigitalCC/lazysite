#!/usr/bin/perl
# SM316: every URL a generated registry advertises must actually retrieve.
#
# A registry is a list of promises about what retrieves. Nothing checked that
# they do.
#
# WHAT THIS WOULD HAVE CAUGHT. SM299: every site's llms.txt opened with a dead
# link, including lazysite's own documentation, for as long as that namespace has
# existed. The template built a source URL by appending ".md" to the page URL,
# which is right for an ordinary page and wrong for an INDEX page - whose URL
# already ends in a slash, so it produced "<dir>/.md". The homepage is an index
# page, so the broken entry was the FIRST line of every site's llms.txt and the
# one an AI client is most likely to follow.
#
# It shipped, and the check did not. The fix landed in 0.10.9 and the site agent
# who found it recommended this assertion in the filing itself; t/lint/46 was
# written instead, and t/lint/46 asserts the registration POLICY by globbing
# source files. It establishes which pages DECLARE llms.txt. It cannot establish
# that what the file advertises resolves, which is the only thing SM299 was about.
#
# THE SHAPE THIS COVERS is a URL constructed by string manipulation from another
# URL. Every registry does that, in four templates, and a rule that holds for the
# common case and breaks on a trailing slash is exactly the kind of thing review
# does not catch and a fetch does.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Copy qw(copy);
use TestHelper qw(setup_test_site run_processor repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# The SHIPPED registry templates, not copies written here. The defect this file
# exists for lived IN a shipped template, so a fixture carrying its own would
# assert that the test's copy was right and nothing about what sites receive.
# t/integration/51 makes the same choice for the same reason.
make_path("$docroot/lazysite/templates/registries");
for my $tt ( glob "$root/starter/lazysite/templates/registries/*.tt" ) {
    ( my $base = $tt ) =~ s{.*/}{};
    copy( $tt, "$docroot/lazysite/templates/registries/$base" )
        or die "copy $tt: $!";
}

# A site with the three shapes that differ: an ordinary page, a folder index, and
# a NESTED folder index. The nested one matters on its own - the 0.10.9 fix was
# first written with a non-recursive glob and missed a subdirectory (t/lint/46),
# so a fixture with only one level of nesting would have passed against the
# half-fixed engine.
sub page {
    my ( $rel, $title, %opt ) = @_;
    my $path = "$docroot/$rel";
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "$path: $!";
    print $fh "---\ntitle: $title\n";
    print $fh "subtitle: About $title\n";
    # Registered for ALL FOUR registries, and dated, because the feeds select on
    # a date. The point is to cover every generated registry in one fixture: all
    # four build a URL by string manipulation from another URL, which is the
    # shape SM299 broke, so testing only the two that happened to be reported
    # would leave the same defect reachable in the other two.
    print $fh "date: 2026-08-1$opt{day}\n" if $opt{day};
    print $fh
        "register:\n  - sitemap.xml\n  - llms.txt\n  - feed.rss\n  - feed.atom\n"
        unless $opt{no_register};
    print $fh "---\n\nBody of $title.\n";
    close $fh;
    return;
}

page( 'index.md',            'Home',   day => 1 );
page( 'about.md',            'About',  day => 2 );
page( 'docs/index.md',       'Docs',   day => 3 );
page( 'docs/guide.md',       'Guide',  day => 4 );
page( 'docs/deep/index.md',  'Deep',   day => 5 );
page( 'docs/deep/detail.md', 'Detail', day => 6 );

# Prime every page so the registries have something to list.
run_processor( $docroot, $_ )
    for qw(/ /about /docs/ /docs/guide /docs/deep/ /docs/deep/detail);

# Strip CGI headers and return the body.
sub body_of {
    my ($out) = @_;
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

# Fetch a site-relative URL through the processor and return ( status, body ).
# The processor emits its status in the CGI header block; absent one, a body
# means 200.
sub fetch {
    my ($url)    = @_;
    my $out      = run_processor( $docroot, $url ) // '';
    my ($status) = $out =~ m{^Status:\s*(\d{3})}mi;
    $status ||= ( length body_of($out) ? 200 : 500 );
    return ( $status, body_of($out) );
}

# Every URL a registry advertises, as site-relative paths. Absolute URLs are
# reduced to their path: the fixture's site_url is http://localhost and what is
# being asserted is that the PATH resolves, not that a hostname is reachable.
sub urls_in {
    my ($text) = @_;
    my %seen;
    my @urls;

    # FOUR registries, four shapes - and getting this list wrong is how a check
    # like this passes while asserting nothing. The first cut knew only the
    # first two and reported both feeds as advertising zero URLs, which looked
    # like a defect in the engine and was a defect in the test.
    #
    #   sitemap.xml  <loc>URL</loc>
    #   llms.txt     markdown [label](URL)
    #   feed.rss     <link>URL</link> and <guid>URL</guid>
    #   feed.atom    <link href="URL"/>
    while ( $text =~ m{<loc>\s*([^<\s]+)\s*</loc>}gi )          { push @urls, $1 }
    while ( $text =~ m{\]\(\s*([^)\s]+)\s*\)}g )                { push @urls, $1 }
    while ( $text =~ m{<link>\s*([^<\s]+)\s*</link>}gi )        { push @urls, $1 }
    while ( $text =~ m{<guid[^>]*>\s*([^<\s]+)\s*</guid>}gi )   { push @urls, $1 }
    while ( $text =~ m{<link\b[^>]*\bhref=["']([^"']+)["']}gi ) { push @urls, $1 }

    my @out;
    for my $u (@urls) {
        $u =~ s{\Ahttps?://[^/]+}{};
        next unless length $u && $u =~ m{\A/};
        next if $seen{$u}++;
        push @out, $u;
    }
    return @out;
}

my %REGISTRY = (
    'sitemap.xml' => '/sitemap.xml',
    'llms.txt'    => '/llms.txt',
    'feed.rss'    => '/feed.rss',
    'feed.atom'   => '/feed.atom',
);

for my $name ( sort keys %REGISTRY ) {
    subtest "every URL in $name retrieves" => sub {
        my ( $st, $reg ) = fetch( $REGISTRY{$name} );
        is( $st, 200, "$name is served" ) or do {
            diag("Body was:\n$reg");
            return;
        };

        my @urls = urls_in($reg);
        cmp_ok( scalar @urls, '>=', 3,
            "$name advertises the fixture's pages" )
            or diag("Extracted nothing from:\n$reg");

        my @dead;
        for my $u (@urls) {
            my ($s) = fetch($u);
            push @dead, "$u -> $s" unless $s == 200;
        }

        is_deeply( \@dead, [], "every URL $name advertises returns 200" )
            or diag( join "\n  ",
            '',
            @dead,
            '',
            'A registry is a list of promises about what retrieves. SM299 was',
            'one of these: "<dir>/.md" for every index page, which is the FIRST',
            'line of every site llms.txt because the homepage is an index page.' );
    };
}

subtest 'the index-page shape specifically, since that is what SM299 broke' => sub {
    # Named separately so a regression reports the CAUSE rather than a list of
    # dead links. The general assertion above would catch it; this says why.
    my ( undef, $llms ) = fetch('/llms.txt');

    unlike( $llms, qr{/\.md\b},
        'no entry is built as "<dir>/.md"' )
        or diag( 'A URL ending in a slash had ".md" appended to it. The '
            . 'homepage is an index page, so this is entry one.' );

    like( $llms, qr{/index\.md\b},
        'an index page advertises its real source file' );
    like( $llms, qr{/docs/deep/index\.md\b},
        'including a NESTED index - the case the first fix missed' );
};

done_testing();
