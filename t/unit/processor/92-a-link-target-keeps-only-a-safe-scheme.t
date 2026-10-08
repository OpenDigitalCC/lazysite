#!/usr/bin/perl
# SM970: a value placed as a WHOLE link target through `| url_safe` keeps only a
# scheme that cannot run script.
#
# The stash escapes a query or db value so it cannot leave its attribute (SM869,
# SM966); escaping does not change `javascript:` into anything else. The filter
# passes a value with no scheme, or http/https/mailto/tel, UNCHANGED - it is
# already escaped once, and must not be escaped again - and turns anything else
# into `#`. Driven through the real processor: a page body and a layout reading a
# query value, a page reading a db row, and the built-in fallback layout's nav.
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use Encode     qw(decode encode);
use File::Path qw(make_path);
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

binmode Test::More->builder->$_, ':encoding(UTF-8)'
    for qw(output failure_output todo_output);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# Each passes unchanged: no scheme, or an allowed one in any case.
my @ALLOWED = (
    [ 'https with a query', 'https://example.test/a?b=1&c="2"' ],
    [ 'http',               'http://example.test/' ],
    [ 'mixed-case HTTPS',   'HTTPS://EXAMPLE.TEST/' ],
    [ 'mailto',             'mailto:someone@example.test?subject=Hi there' ],
    [ 'tel',                'tel:+44 1234 567890' ],
    [ 'an absolute path',   '/members/list?page=2' ],
    [ 'a relative path',    'docs/next-page' ],
    [ 'a relative path with a later colon', './notes/10:30' ],
    [ 'a query only',                       '?q=<b>' ],
    [ 'a fragment only',                    '#section-2' ],
    [ 'protocol-relative',                  '//cdn.example.test/x.js' ],
    [ 'an apostrophe in a path',            q(/o'brien) ],
);

# Each becomes `#`.
my @DANGEROUS = (
    [ 'javascript:',                   'javascript:alert(1)' ],
    [ 'mixed-case javascript:',        'JaVaScRiPt:alert(1)' ],
    [ 'data:',                         'data:text/html,<script>alert(1)</script>' ],
    [ 'vbscript:',                     'vbscript:msgbox(1)' ],
    [ 'file:',                         'file:///etc/passwd' ],
    [ 'leading whitespace',            "  \tjavascript:alert(1)" ],
    [ 'a leading control character',   "\x01javascript:alert(1)" ],
    [ 'a tab and newline inside',      "java\tscr\nipt:alert(1)" ],
    [ 'a decimal character reference', '&#106;avascript:alert(1)' ],
    [ 'a hex character reference',     '&#x6A;avascript:alert(1)' ],
    [ 'a reference with no semicolon', '&#0000106avascript:alert(1)' ],
    [ 'a named colon reference',       'javascript&colon;alert(1)' ],
    [ 'a referenced tab inside',       'jav&#x09;ascript:alert(1)' ],
    [ 'percent-encoding',              'java%73cript:alert(1)' ],
    [ 'percent-encoded first letter',  '%6Aavascript:alert(1)' ],
    [ 'an unlisted scheme',            'ftp://example.test/file' ],
);

# The test's OWN unescape, deliberately not the processor's.
sub unesc {
    my $s = shift;
    $s =~ s/&#(\d+);/chr $1/ge;
    $s =~ s/&#x([0-9a-fA-F]+);/chr hex $1/ge;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&amp;/&/g;                          # last
    return $s;
}

# What the stash makes of a value (as t/unit/processor/88 spells it): the five
# HTML characters, then brackets, backslash and C0 controls as references.
sub stash_esc {
    my $s = shift;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    $s =~ s/\[/&#91;/g;
    $s =~ s/\]/&#93;/g;
    $s =~ s/\\/&#92;/g;
    $s =~ s/([\x00-\x1f])/'&#' . ord($1) . ';'/ge;
    return $s;
}

sub qs_for {
    my ($raw) = @_;
    my $b = encode( 'UTF-8', $raw );
    $b =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge;
    return "u=$b";
}

sub fetch {
    my ( $docroot, $uri, $qs ) = @_;
    my $out = run_processor( $docroot, $uri, QUERY_STRING => $qs // '' ) // '';
    my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
    return decode( 'UTF-8', $body // '' );
}

sub href_of {
    my ( $html, $id ) = @_;
    my ($v) = $html =~ m{<a id="\Q$id\E" href="([^"]*)"};
    return $v;
}

# --- A query value, in a page body and in a layout --------------------------
my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path("$docroot/lazysite/layouts/links");
spit( "$docroot/lazysite/layouts/links/layout.tt", <<'TT' );
<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>
<a id="L" href="[% query.u | url_safe %]">layout</a>
<a id="LP" href="[% params.u | url_safe %]">layout params</a>
[% content %]
</body></html>
TT
spit( "$docroot/lazysite/lazysite.conf",
    "site_name: Test\nsite_url: http://localhost\nlayout: links\n" );
spit( "$docroot/go.md", "---\ntitle: Go\nquery_params:\n  - u\n---\n\n"
        . qq(<a id="B" href="[% query.u | url_safe %]">body</a>\n\n)
        . qq(<a id="A" href="[% "&#106;avascript:alert(1)" | url_safe %]">author literal</a>\n\n)
        . qq(<a id="R" href="[% "/plain/path" | url_safe %]">author relative</a>\n) );

for my $v (@ALLOWED) {
    my ( $label, $raw ) = @$v;
    my $html = fetch( $docroot, '/go', qs_for($raw) );
    for my $id (qw(B L LP)) {
        my $got = href_of( $html, $id );
        ok( defined $got && $got ne '#', "$label ($id): passes" ) or next;
        like( $html, qr{<a id="\Q$id\E" href="[^"]*">}, "$label ($id): cannot leave the attribute" );
        is( unesc($got), $raw, "$label ($id): unchanged - escaped once, not twice" );
        is( $got, stash_esc($raw), "$label ($id): exactly the stash's text - nothing decoded" );
    }
}

for my $v (@DANGEROUS) {
    my ( $label, $raw ) = @$v;
    my $html = fetch( $docroot, '/go', qs_for($raw) );
    is( href_of( $html, $_ ), '#', "$label ($_): becomes #" ) for qw(B L LP);
}

{
    my $html = fetch( $docroot, '/go', '' );
    is( href_of( $html, 'A' ), '#', 'an author literal with a character reference becomes #' );
    is( href_of( $html, 'R' ), '/plain/path', 'an author literal relative path passes' );
    is( href_of( $html, 'B' ), '',            'an absent value is empty, not #' );
}

# --- A db row ----------------------------------------------------------------
SKIP: {
    skip 'DBI/DBD::SQLite/YAML::PP not available', 1
        unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
    require Lazysite::Data::Tables;
    my $dr = site_tempdir();
    setup_minimal_site($dr);
    make_path("$dr/lazysite/db/tables");
    spit( "$dr/lazysite/db/tables/links.yaml",
        "title: Links\npublic: true\nfields:\n  label:\n    type: text\n  url:\n    type: text\n" );
    Lazysite::Data::Tables::apply_schema( $dr, 'links' );
    open my $cf, '>>', "$dr/lazysite/lazysite.conf" or die $!;
    print {$cf} "plugins:\n  - plugins/data.pl\n";
    close $cf;
    my $good = 'https://example.test/?a=1&b=<2>';
    Lazysite::Data::Tables::insert_row( $dr, 'links', { label => 'good', url => $good } );
    Lazysite::Data::Tables::insert_row( $dr, 'links', { label => 'evil', url => 'JavaScript:alert(document.cookie)' } );
    Lazysite::Data::Tables::insert_row( $dr, 'links', { label => 'img', url => 'data:image/svg+xml,<svg onload=alert(1)>' } );
    spit( "$dr/list.md", "---\ntitle: List\ntt_page_var:\n  rows: db:links\n---\n\n"
            . qq([% FOREACH r IN rows %]<a id="D-[% r.label %]" href="[% r.url | url_safe %]">[% r.label %]</a>\n[% END %]\n) );
    my $html = fetch( $dr, '/list', '' );
    my $g    = href_of( $html, 'D-good' );
    ok( defined $g, 'db: the safe row rendered' );
    is( unesc( $g // '' ), $good, 'db: an https row passes unchanged - escaped once, not twice' );
    is( $g, stash_esc($good), "db: exactly the stash's text - nothing decoded" );
    is( href_of( $html, 'D-evil' ), '#', 'db: a javascript: row becomes #' );
    is( href_of( $html, 'D-img' ),  '#', 'db: a data: row becomes #' );
}

# --- The built-in fallback layout's nav --------------------------------------
{
    my $fr = site_tempdir();
    setup_minimal_site($fr);
    spit( "$fr/lazysite/nav.conf", "Home | /\nEvil | javascript:alert(1)\n" );
    my $html = fetch( $fr, '/', '' );
    like( $html, qr{<a href="/" class="nav-link"}, 'fallback nav: a site path passes' );
    like( $html, qr{<a href="#" class="nav-link"[^>]*>Evil</a>}, 'fallback nav: a javascript: entry becomes #' );
    unlike( $html, qr/href="javascript:/i, 'fallback nav: no javascript: link survives' );
}

done_testing();
