#!/usr/bin/perl
# SM824 I1/I2/I3, ruled R7 2026-10-02: a layout can emit JSON-LD from front
# matter that already exists.
#
# THREE MEASURED OBSTACLES, offered by the sites agent as input to SM824 rather
# than as a defect report:
#
#   1. the head meta variables reach a layout ALREADY HTML-ESCAPED, by a single
#      escape point with no inverse - so a layout cannot recover the author's
#      text, and `&amp;` inside a JSON string is wrong rather than merely ugly;
#   2. there was no `json` filter reachable from a layout - `%tt_opts` shipped
#      `markdown` and no encoder, so the alternative was hand-rolled quoting in
#      a template, which is the thing a filter exists to avoid;
#   3. `sections` already reached the layout RAW, against the stated
#      single-escape-point invariant.
#
# THE RULING chose to expose a raw copy and ship the filter, rather than
# walk-and-escape `sections` - which would have held the invariant everywhere and
# made JSON-LD from front matter unreachable, as the reporter said it would. So
# item 3 is not a defect to fix: it is the exception this change DOCUMENTS and
# bounds, which is why the third subtest asserts the contract in both directions.
#
# NOT AN ESCALATION, and the reporter graded it so before anyone asked: only the
# page author can write front matter, and that same author can already put raw
# HTML in the page body. Nothing becomes reachable that was not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

my $docroot = site_tempdir();
setup_minimal_site($docroot);

# A layout lives at lazysite/layouts/<name>/layout.tt and is CHOSEN in
# lazysite.conf - not at templates/<name>.tt, which is where the first draft of
# this file put it and got "No such file or directory" for its trouble.
make_path("$docroot/lazysite/layouts/jsonld");
my $layout = "$docroot/lazysite/layouts/jsonld/layout.tt";
open my $lt, '>', $layout or die "$layout: $!";
print {$lt} <<'TT';
<html><head><title>[% page_title %]</title>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"Person",
 "name":[% page_title_raw | json %],
 "description":[% page_meta_desc_raw | json %],
 "author":[% page_author_raw | json %]}
</script>
</head><body><h1>[% page_title %]</h1><p>[% page_subtitle %]</p>
[% content %]</body></html>
TT
close $lt;

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nlayout: jsonld\n";
close $cf;

# EACH CASE GETS ITS OWN PATH, because a rendered page is CACHED. Writing over
# one file and re-requesting the same URL served the first render to every
# subtest after it - three failures that were all one stale page, which is the
# same trap t/integration/105 hit with the registry cache. A distinct path per
# case avoids the question rather than working around it.
my $n = 0;
sub page {
    my (%fm) = @_;
    my $slug = 'case' . ++$n;
    open my $fh, '>', "$docroot/$slug.md" or die $!;
    print {$fh} "---\n";
    print {$fh} "$_: $fm{$_}\n" for sort keys %fm;
    print {$fh} "---\n\nBody.\n";
    close $fh;
    my $out = scalar run_processor( $docroot, "/$slug" );
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

subtest 'the raw twin carries the author text, the escaped one still escapes' => sub {
    my $html = page(
        title     => 'Tom & Jerry',
        subtitle  => 'Cats & dogs',
        meta_desc => 'Cats & dogs',
        author    => 'A & B',
    );

    like( $html, qr/"name":"Tom \\u0026 Jerry"/,
        'the JSON string carries the ampersand, not &amp;' )
        or diag($html);
    like( $html, qr{<h1>Tom &amp; Jerry</h1>},
        'and the markup still gets the ESCAPED value - the escape point is intact' )
        or diag($html);
    unlike( $html, qr/"name":"Tom &amp;amp; Jerry"/,
        'the JSON is not double-escaped, which is what no inverse meant' );
};

subtest 'the filter produces JSON a consumer can parse' => sub {
    my $html = page( title => 'Quote " and \\ and newline', author => 'X' );
    my ($json) = $html =~ m{<script type="application/ld\+json">(.*?)</script>}s;
    ok( $json, 'the block was emitted' ) or diag($html);

    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($json) };
    ok( $data, 'and it DECODES - the point of a filter rather than hand quoting' )
        or diag( "decode failed: $@\n$json" );
    is( $data->{name}, 'Quote " and \\ and newline',
        'round-trips the author text exactly, quote and backslash included' );
};

subtest 'a close-script sequence cannot end the element' => sub {
    # The reason the filter escapes < > & rather than relying on an encoder: a
    # `</script>` inside the JSON would END the script element, and everything
    # after it would be parsed as markup. Valid JSON that cannot break out.
    my $html = page( title => 'before</script><img src=x onerror=alert(1)>after' );
    my ($json) = $html =~ m{<script type="application/ld\+json">(.*?)</script>}s;
    ok( $json, 'the block is still one element' ) or diag($html);
    unlike( $json, qr{</script>}i, 'the sequence is not present literally' );
    like( $json, qr/\\u003c/, 'it is \\u-escaped instead' );

    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($json) };
    is( $data && $data->{name},
        'before</script><img src=x onerror=alert(1)>after',
        'and the value still round-trips - escaped, not mangled' );
    unlike( $html, qr/onerror=alert\(1\)>after/,
        'the payload never appears unescaped anywhere in the page' );
};

subtest 'the contract: a _raw value is not safe in markup, and says so' => sub {
    # I3. The exception is documented where the invariant is stated, and this
    # asserts the half a reader could otherwise get wrong: `_raw` is for `| json`,
    # the plain name is for markup. If a future change silently escaped the raw
    # twins, the JSON assertions above would fail; if it stopped escaping the
    # plain ones, this one does.
    my $html = page( title => '<b>bold</b>' );
    like( $html, qr{<h1>&lt;b&gt;bold&lt;/b&gt;</h1>},
        'the plain name is escaped in markup' )
        or diag($html);

    # The invariant is stated at the stash, in the render part (SM944 S16).
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-processor/render.pm" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/THE RULE FOR A LAYOUT AUTHOR/,
        'and the contract is written where the invariant is stated, not only here' );
};

subtest 'both render paths offer the filter' => sub {
    # There are two %tt_opts blocks - the page render and the component render -
    # and a filter present in one is a filter a component cannot use. SM330's
    # lesson, applied to FILTERS. The component render is in the processor's
    # components part (SM944 S5), so the script and every part are read.
    my $src = join "\n", map {
        open my $fh, '<', $_ or die "$_: $!";
        local $/;
        scalar <$fh>;
    } "$FindBin::Bin/../../../lazysite-processor.pl",
        sort glob("$FindBin::Bin/../../../lazysite-processor/*.pm");
    # One entry per line since SM970 added url_safe to the same maps.
    my $n = () = $src =~ /FILTERS\s+=>\s*\{[^}]*\bjson\s*=>\s*\\&_json_filter\b[^}]*\}/g;
    is( $n, 2, 'json is registered in BOTH tt_opts blocks' );
};

done_testing();
