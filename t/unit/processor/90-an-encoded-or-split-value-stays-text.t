#!/usr/bin/perl
# SM869 adversarial review, second pass (n271): a query value in an unusual
# ENCODING, SPLIT across two parameters, or meeting a page that changes the
# template TAGS, reaches every sink as text - and an `api:` page stays JSON.
#
# t/unit/processor/88 drove eight value shapes through every sink; the first
# review pass stopped before the encoding variants, split template syntax, TAGS
# and the api: JSON context (docs/review/2026-10-07-sm869-adversarial-review.md,
# "What was not covered"). This test is those classes.
#
# THE ASSERTION IS STRUCTURAL, not about running anything. The payloads carry an
# inert marker element `<m>` and a marker computation `7 * 7`; the reader's
# property is:
#
#   no element     the marker element never appears, and a text segment cannot
#                  open a tag; an attribute segment cannot leave its quotes
#   no evaluation  `49` never appears, and the site's name is never pulled in
#   still a page   the request answers 200, and an api page is valid JSON
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Encode     qw(decode encode);
use File::Path qw(make_path);
use JSON::PP   ();
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

binmode Test::More->builder->$_, ':encoding(UTF-8)'
    for qw(output failure_output todo_output);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# Percent-encode BYTES (a character string is UTF-8 encoded first).
sub enc {
    my $s = shift;
    $s = encode( 'UTF-8', $s ) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf( '%%%02X', ord $1 )/ge;
    return $s;
}

