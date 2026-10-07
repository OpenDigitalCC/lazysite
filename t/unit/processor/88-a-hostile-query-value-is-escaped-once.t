#!/usr/bin/perl
# SM869: a hostile query value reaches the page escaped ONCE, by every path.
#
# THE FILING'S ORDER, followed: this test was written first, against the code
# before the refactor, with what failed then marked TODO and the reason given -
# so the commit that added it records the measured "before". The refactor moved
# the escape out of parse_query_string and into the stash build, and left
# %RENDER_QUERY raw for the engine; this is the test that fails if the escape
# lands in the wrong place.
#
# ONE ASSERTION SHAPE FOR EVERY PATH, and it is the reader's, not the code's:
#
#   safe       the emitted text cannot open a tag (text context) or leave the
#              attribute (attribute context)
#   once       HTML-unescaping what was emitted gives back EXACTLY what the
#              visitor sent - which is what a browser displays. Escaped twice
#              decodes to entity text; escaped zero times is not safe.
#
# Every value below changes under HTML escaping. SM868's lesson: a fixture made
# of alphanumerics is a fixed point of the transform and cannot detect it.
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Encode     qw(decode encode);
use File::Copy qw(copy);
use File::Path qw(make_path);
use TestHelper qw(setup_minimal_site run_processor site_tempdir repo_root);

our $TODO;

binmode Test::More->builder->$_, ':encoding(UTF-8)'
    for qw(output failure_output todo_output);

