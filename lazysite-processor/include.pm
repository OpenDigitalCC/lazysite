package main;

# lazysite-processor/include.pm - the processor's include and Markdown passes.
#
# HOLDS   convert_fenced_include() and _resolve_include(): a `::: include` block
#         is replaced by the file or URL it names - a local path confined to the
#         request's content root (or its private twin), never the lazysite/
#         tree, refused when the partial sits under an ACL entry the including
#         page does not (SM898), and recorded as a render dependency;
#         convert_fenced_code, convert_md (Text::MultiMarkdown with script,
#         style and comments held out by a per-call placeholder key,
#         _placeholder_key, SM967) and unwrap_block_html; the TT filters
#         _markdown_filter, _json_filter (SM824) and _url_safe_filter (SM970,
#         with _url_safe_chr and its two scheme tables); convert_dt_links and
#         convert_p_links, the post-render link passes.
# OWNS    what an include may reach; how Markdown becomes HTML; which link
#         schemes `| url_safe` lets through.
# CALLS   fetch_url, read_file, log_event, parse_yaml_front_matter,
#         convert_fenced_divs, convert_oembed, _content_abs,
#         _path_under_content, _path_under, _acl_governing_key, _tt_dep (the
#         script and its parts); dirname and realpath (imported by the script's
#         `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $REQUEST_CROOT, %LANG_MAP (the script's,
#         declared `our` there).
#
# THE FILE-SCOPE STATE HERE is %URL_SAFE_SCHEME and %URL_SAFE_NAMED, each a
# `my` filled in its own BEGIN, as it was in the script: set while this file
# compiles, which is still before any request, and read only by
# _url_safe_filter at call time. Keep them filled in BEGIN.
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S10). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $REQUEST_CROOT, %LANG_MAP );

# --- Include ---

sub convert_fenced_include {
    my ( $text, $md_path, $meta ) = @_;
    $meta //= {};

    $text =~ s{
        ^:::[ \t]+include(?:[ \t]+([^\n]*?))?\n  # opening ::: include [modifiers]
        [ \t]*([^\n]+?)[ \t]*\n                   # source URL or path (trimmed)
        ^:::[ \t]*\n                              # closing :::
    }{
        my $modifiers = $1 // '';
        my $source    = $2;

        # A path holding a template variable is NOT resolved, and never by a later
        # pass (SM964): the block is left as written, as the docs say.
        if ( $source =~ /\[%.*%\]/ ) {
            "::: include" . ( length $modifiers ? " $modifiers" : '' ) . "\n$source\n:::\n";
        }
        else {

        # Parse ttl modifier
        if ( $modifiers =~ /\bttl=(\d+)\b/ ) {
            my $ttl = $1;
            unless ( defined $meta->{ttl} ) {
                $meta->{ttl} = $ttl;
            }
        }

        _resolve_include( $source, $md_path, $modifiers );
        }
    }gesmx;

    return $text;
}

