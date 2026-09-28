#!/usr/bin/perl
# SM824: schema.org JSON-LD, emitted from metadata the page already has.
#
# The filing's load-bearing constraint is NO NEW AUTHORING BURDEN: if an author
# has to add anything for the ordinary page, it was built wrong. So the ordinary
# case is the first subtest, and it declares nothing.
#
# The filing also asked for an audit before a design, and its four questions are
# answered in the injector's own header. Two of the four are properties a test can
# hold, and they are the two that would otherwise go wrong quietly:
#
#   * `Article` IS NEVER INFERRED. Most lazysite pages are not articles, and
#     guessing the type from a date would be inference published as fact.
#   * THE ESCAPING BOUNDARY has two halves. JSON encoding is the obvious one;
#     `</script>` inside a JSON string is the one that ends the block in a browser
#     however well-formed the JSON is.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $proc = "$root/lazysite-processor.pl";
plan skip_all => "no $proc" unless -f $proc;

# The injector is lifted rather than driven through a render: this is about the
# block it builds from a given set of variables, and a full render would put a
# web server, a layout and a cache between the question and the answer.
my $src = do { open my $fh, '<', $proc or die $!; local $/; <$fh> };
for my $name (qw(_unesc_html _canonical_path _inject_jsonld)) {
    my ($body) = $src =~ /\nsub \Q$name\E \{(.*?)\n\}\n/s
        or die "cannot find sub $name in the processor\n";
    # `eval "sub f {...}"` returns FALSE on success - a sub declaration is not an
    # expression with a value - so the error is the thing to test, not the result.
    ## no critic (ProhibitStringyEval)
    eval "sub $name {$body}\n";
    die "$name: $@" if $@;
}

sub head { return '<html><head><title>t</title></head><body>x</body></html>' }

