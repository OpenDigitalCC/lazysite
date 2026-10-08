package main;

# lazysite-processor/pipeline.pm - the page pipeline: a request's URI to a
# rendered page, and the static files served beside the pages.
#
# HOLDS   process_md(), the Markdown page render (front matter, forms,
#         components, divs, include, code, oEmbed, Markdown, then the template
#         and layout), with %RENDER_QUERY, the request's declared query values;
#         process_url(), the same for a .url source; _strip_leaked_refs();
#         sanitise_uri(), confine_content_root() and _path_under(), the path
#         confinement; the escapers - _esc_html, _esc_query_value, _data_inert,
#         _esc_query_stash, _tt_inert; _serve_content_static() (lint 127) with
#         %STATIC_DENY, _is_engine_asset and _static_cache_control; the source
#         alternate (_wants_source_alternate, _source_alternate,
#         @SOURCE_ALTERNATE_KEYS); _chrome_lang, _chrome and fetch_url, the
#         lazily loaded helpers; peek_ttl, peek_content_type, peek_query_params;
#         the freshness checks is_fresh, is_fresh_ttl, is_fresh_ttl_val_stat.
# OWNS    the order of the Markdown pipeline; what a URI may name (SM797) and
#         where a content root may point (SM151, SM293); what the anonymous
#         static serve refuses (SM797, SM795) and how it caches (SM388, SM416);
#         the one escaping vocabulary for data values (H5, SM869, SM965,
#         SM966); a Perl reference never reaching a page (SM833); a raw/api
#         page's content type (ADR 0006); when a cached page is stale.
# CALLS   render_content, render_template, the convert_* filters,
#         parse_yaml_front_matter, strip_tt_directives, update_registries,
#         write_html, resolve_site_vars, _peek_md, _engine_mtime, _lazy_lib,
#         _acl_governed, _acl_refused, _content_abs, _private_root,
#         _lazysite_dir_for, _security_headers, read_file, log_event (the
#         script and its parts); realpath (imported by the script's `use`,
#         before its parts load); Lazysite::I18n and Lazysite::Fetch, through
#         _lazy_lib, on their cold paths only.
# READS   $DOCROOT, $LAZYSITE_DIR, $LAYOUT_DIR, $CONF_FILE, $REMOTE_TTL,
#         %STATIC_CT; SETS @TT_DEPS, $TT_DEP_LIVE and %ACCESS_REC (the
#         script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S18). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

# --- Processing ---