# The values. Each is [ label, raw value as the visitor means it, query-string
# spelling ]. The spelling is percent-encoded from the raw value unless given.
my @VALUES = (
    [ 'a script element',                        '<script>alert(1)</script>' ],
    [ 'an attribute breakout',                   '"><img src=x onerror=alert(1)>' ],
    [ 'a single quote',                          q(it's) ],
    [ 'an entity, which must stay text',         '&amp;' ],
    [ 'a URL-encoded tag, decoded once',         '<script>',     'x=%3Cscript%3E' ],
    [ 'a double-encoded tag, decoded only once', '%3Cscript%3E', 'x=%253Cscript%253E' ],
    [ 'template syntax',                         '[% 7 * 7 %] [% site_name %]' ],
    [ 'unicode',                                 'café ✓ 日本 – Ω' ],
);

sub qs_for {
    my ( $raw, $spelled ) = @_;
    return $spelled if defined $spelled;
    my $b = encode( 'UTF-8', $raw );
    $b =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord $1)/ge;
    return "x=$b";
}

# The test's OWN escape and unescape, deliberately not the processor's.
sub esc {
    my $s = shift;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

sub unesc {
    my $s = shift;
    $s =~ s/&#(\d+);/chr $1/ge;
    $s =~ s/&#x([0-9a-fA-F]+);/chr hex $1/ge;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&amp;/&/g;    # last, so &amp;lt; decodes to &lt; and no further
    return $s;
}

my $docroot = site_tempdir();
setup_minimal_site($docroot);

# A layout that interpolates the value both ways, so the layout path is driven
# as well as the page body.
make_path("$docroot/lazysite/layouts/hostile");
open my $lt, '>', "$docroot/lazysite/layouts/hostile/layout.tt" or die $!;
print {$lt} <<'TT';
<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>
<div id="L1">[% query.x %]</div>
<div id="L2">[% query.x | html %]</div>
<div id="L3" data-v="[% query.x %]"></div>
[% content %]
</body></html>
TT
close $lt;
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: SITE-NAME-LEAKED\nsite_url: http://localhost\nlayout: hostile\n";
close $cf;

# A file a visitor must not be able to pull into a page by naming it.
open my $sf, '>', "$docroot/partial-secret.md" or die $!;
print {$sf} "PARTIAL-SECRET-TEXT\n";
close $sf;

my $BODY = <<'MD';
<div id="B1">[% query.x %]</div>

<div id="B2">[% query.x | html %]</div>

<div id="B3">[% params.x %]</div>

<div id="B4" data-v="[% query.x %]"></div>

<div id="UND">[% query.y %]</div>
MD

my $n = 0;

sub write_page {
    my ( $fm, $body ) = @_;
    my $slug = 'case' . ++$n;
    open my $fh, '>', "$docroot/$slug.md" or die $!;
    print {$fh} "---\ntitle: Case\n$fm---\n\n$body";
    close $fh;
    return "/$slug";
}

sub fetch {
    my ( $uri, $qs, %env ) = @_;
    my $out = run_processor( $docroot, $uri, QUERY_STRING => $qs, %env ) // '';
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    $body //= '';
    return ( decode( 'UTF-8', $head // '' ), decode( 'UTF-8', $body ) );
}

sub segment {
    my ( $html, $re ) = @_;
    my ($s) = $html =~ $re;
    return $s;
}

# safe + once, for a TEXT context.
sub text_ok {
    my ( $seg, $raw, $what ) = @_;
    ok( defined $seg, "$what: rendered" ) or return;
    unlike( $seg, qr/</, "$what: cannot open a tag" );
    is( unesc($seg), $raw, "$what: escaped exactly once" );
}

# safe + once, for a double-quoted ATTRIBUTE context.
sub attr_ok {
    my ( $seg, $raw, $what ) = @_;
    ok( defined $seg, "$what: rendered" ) or return;
    unlike( $seg, qr/"/, "$what: cannot leave the attribute" );
    is( unesc($seg), $raw, "$what: escaped exactly once" );
}

# A `| html` filter on a value that is ALREADY escaped in the stash escapes it
# again. Safe, and the reader sees entity text - which is why the shipped pages
# no longer filter query values (SM869), and why the docs say not to.
sub filtered_ok {
    my ( $seg, $raw, $what ) = @_;
    ok( defined $seg, "$what: rendered" ) or return;
    unlike( $seg, qr/</, "$what: cannot open a tag" );
    is( unesc($seg), esc($raw),
        "$what: escaped twice - the stash escaped it and so did the filter" );
}

# --- The stash: page body, page body `| html`, params.*, layout ------------
for my $v (@VALUES) {
    my ( $label, $raw, $spelled ) = @$v;
    my $qs = qs_for( $raw, $spelled );
    subtest "the stash: $label" => sub {
        my $uri = write_page( "query_params:\n  - x\n", $BODY );
        my ( undef, $html ) = fetch( $uri, $qs );
        text_ok( segment( $html, qr{<div id="B1">(.*?)</div>}s ), $raw,
            'page body [% query.x %]' );
        filtered_ok( segment( $html, qr{<div id="B2">(.*?)</div>}s ), $raw,
            'page body [% query.x | html %]' );
        text_ok( segment( $html, qr{<div id="B3">(.*?)</div>}s ), $raw,
            'page body [% params.x %]' );
        attr_ok( segment( $html, qr{<div id="B4" data-v="([^"]*)"}s ), $raw,
            'page body attribute' );
        text_ok( segment( $html, qr{<div id="L1">(.*?)</div>}s ), $raw,
            'layout [% query.x %]' );
        filtered_ok( segment( $html, qr{<div id="L2">(.*?)</div>}s ), $raw,
            'layout [% query.x | html %]' );
        attr_ok( segment( $html, qr{<div id="L3" data-v="([^"]*)"}s ), $raw,
            'layout attribute' );
        is( segment( $html, qr{<div id="UND">(.*?)</div>}s ), '',
            'an undeclared parameter reaches nothing' );
        unlike( $html, qr/SITE-NAME-LEAKED.*SITE-NAME-LEAKED/s,
            'a template tag in the value is not evaluated against the stash' );
        unlike( $html, qr/\b49\b/, 'and computes nothing' );
    };
}

# --- raw: true and api: true pages, which skip the layout ------------------
for my $v (@VALUES) {
    my ( $label, $raw, $spelled ) = @$v;
    my $qs = qs_for( $raw, $spelled );
    subtest "raw and api pages: $label" => sub {
        my $r = write_page( "raw: true\nquery_params:\n  - x\n",
            qq(<div id="R1">[% query.x %]</div>\n) );
        my ( undef, $html ) = fetch( $r, $qs );
        text_ok( segment( $html, qr{<div id="R1">(.*?)</div>}s ), $raw, 'raw: true page' );

        my $a = write_page( "api: true\nquery_params:\n  - x\n",
            qq({"v":"[% query.x %]"}\n) );
        my ( undef, $json ) = fetch( $a, $qs );
        text_ok( segment( $json, qr{\{"v":"(.*?)"\}}s ), $raw, 'api: true page' );
    };
}

# --- The form prefill sink: attribute and textarea --------------------------
#
# The value is inserted into the page body BEFORE the body is rendered as a
# template, so this sink's context is "HTML that TT will read": a live `[%` in
# what it emits would be evaluated with the visitor's text as the template.
my $FORM = <<'MD';
:::form
x | Code | prefill:x
note | Note | textarea prefill:x
:::
MD

for my $v (@VALUES) {
    my ( $label, $raw, $spelled ) = @$v;
    my $qs = qs_for( $raw, $spelled );
    subtest "the form prefill sink: $label" => sub {
        my $uri = write_page( "form: apply\nquery_params:\n  - x\n", $FORM );
        my ( undef, $html ) = fetch( $uri, $qs );
        local $TODO = $raw =~ /\[%/
            ? 'BEFORE (measured): the prefilled value is inserted ahead of the '
            . 'body\'s template pass, and nothing makes [% inert - TT evaluates it'
            : undef;
        attr_ok( segment( $html, qr{<input[^>]*name="x"[^>]*\svalue="([^"]*)"}s ), $raw,
            'prefill attribute' );
        text_ok( segment( $html, qr{<textarea[^>]*name="note"[^>]*>(.*?)</textarea>}s ), $raw,
            'prefill textarea' );
        unlike( $html, qr/\b49\b|SITE-NAME-LEAKED.*SITE-NAME-LEAKED/s,
            'a template tag in a prefilled value computes nothing' );
    };
}

# --- The form outcome banner, which reads QUERY_STRING itself ---------------
for my $v (@VALUES) {
    my ( $label, $raw, $spelled ) = @$v;
    ( my $o = qs_for( $raw, $spelled ) ) =~ s/\Ax=//;
    subtest "the form outcome banner: $label" => sub {
        my $uri = write_page( "form: apply\n", "::: form\nname | Name |\n:::\n" );
        my ( undef, $html ) = fetch( $uri, "form=apply&outcome=$o" );
        local $TODO
            = $raw =~ /\[%/
            ? 'BEFORE (measured): the banner is inserted ahead of the body\'s '
            . 'template pass, and nothing makes [% inert - TT evaluates it'
            : $raw =~ /[^\x00-\x7f]/
            ? 'BEFORE (measured): the banner percent-decodes to bytes and never '
            . 'decodes UTF-8, so a non-ASCII outcome arrives as mojibake'
            : undef;
        text_ok( segment( $html, qr{<p class="form-status form-status-error" role="alert">(.*?)</p>}s ),
            $raw, 'outcome banner' );
        unlike( $html, qr/\b49\b|SITE-NAME-LEAKED.*SITE-NAME-LEAKED/s,
            'a template tag in the outcome computes nothing' );
    };
}

# --- The form's own path, which must not take the query ---------------------
subtest 'the form _page field carries the path and nothing from the query' => sub {
    my $uri = write_page( "form: apply\nquery_params:\n  - x\n", $FORM );
    my ( undef, $html ) = fetch( $uri, qs_for('"><script>alert(1)</script>') );
    like( $html, qr{name="_page" value="\Q$uri\E"}, '_page is the page path, exactly' );
};

# --- A value cannot name a file for the second include pass -----------------
#
# The body's template output is scanned once more for `::: include` blocks
# whose path held a template variable. A value carrying newlines and a fence
# is not touched by HTML escaping, so this is checked rather than assumed.
subtest 'a value cannot become an include directive' => sub {
    my $uri = write_page( "query_params:\n  - x\n", "[% query.x %]\n" );
    my ( undef, $html ) = fetch( $uri, qs_for("\n::: include\n/partial-secret.md\n:::\n") );
    local $TODO = 'BEFORE (measured): the second include pass reads the body '
        . 'AFTER the template pass, so a query value printed at the start of a '
        . 'line can name a file to include';
    unlike( $html, qr/PARTIAL-SECRET-TEXT/, 'the named file is not included' );
};

# --- The shipped pages that print a query value -----------------------------
subtest 'the shipped login page carries next= once' => sub {
    copy( repo_root() . '/starter/lazysite/templates/system/login.md', "$docroot/login.md" )
        or die "copy login.md: $!";
    my $raw = '/members?a=1&b="2"';
    my ( undef, $html ) = fetch( '/login', 'next=' . substr( qs_for($raw), 2 ) );
    local $TODO = 'BEFORE (measured): login.md filters an already-escaped value '
        . 'through | html, so next= posts back as entity text';
    attr_ok( segment( $html, qr{<input type="hidden" name="next" value="([^"]*)"} ), $raw,
        'the hidden next field' );
    text_ok( segment( $html, qr{<span class="login-context-url">(.*?)</span>}s ), $raw,
        'the visible next text' );
};

subtest 'the shipped claim page carries u= and c= once' => sub {
    copy( repo_root() . '/starter/lazysite/templates/system/claim.md', "$docroot/claim.md" )
        or die "copy claim.md: $!";
    my $u = q(o'brien&co);
    my $c = 'tok<en>';
    my ( undef, $html ) = fetch( '/claim',
        'u=' . substr( qs_for($u), 2 ) . '&c=' . substr( qs_for($c), 2 ) );
    local $TODO = 'BEFORE (measured): claim.md filters already-escaped values '
        . 'through | html';
    attr_ok( segment( $html, qr{<input type="hidden" name="username" value="([^"]*)"} ), $u,
        'the hidden username field' );
    attr_ok( segment( $html, qr{<input type="hidden" name="claim" value="([^"]*)"} ), $c,
        'the hidden claim field' );
};

# --- An alias redirect carries the query on, and its body is escaped --------
subtest 'an alias redirect' => sub {
    open my $m, '>', "$docroot/lazysite/aliases.json" or die $!;
    print {$m} '{"/old":"/case1"}';
    close $m;
    my ( $head, $html ) = fetch( '/old', qq(x="><script>alert(1)</script>\r\nX-Evil: 1) );
    like( $head, qr/Status:\s*301/, 'redirected' );
    unlike( $head, qr/^X-Evil:/m, 'no header can be injected through the query' );
    unlike( $html, qr/<script>/,  'the body link cannot open a tag' );
    unlike( $html, qr/href="[^"]*"[^>]*><script/, 'nor leave its attribute' );
};

done_testing();