# The PAGE node, asked for the same way everywhere. Twice now I picked the node
# by "has a name" or "has a slash in its @id", and both times got the WebSite -
# which has both - so a sabotage that made the page node wrong passed. The page is
# the node whose url is the page's url; nothing else in the graph claims that.
sub page_node {
    my ( $data, $url ) = @_;
    my ($n) = grep { ( $_->{url} // '' ) eq $url } @{ $data->{'@graph'} };
    return $n;
}

sub block_from {
    my (%vars) = @_;
    local $ENV{REDIRECT_URL} = $vars{_path} // '/about';
    my $html = _inject_jsonld( head(), {%vars} );
    return undef unless $html =~ m{<script type="application/ld\+json">(.*?)</script>}s;
    return $1;
}

subtest 'the ordinary page declares nothing and still gets a correct block' => sub {
    my $raw = block_from(
        site_url        => 'https://example.org',
        site_name       => 'Example',
        page_meta_title => 'About us',
    );
    ok( $raw, 'a block is emitted' ) or return;

    my $data = eval { decode_json($raw) };
    ok( $data, 'it is valid JSON' ) or diag($raw);
    is( $data->{'@context'}, 'https://schema.org', 'with the schema.org context' );

    my ($page) = grep { ( $_->{'@type'} // '' ) eq 'WebPage' } @{ $data->{'@graph'} };
    ok( $page, 'a WebPage node' ) or return;
    is( $page->{name}, 'About us',                   'named from the page title' );
    is( $page->{url},  'https://example.org/about',  'and addressed by the canonical URL' );

    my ($site) = grep { ( $_->{'@type'} // '' ) eq 'WebSite' } @{ $data->{'@graph'} };
    ok( $site, 'and a WebSite node' );
    is( $site->{name}, 'Example', 'named from the site config' );

    # NOTHING ASSERTED THAT THE SITE DOES NOT HAVE. A block claiming an author or
    # a date the page never carried publishes a false statement about the page.
    ok( !exists $page->{author},        'no author is invented' );
    ok( !exists $page->{datePublished}, 'and no publication date' );
};

subtest 'Article is never inferred - only declared' => sub {
    my $plain = decode_json(
        block_from(
            site_url        => 'https://example.org',
            site_name       => 'Example',
            page_meta_title => 'A post',
            page_modified   => '2026-09-28',
            page_author     => 'Ada',
        ) );
    my ($p) = grep { ref $_->{'@type'} ? 0 : $_->{'@type'} eq 'WebPage' } @{ $plain->{'@graph'} };
    ok( $p, 'a page with a date and an author is still a WebPage' )
        or diag( 'Guessing Article from the presence of a date is inference '
            . 'published as fact, which is what this filing refused.' );

    my $declared = decode_json(
        block_from(
            site_url         => 'https://example.org',
            site_name        => 'Example',
            page_meta_title  => 'A post',
            page_schema_type => 'Article',
        ) );
    my ($d) = grep { ref $_->{'@type'} eq 'ARRAY' } @{ $declared->{'@graph'} };
    ok( $d, 'a page that DECLARES a type gets it' ) or return;
    is_deeply( $d->{'@type'}, [ 'WebPage', 'Article' ],
        'as a second type, not instead of WebPage' );

    # A declared type is a string from front matter, so it is bounded.
    for my $bad ( 'Article Thing', '<script>', 'x' x 60, '' ) {
        my $r = decode_json(
            block_from(
                site_url         => 'https://example.org',
                site_name        => 'Example',
                page_meta_title  => 'T',
                page_schema_type => $bad,
            ) );
        my $n = page_node( $r, 'https://example.org/about' );
        ok( !ref $n->{'@type'}, "a schema_type of '"
                . substr( $bad, 0, 12 ) . "' is ignored, not emitted" );
    }
};

subtest 'the escaping boundary, both halves' => sub {
    my $raw = block_from(
        site_url        => 'https://example.org',
        site_name       => 'Ex &amp; Co',
        page_meta_title => 'Closing &lt;/script&gt; and &quot;quotes&quot; &amp; things',
    );
    ok( $raw, 'a block is emitted' ) or return;

    unlike( $raw, qr{</script>.*</script>}s,
        'no bare </script> inside the JSON ends the block early' )
        or diag( 'Well-formed JSON is not enough: the browser ends the block at '
            . 'the first </script> whatever the JSON says.' );
    like( $raw, qr{<\\/script}, 'the slash is escaped instead' );

    my $data = eval { decode_json($raw) };
    ok( $data, 'and it is still valid JSON' ) or diag($raw);
    # By TYPE, not by "has a name": the WebSite node has one too, and picking
    # the first node with a name asks the site what the page is called.
    my ($page) = grep { ( $_->{'@type'} // '' ) eq 'WebPage' } @{ $data->{'@graph'} };
    ok( $page, 'the page node is there' ) or return;
    like( $page->{name}, qr{</script>},
        'the value round-trips to the text the author wrote' );
    like( $page->{name}, qr/"quotes"/, 'quotes decode' );
    like( $page->{name}, qr/ & /,      'and the ampersand is an ampersand, not &amp;' )
        or diag( 'These values arrive HTML-escaped for the <title> tag; inside a '
            . 'JSON string that escaping is just wrong text.' );
};

subtest 'it declines rather than guessing' => sub {
    ok( !block_from( site_name => 'Example', page_meta_title => 'T' ),
        'no site_url, no block - the same rule the canonical link follows' );
    ok( !block_from( site_url => 'https://example.org', page_meta_title => '' ),
        'no title, no block' );

    my $already = _inject_jsonld(
        '<html><head><script type="application/ld+json">{"@type":"Thing"}</script></head><body></body></html>',
        { site_url => 'https://example.org', site_name => 'E', page_meta_title => 'T' } );
    my $count = () = $already =~ m{application/ld\+json}g;
    is( $count, 1, 'a layout that emits its own block keeps it' )
        or diag('Two blocks is two answers about one page.');
};

done_testing();