sub sanitise_uri {
    my ($uri) = @_;

    # Strip leading slash
    $uri =~ s{^/}{};

    # Trailing slash means directory index
    if ( $uri =~ s{/$}{} ) {
        $uri .= '/index';
    }
    else {
        # Strip the page extension - ALL of them (SM797). One strip let
        # `/<page>.md.md` resolve to `<page>.md`, which still has an extension,
        # so it went down the static branch and was served as SOURCE: a draft
        # page's markdown, an api page's body, and `.url.url` revealing an
        # upstream. Collapsing every trailing page extension sends that request
        # to the page renderer instead, where draft: and access rules apply. This
        # is the mechanism; the extension denylist in _serve_content_static is
        # the belt.
        1 while $uri =~ s/\.(html|md|url)$//;
    }

    # Reject null bytes
    return if $uri =~ /\0/;

    # Reject path traversal sequences
    return if $uri =~ m{(?:^|/)\.\.(?:/|$)};

    # Reject absolute paths or suspicious characters
    return if $uri =~ m{^/};
    return if $uri =~ m{[<>"'\\]};

    # Empty uri means docroot index
    $uri = 'index' unless length $uri;

    return $uri;
}

# SM151: is an absolute path strictly inside a directory (or equal to it)?
# Boundary-safe containment for every realpath confinement check. A bare
# index($real,$root)==0 prefix test also passes for a SIBLING whose name is a
# string-superset of $root (docroot/site vs docroot/site-backup, or
# sites/clienta vs sites/clienta-old), so a symlink resolving there would
# escape the intended tree. Comparing against "$root/" (and allowing equality)
# closes that. Used by the page/.url/static-html serve, the boxed-search file
# check, TT include/json sources, and the cache-path guard so they cannot drift
# apart again.
sub _path_under {
    my ( $real, $root ) = @_;
    return 0 unless defined $real && defined $root && length $root;
    return ( $real eq $root || index( $real, "$root/" ) == 0 ) ? 1 : 0;
}

# SEC-2026-07 (H5): HTML-escape the five significant characters. Safe in both
# element-text and double/single-quoted attribute contexts, so a value escaped
# once here needs no per-sink `| html`.
sub _esc_html {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

# SM869: a query value as the template stash holds it. HTML-escaped, as every
# other client-influenced value entering the stash is - and its line breaks as
# character references, because the body's template OUTPUT is scanned once more
# for `::: include` blocks (render_template's second include pass). A value
# carrying lines of its own could spell such a block and name a file for the
# engine to pull into the page; measured before this change, with a shipped page
# shape. &#10; renders as the newline it replaces, in text and in attributes.
#
# SM966: the line breaks are now part of _data_inert, with the rest of the set.
sub _esc_query_value {
    return _data_inert( _esc_html(shift) );
}

# SM966: WHAT A DATA VALUE MAY NOT CARRY LITERALLY, past the HTML escape - for a
# value the page's author did not write: a query value (the stash copy, above), a
# db: row (_escape_db_rows), and through _tt_inert the form prefill and banner.
#
# The HTML escape makes a value safe for the HTML parser, and two more readers
# see the page. convert_p_links turns `[text](url)` in the rendered TEXT into an
# anchor - it exists for an author's link whose URL holds a template variable -
# so a value spelling one became a link: `?x=[m](javascript:void)` printed by
# [% query.x %] rendered `<a href="javascript:void">`, and a visitor-written row
# did the same on every page listing it. And an `api: true` page puts the value
# inside a JSON string, where a backslash or a control character is not text:
# `?x=a\` or a row with a tab made the whole response invalid JSON.
#
# All become character references, which a browser shows as the characters
# typed and which are inert in JSON: `[` and `]` (no link can open or close
# around the value), `\`, and the C0 controls - CR and LF among them, which
# _esc_query_value encoded alone before (SM869). NUL becomes U+FFFD, which is
# what an HTML parser would show for it. One set, here, so the query stash, the
# rows and the pre-template sinks cannot drift apart.
sub _data_inert {
    my ($s) = @_;
    $s =~ s/\[/&#91;/g;
    $s =~ s/\]/&#93;/g;
    $s =~ s/\\/&#92;/g;
    $s =~ s/\0/&#xFFFD;/g;
    $s =~ s/([\x01-\x1f])/'&#' . ord($1) . ';'/ge;
    return $s;
}

# SM869: the stash's escaped COPY of the request's declared query values. The
# raw hash is left as it is: it is %RENDER_QUERY, the engine's copy.
sub _esc_query_stash {
    my ($q) = @_;
    $q //= {};
    return { map { ( $_ => _esc_query_value( $q->{$_} ) ) } keys %{$q} };
}

# SM869: text a sink emits INTO A PAGE BODY BEFORE THE BODY'S OWN TEMPLATE PASS -
# a form field's value, the form outcome banner - is read by TT next, so a `[%`
# in it would run, with the visitor's text as the template. Measured before this
# change: `?x=[% site_name %]` prefilled the site's own value. Applied AFTER the
# HTML escape for the sink's context, so `[` and `%` become character references
# the browser shows as the same characters and TT does not read as a tag.
#
# SM965: AND ITS LINE BREAKS, for the same reason the stash copy encodes them
# (`_esc_query_value`). A value this sink emits lands in the body BEFORE the
# FIRST include pass (convert_fenced_form runs before convert_fenced_include in
# process_md), and that pass reads a newline-delimited `::: include` block as a
# directive. `[%` alone was not enough: a value carrying a line of its own -
# `?x=<LF>::: include<LF>/file<LF>:::<LF>` - spelled a block the include pass
# resolved, pulling a file under the content root into the page (reflected, via
# the prefill textarea and the outcome banner; measured by t/unit/processor/89).
# CR/LF become `&#13;`/`&#10;`, which a browser renders as the line breaks the
# visitor typed, so a genuine multi-line value is displayed, not mangled - while
# no literal line break remains for the include pass to key on. This is the one
# place every pre-template-body sink passes through, so the three callers
# (prefill attribute, prefill textarea, outcome banner) are covered at once and
# a fourth cannot reopen it.
#
# SM966: `[`, CR and LF now come from _data_inert, with the rest of that set.
sub _tt_inert {
    my ($s) = @_;
    $s = _data_inert($s);
    $s =~ s/%/&#37;/g;
    return $s;
}

# SM151: resolve a per-domain content root to a confined absolute directory.
# $content_root is the docroot-relative directory from lazysite.conf
# (a base `content_root:` for the primary host, or a whitelisted
# `alias.<host>.content_root:` for an alias). Returns:
#   * the docroot itself when unset/empty or '/'  - today's behaviour, so an
#     install that configures no roots is unchanged (pure superset);
#   * the confined absolute directory when valid;
#   * undef when the configured value escapes the docroot or reaches into the
#     lazysite/ management tree, or does not exist - the caller treats undef as
#     "fall back to the docroot root and WARN" (spec S6), never as a hard fail.
# Enforces spec S1 (no escape via traversal/symlink) and S2 (never the
# lazysite/ secrets/auth/ACL tree). realpath() resolves symlinks, so a root
# that symlinks out of the docroot is rejected; it returns undef for a
# non-existent path, so a mis-typed root safely degrades rather than serving
# an unintended tree.
sub confine_content_root {
    my ( $docroot, $content_root ) = @_;
    return $docroot unless defined $content_root && length $content_root;

    ( my $rel = $content_root ) =~ s{^/+|/+$}{}g;    # strip leading/trailing /
    return $docroot unless length $rel;              # '' or '/' => docroot root

    # Reject dangerous shapes before touching the filesystem.
    return undef if $rel =~ /\0/;
    return undef if $rel =~ m{(?:^|/)\.\.(?:/|$)};
    return undef if $rel =~ m{[<>"'\\]};

    # Must resolve to a real directory. The -d guard is load-bearing: realpath
    # resolves a non-existent leaf against its existing parent on some systems
    # (returning a path rather than undef), so a mis-typed root would otherwise
    # look valid and 404 every page instead of degrading. Requiring the dir to
    # exist means realpath below fully resolves any symlinks in the path, so a
    # root that symlinks out of the docroot is still caught.
    my $target = "$docroot/$rel";
    return undef unless -d $target;

    my $droot = realpath($docroot) // return undef;
    my $abs   = realpath($target)  // return undef;
    # SM293: the tree this guard excludes may live beside the docroot. Derived
    # from the PASSED docroot, not the file-scoped one - this sub is pure and
    # its tests call it with their own root. On a migrated site the guard finds
    # nothing inside the docroot to exclude, which is correct: there is nothing
    # there to reach.
    my $lzdir = realpath( _lazysite_dir_for($docroot) );    # may not exist

    # Must sit within the docroot ...
    return undef unless $abs eq $droot || index( $abs, "$droot/" ) == 0;
    # ... and must never be, or be inside, the lazysite/ management tree.
    return undef if defined $lzdir
        && ( $abs eq $lzdir || index( $abs, "$lzdir/" ) == 0 );

    return $abs;
}

# Serve a static file that lives under the domain's content root (SM151 P6).
# Returns 1 when it served a file, 0 otherwise. Only extensioned files are
# considered (clean page URLs are extensionless and handled by the .md path).
# Binary-safe (raw read/write). Confined to $root via realpath, so a symlink
# under the content root cannot escape it.
# The engine's own assets, by exact path. A list rather than a prefix: a prefix
# would let a future file under /assets/ inherit an exemption nobody decided to
# give it.
sub _is_engine_asset {
    my ($uri) = @_;
    return 0 unless defined $uri;
    $uri =~ s/\?.*\z//;
    # DP-3b joins the list DELIBERATELY, which is what an exact list is for.
    # Without it the data helper 404s on any domain with its own content root
    # and a live table simply never refreshes - silently, because a script that
    # does not load reports nothing. That is SM382's measured failure, and a
    # new asset inherits none of the reasoning unless somebody adds it here.
    return ( $uri eq '/assets/lazysite-chrome.css'
            || $uri eq '/assets/lazysite-chrome.js'
            || $uri eq '/assets/lazysite-data.js' ) ? 1 : 0;
}


# SM416: the asset Cache-Control, in one place for both the 200 and 304 paths.
#
# The default (no-cache, must-revalidate) is DELIBERATE and stays the default:
# must-revalidate is what makes protecting a path take effect for a visitor who
# already fetched it (the SM331 lesson, documented at the 200 site below), and
# the ten-year cache the docs used to describe is a property of the stock
# front-end fast path, not of the engine.
#
# asset_max_age (site setting, seconds) lets an operator trade a BOUNDED
# staleness window for browser caching: the field measured a typical page at
# ~6 engine round trips per view under pure revalidation, which on contended
# hosting is a real multiplier. With a value set, a newly-protected asset can
# stay readable in browser caches for at most that window - which is why the
# operator chooses the number rather than inheriting one.
#
# ACL-governed paths are no-store ABSOLUTELY, whatever the setting: a protected
# asset must never sit in a shared or private cache at all.
sub _static_cache_control {
    my ($real) = @_;
    return 'Cache-Control: no-store' if _acl_governed($real);
    my %sv  = resolve_site_vars();
    my $age = $sv{asset_max_age} // '';
    return "Cache-Control: public, max-age=$age, must-revalidate"
        if $age =~ /\A\d{1,9}\z/ && $age > 0;
    return 'Cache-Control: no-cache, must-revalidate';
}

# SM797: WHAT THE ANONYMOUS STATIC SERVE NEVER HANDS OUT, by the extension of the
# CANONICAL path. DAV - the authenticated surface - refused dangerous types on
# write while this, the anonymous one, served any extension as raw bytes.
#
# A DENYLIST, BY RULING (2026-09-09). An allowlist is stronger and was refused:
# it stops a site serving a file type nobody listed, on upgrade, silently, and
# the first anyone hears is from the field. For the same reason `json` is NOT
# here - sites serve data and manifests as JSON on purpose, and a list that
# quietly broke them would be the "wrong list worse than none" this filing warned
# about. Each group below is a type with no legitimate reason to leave a content
# directory as raw bytes:
#
#   the engine's own inputs  - md url brief: pages render, never download;
#                              a .url's target is an upstream nobody chose to
#                              publish, and a .brief is the operator's notes
#   editor and backup litter - bak swp swo orig old tmp: left beside the thing
#                              they copy, and a copy of anything is as private
#                              as the original
#   configuration and keys   - conf ini env pem key
#   executable source        - EVERY type DAV refuses to accept as an upload,
#                              pinned by t/lint/127 so the two cannot drift: a
#                              type too dangerous to write is too dangerous to
#                              hand out.
#
# A refused request is answered as NOT FOUND - the same as an absent file - so
# this tells a scanner nothing it could not learn from a miss.
#
# FILLED AT COMPILE TIME, AND IT HAS TO BE. The request is dispatched from the
# middle of this file (handle_one_request, near the FastCGI loop), long before
# execution would reach a plain `my %STATIC_DENY = ...` down here - so the hash
# would exist and be EMPTY when every request ran. The first version of this
# did exactly that and the denylist refused nothing, silently; the end-to-end
# test caught it and a unit test of the sub would not have.
my %STATIC_DENY;
BEGIN { %STATIC_DENY = map { $_ => 1 } qw(
        md url brief
        bak swp swo orig old tmp
        conf ini env pem key
        pl pm cgi fcgi shtml shtm phtml php php3 php4 php5 phps phar htaccess htpasswd
) }

# SM825: THE SOURCE ALTERNATE - the markdown beside the rendered page.
#
# `llms.txt` has linked to `<page>.md` since SM299, which spent its effort on
# getting the shape of those URLs right (an index page's URL already ends in a
# slash, so appending `.md` gave `<dir>/.md`). Measured 2026-09-29: the URLs are
# right and every one of them answers with the page's HTML, byte-for-byte
# identical to the rendering. sanitise_uri collapses the extension, so the
# request goes down the render path and gets what that path produces. The one
# registry whose entire purpose is to hand a machine the prose without HTML
# around it was pointing every client at HTML.
#
# THE GATE IS THE PAGE'S OWN, BY CONSTRUCTION, because the emitter runs INSIDE
# the render path, after `auth:` and payment have already had their say. This
# filing's own audit reasoned about `_serve_content_static`'s per-path ACL - `md`
# is the first entry on SM797's denylist above - and concluded the serving path
# "has A gate and it is the WRONG ONE". That was the wrong path: a `.md` request
# never reaches the static branch, because the extension is gone before the
# branch is chosen. Measured: `/gated.md` answers 302 to the login from the
# page's own front matter. So the expensive half of the audit's verdict does not
# apply, and SM797's denylist is untouched - `md` stays on it, and the alternate
# is not a static file.
#
# THE FRONT MATTER IS BUILT, NOT FILTERED. RULED 2026-09-29: an allowlist of
# `title`, `subtitle` and `description` - the three keys the rendering already
# publishes, so the alternate discloses nothing new. Constructing the output from
# a fixed list is what makes that an allowlist in FACT rather than in intent: the
# next key somebody adds is withheld with no code change, where a filter that
# strips known-bad keys would expose it. SM797's own ruling turned on the same
# distinction. What this withholds today, counted across the shipped pages:
# `auth` (27 of 64), `auth_groups`, `query_params`, `tt_page_var`,
# `payment_address`, `form`, `api`.
#
# FILLED AT COMPILE TIME, for the reason %STATIC_DENY documents above: the
# request is dispatched from the middle of this file, long before execution would
# reach a plain `my @X = ...` down here, so the list would be EMPTY on every
# request and the emitter would publish no metadata at all - silently, and with
# every test that calls the sub directly still passing.
my @SOURCE_ALTERNATE_KEYS;
BEGIN { @SOURCE_ALTERNATE_KEYS = qw(title subtitle description) }

# Does this request ask for the source rather than the rendering?
#
# EXACTLY ONE trailing `.md`. A doubled extension is the probe SM797 closed, not
# an author's link: `/page.md.md` collapses to the same page, so answering it
# with source would reopen that door through a new hole. The test is on what the
# CLIENT ASKED FOR, before sanitise_uri, because after it there is nothing left
# to ask.
sub _wants_source_alternate {
    my ($uri) = @_;
    return 0 unless defined $uri && $uri =~ /\.md\z/;
    return 0 if $uri =~ /\.(?:html|md|url)\.md\z/i;
    return 1;
}

# The alternate's body: the allowlisted keys, then the prose as authored.
#
# Returns undef when the page cannot be read, which the caller treats as "not
# handled" so the request falls through to the rendering rather than answering
# with an empty document.
sub _source_alternate {
    my ($md_path) = @_;
    open my $fh, '<:utf8', $md_path or return;
    my $text = do { local $/; <$fh> };
    close $fh;
    return unless defined $text;

    my %said;
    if ( $text =~ s/\A---[ \t]*\n(.*?)\n---[ \t]*\n//s ) {
        my $yaml = $1;
        for my $k (@SOURCE_ALTERNATE_KEYS) {
            next unless $yaml =~ /^\Q$k\E[ \t]*:[ \t]*(\S.*?)[ \t]*$/m;
            # Captured before any later match clobbers it, and the author's own
            # quoting undone exactly once - it is re-quoted on the way out below.
            my $v = $1;
            $v =~ s/\A(['"])(.*)\1\z/$2/s;

            # One shipped page carries `[% client_ip %]` inside its subtitle.
            # Same helper the register: list uses, so there is one answer to
            # "what happens to a directive in a front-matter value".
            $v = strip_tt_directives($v);
            $v =~ s/\s+\z//;
            $said{$k} = $v if length $v;
        }
    }

    my $out = '';
    if (%said) {
        # The DECLARED order, never the hash's: this is a document somebody may
        # diff between two requests. Values are emitted double-quoted and
        # escaped, always - a title containing a colon is ordinary, and an
        # alternate whose YAML validity depends on the author's punctuation is
        # not a contract.
        $out = "---\n";
        # THIS LOOP IS THE ONE THAT WITHHOLDS, not the collecting loop above.
        # Sabotage found that out: rewriting the collection as a denylist changed
        # nothing observable, because emission still walked the allowlist - so a
        # reader who removes THIS grep on the grounds that collection already
        # filtered would publish every key in the file, and the collection filter
        # alone is what looks redundant. Both are kept; this is the load-bearing
        # one.
        for my $k ( grep { exists $said{$_} } @SOURCE_ALTERNATE_KEYS ) {
            my $v = $said{$k};
            $v =~ s/(["\\])/\\$1/g;
            $out .= qq($k: "$v"\n);
        }
        $out .= "---\n\n";
    }
    $text =~ s/\A\s+//;
    return $out . $text;
}

sub _serve_content_static {
    my ( $root, $rel, $uri ) = @_;
    return 0 unless length $rel;
    my ($ext) = $rel =~ /\.([A-Za-z0-9]+)\z/;
    return 0 unless defined $ext;

    # SM797: the belt. Checked on the REQUEST's extension here, and again on the
    # canonical path below once it is resolved, because a symlink can carry an
    # innocent name to a denied target.
    return 0 if $STATIC_DENY{ lc $ext };

    # SM286: the file may live in the private store rather than under $root,
    # and the confinement test has to accept whichever tree answered - while
    # still refusing anything outside BOTH.
    my $path = _content_abs("$root/$rel");
    return 0 unless -f $path;
    my $real = realpath($path);
    return 0 unless defined $real;
    my $priv = _private_root();
    return 0
        unless index( $real, "$root/" ) == 0
        || ( length $priv && index( $real, "$priv/" ) == 0 );

    # SM795: AND NOT INSIDE THE ENGINE TREE, on the CANONICAL path.
    #
    # The engine tree is blocked earlier by a test on the REQUEST STRING
    # (`$uri eq $LAZYSITE_URI || index($uri, "$LAZYSITE_URI/") == 0`), which
    # answers about what the client asked for. This serve resolves the real
    # path and then checked only the docroot boundary - and in the
    # inside-docroot layout the engine tree IS under the docroot. So a symlink
    # whose request path does not begin with /lazysite resolved into it and was
    # served: the session secret, or the connector secrets, returned as
    # whatever content type the extension implied.
    #
    # This is the rule the project already holds (SM268): blocklist on the
    # canonical resolved path, never on the request string. _resolve_include
    # makes exactly this test, with a comment saying why. One sink of three had
    # it; now two do, and the DAV half is filed as SM795's second part.
    return 0 if length $LAZYSITE_DIR && _path_under( $real, $LAZYSITE_DIR );

    # SM797: and by the CANONICAL path's extension, for the reason SM795 gives
    # above - the rule holds on what was resolved, never only on what was asked.
    if ( my ($real_ext) = $real =~ /\.([A-Za-z0-9]+)\z/ ) {
        return 0 if $STATIC_DENY{ lc $real_ext };
    }

    # SM223: these are source-less statics on a content-rooted domain - the same
    # exposure as the fallback above, so the same gate. Returning 1 means the
    # response is written and the caller stops, which is what a refusal needs.
    return 1 if _acl_refused( $real, $uri // ( $ENV{REDIRECT_URL} // '' ) );

    # SM388: CONDITIONAL GET, which is what makes SM387's revalidation cheap.
    #
    # SM387 settled that an engine-served static must revalidate: it is public
    # now and can be protected at any moment, so a long cache would outlive the
    # protection in a visitor's browser. That decision is right and it has a
    # cost - and without a validator the cost is a FULL RE-DOWNLOAD on every
    # navigation, which is the expensive way to be correct.
    #
    # A validator makes revalidation a 304 with no body: the operator still gets
    # protection that takes effect immediately, and the visitor stops paying for
    # it in bytes.
    #
    # WEAK, from mtime and size, because that is what this can honestly assert.
    # A strong validator claims byte-identity, and two writes inside one second
    # would break that claim; W/ says "semantically the same", which mtime and
    # size do support. Cheaper than hashing the file on every request, which on
    # a shared host is the cost this is trying to remove.
    my @st   = stat($real);
    my $etag = @st ? sprintf( 'W/"%x-%x"', $st[9], $st[7] ) : undef;

    if ( defined $etag ) {
        my $inm = $ENV{HTTP_IF_NONE_MATCH} // '';
        # A client may send several, and may send them weak.
        for my $candidate ( split /\s*,\s*/, $inm ) {
            $candidate =~ s/^\s+|\s+$//g;
            next unless length $candidate;
            next unless $candidate eq $etag || $candidate eq '*';
            $ACCESS_REC{s} //= 304;
            $ACCESS_REC{b} = 0;
            print "Status: 304 Not Modified\n";
            print "$_\n" for _security_headers();
            print "ETag: $etag\n";
            print _static_cache_control($real) . "\n";    # SM416
            print "\n";
            return 1;
        }
    }

    # SM389: STREAMED, NOT SLURPED. This read the whole file into memory before
    # writing a byte of it, in a persistent pool worker - so a single request
    # for a large upload sized the worker to that file and kept it there. There
    # is no cap anywhere: WebDAV accepts 64m bodies by front-end configuration,
    # and an operator publishing video has no reason to think a fetch of their
    # own file is a memory event.
    #
    # A cap was the other option and is worse: refusing to serve a file the
    # operator legitimately published, to protect a limit they never set,
    # trades an availability defect for a resource one. Reading in blocks costs
    # nothing and bounds the worker regardless of file size.
    open my $fh, '<', $real or return 0;
    binmode $fh;

    my $size = ( stat $fh )[7] // 0;
    my $ct   = $STATIC_CT{ lc $ext } || 'application/octet-stream';
    $ACCESS_REC{s} //= 200;
    $ACCESS_REC{b} = $size;
    binmode(STDOUT);
    print "Status: 200 OK\n";
    print "Content-type: $ct\n";
    print "$_\n" for _security_headers();    # SM352
        # SM223: a file whose serving depended on WHO asked must not be stored by a
        # shared cache. no-cache still permits storage and revalidation; no-store
        # does not, and that is the distinction that matters for private material.
        #
        # SM387: AND THE PUBLIC BRANCH IS `no-cache` DELIBERATELY, not by
        # omission. This was measured in the field and reported as a possible
        # regression, which it looks like: on the SM283 proxy template every
        # static comes back here, and the ten-year `expires max` the front end
        # used to apply is gone. On contended shared hosting that is not free.
        #
        # It stays, because a long cache would resurrect SM331 one layer out.
        # A static served here is PUBLIC RIGHT NOW and can be protected at any
        # moment - that is the whole point of SM223, protection as a content
        # action with no vhost regeneration. A visitor holding a ten-year copy
        # would go on reading it long after the operator protected the folder,
        # in their own browser cache, where nothing the engine or the front end
        # does can reach them.
        #
        # SM331 was exactly this in the front end's descriptor cache and took
        # three filings to understand. `must-revalidate` is what makes
        # protecting a path take effect for someone who already fetched it.
        #
        # SO THE TEN-YEAR CACHE IS A PROPERTY OF THE FRONT-END FAST PATH, not of
        # lazysite: a site with no ACL store keeps it, because nothing there can
        # become protected without a sysop noticing. The docs say so now
        # rather than describing the stock template as though it were the rule.
    print _static_cache_control($real) . "\n";    # SM416: sysop-set max-age
                                                  # or the revalidation default
    print "ETag: $etag\n" if defined $etag;       # SM388
    print "\n";

    # 64 KiB blocks: large enough that the syscall count is irrelevant, small
    # enough that the worker's footprint is a constant rather than a function of
    # what the operator published.
    my $buf;
    while ( my $n = read $fh, $buf, 65_536 ) {
        print $buf;
    }
    close $fh;
    return 1;
}

# SM856: the request's DECLARED query values, for the form renderer's `prefill:`.
#
# The caller hands process_md a hash that has ALREADY been filtered to the page's
# `query_params:` allowlist, which is the gate this rule relies on. It is held
# here rather than threaded through render_content -> components -> _render_form,
# and it is set per render so a pooled process cannot serve one visitor's value
# to the next.
#
# SM869: RAW. These are the values the visitor sent, for the engine to act on -
# never to be emitted as they are. A sink that outputs one escapes it for its own
# context; the template stash gets its own escaped copy (render_content).
our %RENDER_QUERY;

sub process_md {
    my ( $md_path, $html_path, $md_mtime, $query ) = @_;
    $query //= {};
    local %RENDER_QUERY = %{$query};

    # SM888 A2: THE RENDER'S DEPENDENCY RECORD STARTS HERE, which is where the
    # render starts. It used to start inside resolve_tt_vars, which was the only
    # recorder when SM311 wrote it - and is now called from resolve_site_vars
    # and from render_content, both AFTER `::: include` has resolved. So the
    # include recorded its partial and the reset threw it away, and write_deps
    # found an empty list and removed the record. An included file was watched
    # by nothing.
    #
    # One reset per render, at the top, and every recorder downstream of it
    # survives to write_deps - which runs immediately after this returns.
    @TT_DEPS     = ();
    $TT_DEP_LIVE = 0;

    my $raw_text = read_file($md_path);
    my ( $meta, $body ) = parse_yaml_front_matter($raw_text);

    # Format mtime for TT variables
    if ( defined $md_mtime ) {
        my @t      = localtime($md_mtime);
        my @months = qw(January February March April May June
            July August September October November December);
        $meta->{page_modified} = sprintf( "%d %s %d",
            $t[3], $months[ $t[4] ], $t[5] + 1900 );
        $meta->{page_modified_iso} = sprintf( "%04d-%02d-%02d",
            $t[5] + 1900, $t[4] + 1, $t[3] );
    }
    my $page;

    # D035: resolve the active layout's directory so fenced components
    # (::: name -> components/name.tt) can be found. Page override wins, else the
    # site default. Local layouts only (remote/URL layouts skip this for now).
    my $cmp_layout = ( defined $meta->{layout} && length $meta->{layout} )
        ? $meta->{layout}
        : do { my %sv = resolve_site_vars(); $sv{layout} };
    my $layout_dir = ( defined $cmp_layout && length $cmp_layout
            && $cmp_layout !~ m{://} ) ? "$LAYOUT_DIR/$cmp_layout" : undef;

    # api: true - body is pure TT, no Markdown pipeline, no layout
    if ( $meta->{api} && $meta->{api} =~ /^true$/i ) {
        my ($processed_body) = render_content( $meta, $body, $query );
        $processed_body =~ s/^\s+|\s+$//g;    # trim for clean JSON
        $page = $processed_body;
    }
    # raw: true - Markdown pipeline runs, no layout
    elsif ( $meta->{raw} && $meta->{raw} =~ /^true$/i ) {
        my $converted_form = convert_fenced_form( $body, $meta );
        my $converted_comp = convert_fenced_components( $converted_form, $layout_dir, $md_path, $meta );
        my $converted        = convert_fenced_divs($converted_comp);
        my $converted_inc    = convert_fenced_include( $converted, $md_path, $meta );
        my $converted2       = convert_fenced_code($converted_inc);
        my $converted3       = convert_oembed($converted2);
        my $html_body        = convert_md($converted3);
        my ($processed_body) = render_content( $meta, $html_body, $query );
        $page = $processed_body;
    }
    # Normal mode - full pipeline with layout
    else {
        my $converted_form = convert_fenced_form( $body, $meta );
        my $converted_comp = convert_fenced_components( $converted_form, $layout_dir, $md_path, $meta );
        my $converted     = convert_fenced_divs($converted_comp);
        my $converted_inc = convert_fenced_include( $converted, $md_path, $meta );
        my $converted2    = convert_fenced_code($converted_inc);
        my $converted3    = convert_oembed($converted2);
        my $html_body     = convert_md($converted3);
        $meta->{_md_path} = $md_path;
        $page             = render_template( $meta, $html_body, $query );
        $page             = convert_dt_links($page);
        $page             = convert_p_links($page);
    }

    # SM833: no Perl reference reaches a visitor, whatever produced it.
    $page = _strip_leaked_refs( $page, $raw_text, $md_path );

    # Only cache if no query params - query responses are dynamic
    if ( !%$query ) {
        write_html( $html_path, $page );
        eval { update_registries() };
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'registry update failed', error => $@ ) if $@;
    }

    return $page;
}

# SM833: A PERL REFERENCE NEVER REACHES THE PAGE.
#
# A template that interpolates a list or a hash whole - [% theme %], a db binding
# read with the wrong accessor, a json: variable used as a value - stringifies
# it, and the visitor is handed ARRAY(0x55d4...) with a heap address in it.
# SM833's instance was fixed where it arose; this is the net under the next one,
# at the one place every rendered page passes, rather than in each engine.
#
# Recognised by the live address, which no author typed: a token that also
# appears in the page's own source is the author's - a page about this very bug
# - and is left alone. What is removed is logged, naming the source, because a
# page that silently loses a value is the next thing to be puzzled over.
sub _strip_leaked_refs {
    my ( $page, $source, $where ) = @_;
    return $page unless defined $page && index( $page, '(0x' ) >= 0;
    my $n = 0;
    $page =~ s{((?:[A-Za-z_][\w:]*=)?(?:ARRAY|HASH|CODE|SCALAR|GLOB|REF|Regexp)\(0x[0-9a-f]+\))}
              { ( defined $source && index( $source, $1 ) >= 0 ) ? $1 : do { $n++; '' } }gex;
    log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
        'a Perl reference reached the page and was removed - a template interpolates a list or hash whole',
        count => $n, source => $where )
        if $n;
    return $page;
}

sub process_url {
    my ( $url_path, $html_path, $url_mtime ) = @_;

    # Read URL from file
    my $url = read_file($url_path);
    $url =~ s/^\s+|\s+$//g;    # trim whitespace

    # Serve stale cache if still within TTL
    if ( is_fresh_ttl($html_path) ) {
        return read_file($html_path);
    }

    # Fetch remote content
    my $raw = fetch_url($url);

    unless ( defined $raw ) {
        # Fetch failed - serve stale cache if available
        if ( -f $html_path ) {
            return read_file($html_path);
        }
        # No cache. SM837: THE VISITOR IS TOLD THE CONTENT IS UNAVAILABLE AND
        # NOTHING ABOUT WHERE IT COMES FROM. This used to render "Could not fetch
        # remote content from <code>$url</code>" - the upstream address, to an
        # anonymous visitor, interpolated unescaped, as a 200. A .url source can
        # name an internal host or carry a token in its query; the operator chose
        # to publish the content, never the address. The address goes to the log,
        # where an operator can reach it, and the status says the page is not
        # available rather than claiming success to every cache and monitor.
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'remote content unavailable',
            url => $url );
        return (
            render_template(
                { title => 'Content Unavailable' },
                qq(<div class="errorbox">\n<p>This content is temporarily unavailable.</p>\n</div>\n)
            ),
            '503 Service Unavailable'
        );
    }

    my ( $meta, $body ) = parse_yaml_front_matter($raw);

    # Format mtime for TT variables
    if ( defined $url_mtime ) {
        my @t      = localtime($url_mtime);
        my @months = qw(January February March April May June
            July August September October November December);
        $meta->{page_modified} = sprintf( "%d %s %d",
            $t[3], $months[ $t[4] ], $t[5] + 1900 );
        $meta->{page_modified_iso} = sprintf( "%04d-%02d-%02d",
            $t[5] + 1900, $t[4] + 1, $t[3] );
    }

    my $converted     = convert_fenced_divs($body);
    my $converted_inc = convert_fenced_include( $converted, $url_path, $meta );
    my $converted2    = convert_fenced_code($converted_inc);
    my $converted3    = convert_oembed($converted2);
    my $html_body     = convert_md($converted3);

    my $page;
    if ( $meta->{raw} && $meta->{raw} =~ /^true$/i ) {
        my ($processed_body) = render_content( $meta, $html_body );
        $page = $processed_body;
    }
    else {
        $page = render_template( $meta, $html_body );
        $page = convert_dt_links($page);
        $page = convert_p_links($page);
    }
    $page = _strip_leaked_refs( $page, $raw, $url_path );    # SM833

    write_html( $html_path, $page );
    eval { update_registries() };
    log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'registry update failed', error => $@ ) if $@;

    return $page;
}

# SM096: the guarded fetch + SSRF check now live in Lazysite::Fetch, shared with
# the manager's migrate-to-local action so there is ONE SSRF guard to audit.
# fetch_url is a cold, network-bound path (never the hot cache-hit render), so the
# module is loaded lazily here on first use - the page-serving hot path stays
# module-free (ADR 0001), exactly as LWP::UserAgent was already deferred.
# SM179 P8: a localised engine-chrome string (the bare 403/404 fallbacks and the
# "authentication required" text). Loaded lazily - these paths are rare relative
# to cache-hit traffic - and keyed off the host language, with an English
# fallback. Args are HTML-escaped by chrome_string. See Lazysite::I18n.

# The host's language, sanitised to a bare code (safe for an <html lang> attr and
# for naming an i18n file); 'en' when unset. See _chrome.
sub _chrome_lang {
    my %sv   = resolve_site_vars();
    my $lang = $sv{lang} || 'en';
    $lang =~ s/[^A-Za-z-]//g;
    return length $lang ? $lang : 'en';
}

sub _chrome {
    my ( $key, @args ) = @_;
    _lazy_lib('Lazysite::I18n');
    return Lazysite::I18n::chrome_string( $DOCROOT, _chrome_lang(), $key, @args );
}

sub fetch_url {
    my ($url) = @_;
    _lazy_lib('Lazysite::Fetch');
    return Lazysite::Fetch::fetch_url($url);
}

sub peek_ttl {
    my ($md_path) = @_;
    return _peek_md($md_path)->{ttl};
}

sub peek_content_type {
    my ($path) = @_;
    my $m = _peek_md($path);
    # SEC (ADR 0006, mechanical enforcement): a raw/api page is served VERBATIM,
    # with no layout and no escaping. A script-capable content_type declared by a
    # content author (text/html, XHTML, SVG) is therefore a stored-XSS vector - a
    # manage_content-only partner could write a page that runs script in every
    # visitor's browser. Downgrade any such declared type to text/plain; combined
    # with the X-Content-Type-Options: nosniff header the response already carries,
    # the browser cannot execute it. JSON / CSV / XML / plain-text / image / PDF
    # artifacts are unaffected; genuine HTML/SVG artifacts belong in a layout or a
    # static file (served by the web server, not the processor).
    if ( ( $m->{raw} || $m->{api} )
        && defined $m->{content_type}
        && $m->{content_type}
        =~ m{^\s*(?:text/html|application/xhtml\+xml|image/svg\+xml)\b}i )
    {
        log_event( 'WARN', $path,
            'raw/api page declared a script-capable content_type; downgraded to text/plain (serve HTML through a layout, or as a static file)',
            content_type => $m->{content_type} );
        return 'text/plain; charset=utf-8';
    }
    return $m->{content_type} if $m->{content_type};
    return unless $m->{raw} || $m->{api};
    return 'application/json; charset=utf-8' if $m->{api};
    return 'text/plain; charset=utf-8'       if $m->{raw};
    return 'text/html; charset=utf-8';
}

sub peek_query_params {
    my ($md_path) = @_;
    return unless $md_path && -f $md_path;
    return _peek_md($md_path)->{query_params};
}

sub is_fresh_ttl_val_stat {
    my ( $html_stat, $ttl ) = @_;
    return 0 unless @$html_stat;
    return ( time() - $html_stat->[9] ) < $ttl;
}

sub is_fresh_ttl {
    my ($html_path) = @_;
    return 0 unless -f $html_path;
    return ( time() - ( stat($html_path) )[9] ) < $REMOTE_TTL;
}

sub is_fresh {
    my ( $html_path, $md_path ) = @_;
    return 0 unless -f $html_path;
    return 0 unless -f $md_path;
    my $h = ( stat($html_path) )[9];
    return 0 if $h < ( stat($md_path) )[9];
    # A render also depends on the conf (see try_serve_cache); a cache that
    # predates a conf change is stale even if its source is unchanged.
    # SM886: and on the engine that produced it - the cached 404 is a rendered
    # page like any other, and a 404 carrying a two-release-old head contract is
    # the same defect on the path a visitor reaches by accident.
    return 0 if $h < _engine_mtime();
    return $h >= ( ( stat $CONF_FILE )[9] // 0 );
}

1;