sub _resolve_include {
    my ( $source, $md_path, $modifiers ) = @_;

    # HTML-escape source for error spans
    ( my $source_escaped = $source ) =~ s/&/&amp;/g;
    $source_escaped                  =~ s/</&lt;/g;
    $source_escaped                  =~ s/>/&gt;/g;
    $source_escaped                  =~ s/"/&quot;/g;

    my $content;
    my $is_remote = $source =~ m{\Ahttps?://};

    if ($is_remote) {
        # Remote URL
        $content = fetch_url($source);
        unless ( defined $content ) {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include fetch failed", source => $source );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }
    }
    else {
        # Local file. SEC-2026-07 (C2): an include is content, so it is confined
        # to the request's content root ($REQUEST_CROOT, the docroot for a
        # single-site install) - never the whole docroot under multisite - AND
        # the lazysite/ management tree (auth/.secret, groups-settings.json,
        # users, ACLs, logs) is excluded outright. Without this a content author
        # could `::: include /lazysite/auth/.secret` and leak the CSRF/HMAC
        # secret and password hashes into a public page.
        my $base = $REQUEST_CROOT // $DOCROOT;
        my $resolved;
        if ( index( $source, $DOCROOT ) == 0 ) {
            # Already a full filesystem path (e.g. from scan results)
            $resolved = $source;
        }
        elsif ( $source =~ m{\A/} ) {
            # Absolute from the content root
            $resolved = $base . $source;
        }
        else {
            # Relative to parent .md file
            $resolved = dirname($md_path) . '/' . $source;
        }

        # SM888 A3: AND THE CONTENT ROOT'S TWIN IN THE PRIVATE STORE.
        #
        # Gating MOVES content out of the docroot into a sibling store (SM286),
        # so a page in a protected section has its own partials in the store,
        # not under the content root. `_path_under` refused them - and logged
        # "include path invalid", which reads as an attempted traversal rather
        # than a feature that does not reach behind a gate.
        #
        # `_path_under_content` is the predicate the rest of the engine already
        # uses, and it is NOT "anywhere in the store": it accepts this content
        # root's twin only, so one domain still cannot reach another domain's
        # protected content. The lazysite/ exclusion below is untouched.
        $resolved = _content_abs($resolved);

        # Realpath check - reject if outside the content root (or its private
        # twin) or inside the lazysite/ management tree.
        my $real = realpath($resolved);
        if ( !_path_under_content( $real, $base )
            || _path_under( $real, "$LAZYSITE_DIR" ) )
        {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include path invalid", source => $source );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        if ( !-f $real ) {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include file not found", source => $source );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        # SM898: GOVERNED CONTENT IS INCLUDABLE ONLY FROM ITS OWN SECTION.
        #
        # A3 (above) let an include reach the private store, and nothing then
        # asked whether the REQUESTER may read what it reached. The field
        # measured the result on 0.14.3 as an anonymous visitor: a draft
        # section's partial and a read-restricted section's partial, each 404
        # when fetched directly, each printed in full into a public page that
        # carried one `::: include` line. The section's 404 exists so that
        # nothing confirms the content is there; one line of Markdown undid it,
        # and the one who can write that line on a multi-author site is exactly
        # the sub-user whose grant stops at their own folder.
        #
        # The rule is about SECTIONS, not identities: the including page must
        # sit under the same governing entry as the partial. A page inside the
        # section is gated by that entry already, so it may include the
        # section's own partials (A3's case, kept - t/integration/103). A page
        # anywhere else may not, whoever is asking. Identity-free on purpose:
        # the refusal renders the same for every reader, so a cached public
        # page cannot carry one reader's view to another, and an ungoverned
        # page's render never comes to depend on who asked. A TIGHTER rule
        # inside a section is a different entry and therefore a different
        # audience, and is refused for the same reason.
        my $gov = _acl_governing_key($real);
        if ( defined $gov ) {
            my $page_gov = _acl_governing_key($md_path);
            if ( !defined $page_gov || $page_gov ne $gov ) {
                log_event( "WARN", $ENV{REDIRECT_URL} // "-",
                    "include refused: governed content outside its section",
                    source => $source, rule => $gov );
                return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
            }
        }

        $content = eval { read_file($real) };
        if ( $@ || !defined $content ) {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include failed", source => $source, error => $@ );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        # SM888 A2: THIS RENDER READ A FILE THAT IS NOT THE PAGE.
        #
        # SM311 built the record for exactly this and gave it four call sites,
        # none of them here - so the cache was fresh whenever it post-dated the
        # .md and lazysite.conf, and an edited partial is neither. A shared
        # header, footer or notice changed once updated nothing until every
        # page including it was saved.
        #
        # It is SM311's own complaint one layer along, including the part about
        # who is affected: the person who maintains the partial is often not
        # the person who holds `manage_content` on the pages that use it, so
        # the recovery is not theirs to perform.
        #
        # The REAL path, as the json: reader records, so a symlinked partial is
        # watched where it lives rather than where it was named.
        _tt_dep($real);
    }

    # Determine extension from source
    my $ext = '';
    if ( $source =~ /\.(\w+)(?:\?.*)?$/ ) {
        $ext = lc($1);
    }

    my $lang = $LANG_MAP{$ext} || '';

    if ( $lang eq 'markdown' ) {
        # Strip YAML front matter, run sub-pipeline (no recursion)
        my ( undef, $body ) = parse_yaml_front_matter($content);
        my $sub = convert_fenced_divs($body);
        $sub = convert_fenced_code($sub);
        $sub = convert_oembed($sub);
        $sub = convert_md($sub);
        return $sub;
    }
    elsif ( $ext eq 'html' || $ext eq 'htm' ) {
        # Insert bare HTML
        return $content;
    }
    elsif ($lang) {
        # Code file - wrap in fenced code block for convert_fenced_code
        return "```$lang\n$content```\n";
    }
    else {
        # Unknown extension - wrap in <pre>
        $content =~ s/&/&amp;/g;
        $content =~ s/</&lt;/g;
        $content =~ s/>/&gt;/g;
        return "<pre>$content</pre>\n";
    }
}

sub convert_fenced_code {
    my ($text) = @_;

    $text =~ s{
        ^```[ \t]*(\S*)[ \t]*\n  # opening ``` with optional language
        (.*?)                     # content
        ^```[ \t]*\n              # closing ```
    }{
        my $lang = $1;
        my $code = $2;
        $code =~ s/&/&amp;/g;
        $code =~ s/</&lt;/g;
        $code =~ s/>/&gt;/g;
        my $class = $lang ? qq( class="language-$lang") : '';
        "<pre><code$class>$code</code></pre>\n"
    }gsmxe;

    return $text;
}

# Text::MultiMarkdown paragraph-wraps top-level block HTML that is not isolated
# by blank lines (e.g. a hero <section> with Markdown inside), emitting invalid
# <p><section>...</section></p>. Strip the spurious <p>/</p> that hug a
# block-level element. (Reported from an AI-partner site review, 2026-06.)
sub unwrap_block_html {
    my ($html) = @_;
    my $block = qr/(?:section|article|aside|nav|header|footer|figure|figcaption|main|div|details|summary|address|blockquote|form|fieldset|table|ul|ol|dl|hr|style)/ix;
    $html =~ s{<p>\s*(<$block\b)}{$1}g;
    $html =~ s{(</$block>)\s*</p>}{$1}g;
    return $html;
}

# SM967: A PLACEHOLDER THE CONTENT CANNOT SPELL.
#
# Three passes lift text out of the page and put it back by a placeholder:
# convert_md (script, style, comments - RAWBLOCK), render_content (code spans -
# CODEBLOCK) and convert_p_links (tags - NUL RAW). Each placeholder was a fixed
# word and a counter, so a value carrying the word was restored as the block:
# `?x=CODEBLOCK_0_END` printed a copy of the page's first code span, and a
# prefilled `RAWBLOCK_0_END` moved the page's own <script> into the field's
# value attribute, where its quotes could end the attribute. The key makes each
# placeholder specific to one call: random, and never a string already present
# in the text being protected, so neither a value nor an author can spell it.
sub _placeholder_key {
    my ($text) = @_;
    $text //= '';
    my $k;
    do { $k = sprintf '%08x%08x', int rand 0xffffffff, int rand 0xffffffff }
        while index( $text, $k ) >= 0;
    return $k;
}

sub convert_md {
    my ( $body, %o ) = @_;
    my $k = _placeholder_key($body);         # SM967

    # Protect <script> AND <style> blocks from Markdown processing. CSS/JS is not
    # Markdown: emphasis would mangle it - e.g. the `*/ ... /*` between two CSS
    # comments pairs into <em>...</em>, swallowing the rules in between (the login
    # page's inline styles regressed exactly this way).
    my @rawblocks;
    $body =~ s{(<(script|style)\b[^>]*>)(.*?)(</\2>)}{
        my $placeholder = "RAWBLOCK${k}_" . scalar(@rawblocks) . "_END";
        push @rawblocks, "$1$3$4";
        $placeholder
    }gsei;

    # SM689: HTML COMMENTS TOO, and for the same reason as the block above.
    #
    # Text::MultiMarkdown pairs `<!--` with a LATER `-->` when hashing HTML
    # blocks, and everything between the two is discarded - not escaped,
    # DISCARDED. A page that explains itself in comments between its markup
    # therefore loses the markup, silently, with no error anywhere.
    #
    # Measured on the Data page: twenty of its forty-six elements never reached
    # the browser, including `rows-panel`. The symptom an operator saw was
    # "Could not load rows: can't access property style, panel is null" - the
    # script looking for markup that the markdown pass had eaten. The page's
    # source was correct and every source-level test passed.
    #
    # Protecting comments the same way scripts and styles are protected removes
    # the pairing opportunity entirely: the matcher never sees a `<!--` to pair.
    # Comments survive into the output verbatim, which is what an HTML comment
    # in a page is for.
    $body =~ s{(<!--.*?-->)}{
        my $placeholder = "RAWBLOCK${k}_" . scalar(@rawblocks) . "_END";
        push @rawblocks, "$1";
        $placeholder
    }gse;

    # P5 (WORK-PLAN-0154): A TEMPLATE TAG IS NOT MARKDOWN.
    #
    # The body is converted BEFORE the template pass, so every `[% ... %]` the
    # author wrote went through the converter as prose: `[% IF a && b %]`
    # reached TT as `[% IF a &amp;&amp; b %]`, a parse error, and the page
    # showed its own source. `<` met the same escape and `*`/`_` could pair
    # into emphasis. Each tag is lifted out here and put back as written.
    #
    # Not inside code. A <pre> block already converted (convert_fenced_code,
    # which has escaped it) is passed over; a tag the converter then places in
    # a code span or an indented block goes back ESCAPED, as the converter
    # would have left it, because there it is text to show, not a directive.
    # A visitor's value cannot spell a tag here: the prefill and banner text
    # written into the body before this pass has `[` and `%` encoded
    # (_tt_inert). The `markdown` filter, whose input is a value rather than
    # the author's body, passes tt => 0 and is converted as it always was.
    #
    # The placeholder is itself a tag with spaces, `[% KEY %]`, so the converter
    # meets the same shape it met before: a bare word glued to the text around
    # it made `[a]B:[c]:d=[e]` a reference-link definition, and the line - a
    # scan loop in t/integration/39 - vanished from the page.
    my @tt;
    my $tk = "LZSTT${k}N";
    if ( $o{tt} // 1 ) {
        $body =~ s{(<pre\b.*?</pre>)|(\[%.*?%\])}{
            defined $1 ? $1 : do { push @tt, $2; '[% ' . $tk . $#tt . 'E %]' }
        }gsei;
    }

    my $md = Text::MultiMarkdown->new(
        use_fenced_code_blocks => 1,
    );
    my $html = $md->markdown($body);

    if (@tt) {
        my $esc = sub {
            my $s = shift;
            $s =~ s/&/&amp;/g;
            $s =~ s/</&lt;/g;
            $s =~ s/>/&gt;/g;
            return $s;
        };
        $html =~ s{(<code\b[^>]*>.*?</code>)}{
            ( my $c = $1 ) =~ s/(\[% \Q$tk\E(\d+)E %\])/defined $tt[$2] ? $esc->( $tt[$2] ) : $1/ge;
            $c
        }gse;
        $html =~ s/(\[% \Q$tk\E(\d+)E %\])/defined $tt[$2] ? $tt[$2] : $1/ge;
    }

    # Restore the protected blocks
    for my $i ( 0 .. $#rawblocks ) {
        $html =~ s/(?:<p>)?RAWBLOCK${k}_${i}_END(?:<\/p>)?/$rawblocks[$i]/;
    }

    return unwrap_block_html($html);
}

# Content components (D035): a TT filter that renders a value containing Markdown
# to HTML, reusing the page Markdown pipeline. A single-paragraph result is
# unwrapped so inline fields (e.g. heading="A site that's *alive*.") stay inline;
# multi-block content keeps its block structure.
sub _markdown_filter {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    my $html = convert_md( "$text", tt => 0 );    # P5: a value, not the body
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    if ( $html =~ m{\A<p>(.*)</p>\z}s && index( $1, '<p>' ) < 0 ) {
        $html = $1;    # inline: drop the single enclosing paragraph
    }
    return $html;
}

# SM824 I2 (ruled R7, 2026-10-02): encode a value as JSON, for a layout emitting
# JSON-LD.
#
# `%tt_opts` shipped `markdown` and no JSON encoder, so a layout wanting
# structured data had to hand-roll quoting in a template - which is the thing
# this exists to avoid. A missed backslash or control character does not produce
# a visible error; it produces JSON no consumer will parse, on a page that
# renders fine.
#
# SCALARS ONLY, DELIBERATELY. A layout emits one value at a time into JSON it is
# writing itself, and that is the whole use the filing asks for. Handing a
# reference to a TT filter would mean deciding how a blessed object or a cycle
# encodes, in a filter that cannot report a failure - so a reference becomes the
# empty string rather than a guess.
#
# WHY NOT JSON::PP->encode DIRECTLY: it would wrap the string in quotes, which is
# right, but it also escapes `/` inconsistently across versions and does not
# escape `<` at all. A `</script>` inside a JSON-LD block ENDS THE SCRIPT ELEMENT,
# so the three HTML-significant characters are escaped as \uXXXX here - valid JSON
# that cannot break out of the element it sits in.
sub _json_filter {
    my ($text) = @_;
    return '""' unless defined $text;
    return '""' if ref $text;
    my $s = "$text";
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\x08/\\b/g;
    $s =~ s/\f/\\f/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    # Remaining C0 controls are not legal raw in a JSON string.
    $s =~ s/([\x00-\x1f])/sprintf '\\u%04x', ord $1/ge;
    # The three that matter inside <script>: an author's `</script>` must not end
    # the element, and `<`/`>`/`&` are cheap to neutralise.
    $s =~ s/</\\u003c/g;
    $s =~ s/>/\\u003e/g;
    $s =~ s/&/\\u0026/g;
    return '"' . $s . '"';
}

# SM970: `| url_safe` - a value placed as a WHOLE link target (href, src,
# action) keeps only a scheme that cannot run script. The stash escapes a value
# so it cannot leave its attribute; that does not stop the attribute BEING
# `javascript:...`. The value passes unchanged when, read as a URL, it has no
# scheme - a relative path, `/abs`, `?q`, `#frag`, or `//host`, which inherits
# the page's own http/https - or one of http, https, mailto, tel. Anything else
# becomes `#`.
#
# The value is decoded - character references and percent-encoding - ONLY to
# read the scheme, layer by layer (the stash has already escaped it once, and an
# author's literal may carry more), and the scheme is checked at EVERY layer: a
# browser decodes an attribute once and does not percent-decode a scheme, so
# checking every layer is stricter than any browser, never looser. Leading
# controls and spaces are dropped and tab/CR/LF removed, as a URL parser does.
# What is returned is the original text, so nothing is escaped twice.
#
# Set in BEGIN, like %STATIC_DENY: main() runs from the middle of this file,
# before execution would reach a plain assignment down here.
my %URL_SAFE_SCHEME;
BEGIN { %URL_SAFE_SCHEME = map { $_ => 1 } qw(http https mailto tel) }

# The named references that can change how a scheme reads: the colon, the two
# characters a URL parser deletes, the scheme punctuation, and the `&` and `%`
# that open another layer. No named reference decodes to an ASCII letter.
my %URL_SAFE_NAMED;
BEGIN {
    %URL_SAFE_NAMED = (
        colon  => ':', Tab => "\t", NewLine => "\n", plus   => '+',
        period => '.', amp => '&',  AMP     => '&',  percnt => '%',
    );
}

sub _url_safe_chr {
    my ($n) = @_;
    return ( $n > 0 && $n <= 0x10FFFF ) ? chr $n : "\x{FFFD}";
}

sub _url_safe_filter {
    my ($text) = @_;
    return '' unless defined $text;
    return '#' if ref $text;
    my $s = "$text";
    for ( 1 .. 8 ) {
        ( my $r = $s ) =~ s/\A[\x00-\x20]+//;
        $r =~ tr/\t\n\r//d;
        if ( $r =~ /\A([a-zA-Z][a-zA-Z0-9+.\-]*):/ ) {
            return '#' unless $URL_SAFE_SCHEME{ lc $1 };
        }
        my $d = $s;
        $d =~ s/&#[xX]([0-9a-fA-F]{1,8});?/_url_safe_chr(hex $1)/ge;
        $d =~ s/&#([0-9]{1,10});?/_url_safe_chr($1)/ge;
        $d =~ s/&([a-zA-Z]+);/exists $URL_SAFE_NAMED{$1} ? $URL_SAFE_NAMED{$1} : "&$1;"/ge;
        $d =~ s/%([0-9a-fA-F]{2})/chr hex $1/ge;
        return $text if $d eq $s;
        $s = $d;
    }
    return '#';    # still decoding after eight layers: not a link anyone wrote
}

sub convert_dt_links {
    my ($html) = @_;
    # Convert unprocessed Markdown links inside <dt> tags.
    # These are left unconverted when <dt> content is authored as Markdown
    # inside an HTML <dl> block, which the Markdown parser does not process.
    $html =~ s{<dt>\[([^\]]+)\]\(([^)]+)\)</dt>}{<dt><a href="$2">$1</a></dt>}g;
    return $html;
}

sub convert_p_links {
    my ($html) = @_;
    # Convert unprocessed Markdown links in TEXT after TT rendering.
    # Markdown links containing TT variables in the URL are parsed by
    # MultiMarkdown before TT runs, which strips the TT content from the URL.
    # After TT has resolved all variables, this pass converts any remaining
    # Markdown link syntax in text content to HTML anchor tags.
    #
    # SM853: IN TEXT, WHICH IS NOT EVERYWHERE, and the name said `<p>` while the
    # pattern said the whole document. `x[i](y)` is ordinary JavaScript and
    # ordinary code prose, and this pass turned it into an anchor wherever it
    # appeared - inside <script>, <style>, <code>, <pre> and even inside an
    # attribute value. The Handlers page shipped in 0.13.13 with
    # `BUILD[listId](key)` in its only script: the anchor broke the parse of the
    # whole 26KB script, so every list stayed at "Loading..." and every button
    # was inert, with nothing in any log. The page was correct; this pass ate it.
    #
    # So the pass now runs on text alone. Script, style, pre and code spans come
    # out first, then every remaining tag - which is what keeps an attribute
    # value out of reach as well - and both go back afterwards. The placeholder
    # carries NULs, a byte no HTML document and no link target contains.
    #
    # SM967: a VALUE could contain one (`%00` in a query), and spelled this
    # placeholder; so it carries a per-call key as well (_placeholder_key).
    my @raw;
    my $k = _placeholder_key($html);
    $html =~ s{(<(script|style|pre|code)\b[^>]*>.*?</\2\s*>)}{
        push @raw, $1; "\0RAW${k}_" . $#raw . "\0"
    }gsei;
    $html =~ s{(<[^>]+>)}{ push @raw, $1; "\0RAW${k}_" . $#raw . "\0" }ge;

    $html =~ s{\[([^\]]+)\]\(([^)]+)\)}{<a href="$2">$1</a>}g;

    $html =~ s{\0RAW\Q$k\E_(\d+)\0}{ $raw[$1] }ge;
    return $html;
}

1;
