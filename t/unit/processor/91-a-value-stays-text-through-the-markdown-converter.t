#!/usr/bin/perl
# SM869 adversarial review, second pass (n271): a query value that meets the
# Markdown converter - beside a code span, beside an autolink, spelling a link or
# a reference-link label, or spelling one of the engine's own placeholders - is
# still text in the page.
#
# The order matters and is the reason for the test. The page body is converted
# from Markdown BEFORE the template pass, so a stash value is never itself read
# as Markdown - but three things read the output AFTER it: the code-span restore
# in render_content, and convert_dt_links/convert_p_links over the whole page.
# And the form prefill and outcome banner are written into the body BEFORE the
# converter, so their text is read by it.
#
# The payloads are inert: a marker link target `javascript:void`, the engine's
# placeholder words. The assertion is structural: no new element.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub enc  { my $s = shift; $s =~ s/([^A-Za-z0-9\-_.~])/sprintf( '%%%02X', ord $1 )/ge; return $s }
sub seg  { my ( $html, $re ) = @_; my ($s) = $html =~ $re; return $s }
sub count { my ( $html, $re ) = @_; return scalar( () = $html =~ /$re/g ) }
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

our $TODO;
my $TODO_BANNER = 'n271 before: the outcome banner is written to the page cache, and can spell a placeholder';

my $docroot = site_tempdir();
setup_minimal_site($docroot);

spit( "$docroot/md.md", <<'MD' );
---
title: Md
query_params:
  - x
---

Inline `literal [% query.x %]` code, then <div id="V1">[% query.x %]</div>

See <http://example.com/auto> and <div id="V2">[% query.x %]</div>

[Go](/next?q=[% query.x %]) and a [reference link][ref].

<dl><dt>[% query.x %]</dt><dd>d</dd></dl>

[ref]: http://example.com/ref
MD

sub fetch {
    my ( $uri, $qs ) = @_;
    my $out = run_processor( $docroot, $uri, QUERY_STRING => $qs ) // '';
    my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
    return $body // '';
}

# The page with an ordinary value, as the baseline for counting elements.
my $base     = fetch( '/md', 'x=plain' );
my $codes    = count( $base, qr/<code\b/ );
my $anchors  = count( $base, qr/<a\b/ );
is( $codes, 1, 'baseline: one code span' );
like( $base, qr{<a href="http://example\.com/auto">}, 'baseline: the autolink' );
like( $base, qr{<a href="/next\?q=plain">Go</a>},      'baseline: the author link carries the value' );
like( $base, qr{<a href="http://example\.com/ref">},  'baseline: the reference link' );

for my $v (
    # BEFORE (measured): these two became <a href="javascript:void"> - convert_p_links
    # reads the rendered text. SM966: [ and ] are character references in a value.
    [ 'inline link syntax',                 '[m](javascript:void)' ],
    [ 'a reference-link label',             '[m][ref]' ],
    [ 'a full reference link',              '[m] [ref]' ],
    [ 'an autolink',                        '<http://m.example/>' ],
    [ 'a code span',                        '`m`' ],
    # BEFORE (measured): restored as a copy of the page's code span. SM967.
    [ 'the code-span placeholder',          'CODEBLOCK_0_END' ],
    [ 'a link that closes the author link', ') [m](javascript:void' ],
    [ 'a bracket that closes a link label', '](javascript:void)' ],
    )
{
    my ( $label, $raw, $todo ) = @$v;
    local $TODO = $todo;
    subtest "a query value: $label" => sub {
        my $html = fetch( '/md', 'x=' . enc($raw) );
        is( count( $html, qr/<code\b/ ), $codes,   'no code element added' );
        is( count( $html, qr/<a\b/ ),    $anchors, 'no anchor added' );
        unlike( $html, qr/href="javascript/i, 'no javascript: link' );
        unlike( $html, qr{href="http://m\.example}, 'no autolink made from the value' );
        for my $id (qw(V1 V2)) {
            my $s = seg( $html, qr{<div id="$id">(.*?)</div>}s );
            ok( defined $s && $s !~ /</, "$id: the value is text" );
        }
        like( $html, qr{<code>literal \[% query\.x %\]</code>},
            'the author code span is literal and unchanged' );
    };
}

# --- The pre-converter sinks: form prefill and outcome banner ---------------
spit( "$docroot/form.md", <<'MD' );
---
title: Form
form: apply
query_params:
  - x
---

:::form
code | Code | prefill:x
note | Note | textarea prefill:x
:::

<script>var marker = "q";</script>

<!-- an author comment -->
MD

my $fbase = fetch( '/form', 'x=plain' );
is( count( $fbase, qr/var marker/ ), 1, 'baseline: the author script once' );

for my $v (
    # BEFORE (measured): the page's <script> moved into the field, and out of
    # the attribute its quotes ended. SM967.
    [ 'the converter placeholder',   'RAWBLOCK_0_END RAWBLOCK_1_END' ],
    [ 'Markdown emphasis and code',  '`m` *m* _m_ **m**' ],
    [ 'link and reference syntax',   '[m](javascript:void) [m][ref]' ],
    [ 'an autolink',                 '<http://m.example/>' ],
    )
{
    my ( $label, $raw, $todo ) = @$v;
    subtest "a prefilled value: $label" => sub {
        local $TODO = $todo;
        my $html = fetch( '/form', 'x=' . enc($raw) );
        my $ta   = seg( $html, qr{<textarea[^>]*name="note"[^>]*>(.*?)</textarea>}s );
        my $at   = seg( $html, qr{<input[^>]*name="code"[^>]*\svalue="([^"]*)"}s );
        ok( defined $ta && $ta !~ /</, 'the textarea holds text' );
        ok( defined $at && $at !~ /[<"]/, 'the attribute holds text' );
        is( count( $html, qr/var marker/ ), 1, 'the author script is where the author put it, once' );
        like( $html, qr{</form>.*var marker}s, 'and after the form' );
        unlike( $html, qr/href="javascript/i, 'no javascript: link' );

        local $TODO = $TODO_BANNER;
        my $b = fetch( '/form', 'form=apply&outcome=' . enc($raw) );
        my $s = seg( $b, qr{<p class="form-status form-status-error" role="alert">(.*?)</p>}s );
        ok( defined $s && $s !~ /</, 'the outcome banner holds text' );
        is( unesc( $s // '' ), $raw, 'the outcome banner shows THIS request\'s value' );
        is( count( $b, qr/var marker/ ), 1, 'banner: the author script once' );
    };
}

done_testing();