sub unesc {
    my $s = shift;
    $s =~ s/&#(\d+);/chr $1/ge;
    $s =~ s/&#x([0-9a-fA-F]+);/chr hex $1/ge;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

my $SITE = 'SITE-NAME-7713';
my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path("$docroot/lazysite/layouts/probe");
spit( "$docroot/lazysite/layouts/probe/layout.tt", <<'TT' );
<!DOCTYPE html><html><head><title>t</title></head><body>
<div id="L1">[% query.x %]</div>
<div id="L3" data-v="[% query.x %]"></div>
[% content %]
</body></html>
TT
spit( "$docroot/lazysite/lazysite.conf", "site_name: $SITE\nsite_url: http://localhost\nlayout: probe\n" );
spit( "$docroot/secret-part.txt", "SECRET-PART-TEXT\n" );

spit( "$docroot/body.md", "---\ntitle: Body\nquery_params:\n  - x\n---\n\n"
        . qq(<div id="B1">[% query.x %]</div>\n\n<div id="B4" data-v="[% query.x %]"></div>\n) );
spit( "$docroot/rawp.md", "---\nraw: true\nquery_params:\n  - x\n---\n\n<div id=\"R1\">[% query.x %]</div>\n" );
spit( "$docroot/apip.md", "---\napi: true\nquery_params:\n  - x\n---\n{\"v\":\"[% query.x %]\"}\n" );
spit( "$docroot/formp.md", "---\ntitle: Form\nform: apply\nquery_params:\n  - x\n---\n\n"
        . ":::form\ncode | Code | prefill:x\nnote | Note | textarea prefill:x\n:::\n" );
spit( "$docroot/ban.md", "---\ntitle: Ban\nform: apply\n---\n\n::: form\nname | Name |\n:::\n" );

sub fetch {
    my ( $uri, $qs ) = @_;
    my $out = run_processor( $docroot, $uri, QUERY_STRING => $qs ) // '';
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    $head //= '';
    $body //= '';
    my $b = eval { decode( 'UTF-8', $body, Encode::FB_CROAK ) } // $body;
    return ( $head, $b );
}

sub seg { my ( $html, $re ) = @_; my ($s) = $html =~ $re; return $s }

sub page_ok {
    my ( $head, $html, $what ) = @_;
    unlike( $head, qr/^Status:\s*[45]/m, "$what: answered, not an error" );
    unlike( $html, qr/<m\b/i,          "$what: no marker element" );
    unlike( $html, qr/\b49\b/,         "$what: nothing computed" );
    unlike( $html, qr/\Q$SITE\E/,      "$what: the site's name is not pulled in" );
    unlike( $html, qr/SECRET-PART-TEXT/, "$what: no file included" );
}

sub text_ok {
    my ( $s, $what ) = @_;
    ok( defined $s, "$what: rendered" ) or return;
    unlike( $s, qr/</, "$what: cannot open a tag" );
}

sub attr_ok {
    my ( $s, $what ) = @_;
    ok( defined $s, "$what: rendered" ) or return;
    unlike( $s, qr/["<>]/, "$what: cannot leave the attribute" );
}

# api: true - the body must still parse as JSON, and the value must decode
# (JSON, then the HTML escape it carries) back to what was sent, when given.
sub json_ok {
    my ( $json, $raw, $what ) = @_;
    my $d = eval { JSON::PP->new->decode($json) };
    ok( ref $d eq 'HASH', "$what: the api page is valid JSON" )
        or return diag( "got: " . join '', map { sprintf( ord($_) < 32 ? '\\x%02x' : '%s', ord($_) < 32 ? ord $_ : $_ ) } split //, $json );
    unlike( $d->{v}, qr/</, "$what: the value cannot open a tag" );
    is( unesc( $d->{v} ), shown($raw), "$what: the value decodes to what was sent" ) if defined $raw;
}

# What a reader is shown for a value: the value, except that a NUL - which an
# HTML parser replaces with U+FFFD anyway - is shown as U+FFFD.
sub shown { my $s = shift; return undef unless defined $s; $s =~ s/\0/\x{FFFD}/g; return $s }

# Every sink, for one query string. $raw is the value as the processor should
# see it (after ONE percent-decode), or undef where it is not a character string.
sub every_sink {
    my ( $qs, $raw, $label ) = @_;
    subtest "every sink: $label" => sub {
        my ( $h, $html ) = fetch( '/body', $qs );
        page_ok( $h, $html, 'page' );
        text_ok( seg( $html, qr{<div id="B1">(.*?)</div>}s ), 'page body text' );
        attr_ok( seg( $html, qr{<div id="B4" data-v="([^"]*)"}s ), 'page body attribute' );
        text_ok( seg( $html, qr{<div id="L1">(.*?)</div>}s ), 'layout text' );
        attr_ok( seg( $html, qr{<div id="L3" data-v="([^"]*)"}s ), 'layout attribute' );

        ( $h, $html ) = fetch( '/rawp', $qs );
        page_ok( $h, $html, 'raw page' );
        text_ok( seg( $html, qr{<div id="R1">(.*?)</div>}s ), 'raw page text' );

        ( $h, $html ) = fetch( '/apip', $qs );
        unlike( $h, qr/^Status:\s*[45]/m, 'api page: answered' );
        json_ok( $html, $raw, 'api page' );

        ( $h, $html ) = fetch( '/formp', $qs );
        page_ok( $h, $html, 'form page' );
        attr_ok( seg( $html, qr{<input[^>]*name="code"[^>]*\svalue="([^"]*)"}s ), 'prefill attribute' );
        text_ok( seg( $html, qr{<textarea[^>]*name="note"[^>]*>(.*?)</textarea>}s ), 'prefill textarea' );

        ( my $o = $qs ) =~ s/\Ax=//;
        ( $h, $html ) = fetch( '/ban', "form=apply&outcome=$o" );
        page_ok( $h, $html, 'banner page' );
        my $ban = seg( $html, qr{<p class="form-status form-status-error" role="alert">(.*?)</p>}s );
        # SM1124 F-3: the outcome is a code and is never printed; whatever the
        # value, the banner is the one generic sentence.
        is( $ban, 'Your submission could not be accepted. Please try again.',
            'the outcome banner is the generic sentence, not the value' );
    };
}

# --- 1. Encoding variants ----------------------------------------------------

# Percent-encoded twice: decoded ONCE, so the second layer stays text.
every_sink( 'x=%253Cm%253E',                                  '%3Cm%3E',          'a tag, percent-encoded twice' );
every_sink( 'x=%255B%2525%25207%2520*%25207%2520%2525%255D',  '%5B%25%207%20*%207%20%25%5D', 'template syntax, percent-encoded twice' );

# HTML entity forms of <, [ and %: the & is escaped, so they display as typed.
every_sink( 'x=' . enc('&lt;m&gt; &#60;m&#62; &#x3c;m&#x3e;'), '&lt;m&gt; &#60;m&#62; &#x3c;m&#x3e;', 'entity forms of <' );
every_sink( 'x=' . enc('&#91;% 7 * 7 %&#93; &#x5b;% site_name %&#x5d;'),
    '&#91;% 7 * 7 %&#93; &#x5b;% site_name %&#x5d;', 'entity forms of [' );
every_sink( 'x=' . enc('[&#37; 7 * 7 &#37;] [&percnt; site_name &percnt;]'),
    '[&#37; 7 * 7 &#37;] [&percnt; site_name &percnt;]', 'entity forms of %' );

# A lone CR, carrying an include block and a tag.
every_sink( 'x=' . enc("a\r::: include\r/secret-part.txt\r:::\r<m>"),
    "a\r::: include\r/secret-part.txt\r:::\r<m>", 'a lone CR' );

# U+2028 / U+2029, the line and paragraph separators.
every_sink( 'x=' . enc("a\x{2028}::: include\x{2029}/secret-part.txt\x{2028}:::\x{2029}<m>[% 7 * 7 %]"),
    "a\x{2028}::: include\x{2029}/secret-part.txt\x{2028}:::\x{2029}<m>[% 7 * 7 %]", 'U+2028 and U+2029' );

# NUL, alone and spelling an engine placeholder.
# BEFORE (measured): the api page carried the NUL raw, which is not JSON; and a
# value spelling convert_p_links' NUL placeholder pulled a protected tag (the
# layout's own <script>) into the text. SM966: NUL is U+FFFD in a data value.
every_sink( 'x=' . enc("a\0<m>\0b"), "a\0<m>\0b", 'NUL' );
every_sink( 'x=' . enc("\0RAW0\0 \0RAW1\0"), "\0RAW0\0 \0RAW1\0", 'NUL spelling an engine placeholder' );

# Invalid UTF-8 bytes, around a tag and a template tag.
every_sink( 'x=%FF%FE%3Cm%3E%C3%28%5B%25%207%20*%207%20%25%5D', undef, 'invalid UTF-8' );

# --- 3. Attribute contexts: a space or `>` cannot add an attribute -----------
#
# The shipped starter tree places no template value in an UNQUOTED attribute
# (t/lint/212 holds that); a value with a space or `>` in a quoted one stays in it.
every_sink( 'x=' . enc('a onmouseover=m b>c'), 'a onmouseover=m b>c', 'a space and > in an attribute' );

# --- 4. Template syntax split across two parameters --------------------------
spit( "$docroot/split.md", "---\ntitle: Split\nform: apply\nquery_params:\n  - x\n  - y\n---\n\n"
        . qq(<div id="S1">[% query.x %][% query.y %]</div>\n\n)
        . ":::form\na | A | prefill:x\nb | B | prefill:y\nc | C | textarea prefill:x\nd | D | textarea prefill:y\n:::\n" );
spit( "$docroot/splitraw.md", "---\nraw: true\nquery_params:\n  - x\n  - y\n---\n\n<div id=\"S1\">[% query.x %][% query.y %]</div>\n" );
for my $pair ( [ '[', '% 7 * 7 %]' ], [ '[% site_name ', '%]' ], [ '[%', ' 7 * 7 %]' ] ) {
    my ( $x, $y ) = @$pair;
    my $qs = 'x=' . enc($x) . '&y=' . enc($y);
    subtest "split across two parameters: '$x' + '$y'" => sub {
        for my $u ( '/split', '/splitraw' ) {
            my ( $h, $html ) = fetch( $u, $qs );
            page_ok( $h, $html, $u );
            my $s = seg( $html, qr{<div id="S1">(.*?)</div>}s );
            is( unesc( $s // '' ), "$x$y", "$u: the two values join as text" );
        }
    };
}

# --- 4. A page that sets TAGS ------------------------------------------------
#
# A pre-template sink (prefill, banner) writes the visitor's text into the body
# BEFORE the body's template pass, and _tt_inert makes `[` and `%` inert - which
# is enough only while the tags are `[% %]`. A page can change them.
for my $style ( [ '{{ }}', '{{ site_name }}{{ 7 * 7 }}' ], [ 'star', '[* site_name *][* 7 * 7 *]' ],
    [ '<+ +>', '<+ site_name +><+ 7 * 7 +>' ] )
{
    my ( $tags, $v ) = @$style;
    my $slug = 'tags-' . unpack( 'H*', $tags );
    spit( "$docroot/$slug.md", "---\ntitle: Tags\nform: apply\nquery_params:\n  - x\n---\n\n"
            . "[% TAGS $tags %]\n\n:::form\ncode | Code | prefill:x\nnote | Note | textarea prefill:x\n:::\n" );
    # BEFORE (measured): with TAGS {{ }}, the prefill and the banner evaluated
    # `{{ site_name }}` - the site's name was prefilled. SM968: a body's TAGS is a
    # comment. star and <+ +> were already inert: `[` and `<` are encoded.
    subtest "a page that sets TAGS $tags" => sub {
        my ( $h, $html ) = fetch( "/$slug", 'x=' . enc($v) );
        page_ok( $h, $html, 'prefill' );
        is( unesc( seg( $html, qr{<input[^>]*name="code"[^>]*\svalue="([^"]*)"}s ) // '' ), $v,
            'the prefill attribute shows the value as sent' );
        is( unesc( seg( $html, qr{<textarea[^>]*name="note"[^>]*>(.*?)</textarea>}s ) // '' ), $v,
            'the prefill textarea shows the value as sent' );
        ( $h, $html ) = fetch( "/$slug", 'form=apply&outcome=' . enc($v) );
        page_ok( $h, $html, 'banner' );
    };
}

# --- The outcome banner is never the page's ---------------------------------
#
# BEFORE (measured): a request carrying form=&outcome= on a cold cache wrote its
# banner into the page cache, and the next visitor - with no query at all - was
# shown it, in the alert style. SM969.
spit( "$docroot/ban2.md", "---\ntitle: Ban2\nform: apply\n---\n\n::: form\nname | Name |\n:::\n" );
subtest 'a visitor\'s outcome is not shown to the next visitor' => sub {
    my ( undef, $first ) = fetch( '/ban2', 'form=apply&outcome=too-fast' );
    like( $first, qr/That was too quick/, 'the visitor sees their own outcome' );
    my ( undef, $next ) = fetch( '/ban2', '' );
    unlike( $next, qr/That was too quick/, 'the next visitor, with no query, does not' );
    unlike( $next, qr/form-status-error/, 'and sees no banner at all' );
    my ( undef, $other ) = fetch( '/ban2', 'form=apply&outcome=SECOND' );
    like( $other, qr/could not be accepted/, 'a later outcome is shown, not the cached page' );
};

# --- 5. api: true - a value cannot make the JSON invalid ---------------------
#
# BEFORE (measured): a backslash, a tab, a control character or NUL reached the
# JSON string raw and the response did not parse. SM966: they are character
# references in a data value, as a line break already was.
for my $v ( [ 'a trailing backslash', 'a\\' ], [ 'a backslash before a quote', 'a\\"b' ],
    [ 'a control character', "a\x01b" ], [ 'a tab', "a\tb" ], [ 'a line break', "a\nb\r" ],
    [ 'NUL', "a\0b" ], [ 'U+2028', "a\x{2028}b" ], [ 'DEL', "a\x7fb" ] )
{
    my ( $label, $raw ) = @$v;
    subtest "an api page: $label" => sub {
        my ( $h, $json ) = fetch( '/apip', 'x=' . enc($raw) );
        unlike( $h, qr/^Status:\s*[45]/m, 'answered' );
        json_ok( $json, $raw, 'api page' );
    };
}

done_testing();
