package main;

# lazysite-processor/render.pm - the template render: the TT boundary every page
# body crosses.
#
# HOLDS   render_content(): builds the page's template variables (site vars, the
#         page's tt vars, the auth/payment/preview contexts, the escaped stash
#         families and their `_raw` twins, the manager caps, the languages),
#         protects code blocks, neutralises a body's TAGS directive and renders
#         the body - as a sequence of calls to its parts (SM1012): _tt_engine,
#         _render_manager_facts, _render_lang, _render_stash and
#         _tt_process_protected; _tt_render() and _tt_render_impl(), the render
#         with one retry without the compile cache; _cache_umask(), the
#         group-writable umask every compile-cache surface runs under.
# OWNS    the single point the stash's escaped families enter (SM709, H5,
#         SM869) and the documented `_raw` exception (SM824); the code-block
#         placeholder pass (SM931, SM967); the TAGS refusal (SM968); a
#         compile-cache fault never breaking a render.
# CALLS   resolve_site_vars, resolve_tt_vars, _is_manager, _site_grants_manager,
#         _groups_grant_cap, _domain_scopes, _domain_home, _language_set,
#         _esc_html, _esc_query_stash, _front_matter_reserved,
#         _front_matter_private, _content_rel,
#         _request_address, _trusted_proxy_spec, _lazysite_version,
#         _manager_style, _enabled_plugins, _placeholder_key, _url_safe_filter,
#         log_event (the script and its parts); Template->new and make_path
#         (loaded by the script's `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $TT_COMPILE_DIR, %AUTH_CONTEXT,
#         %PAYMENT_CONTEXT, %PREVIEW_CONTEXT; SETS $RESPONSE_LANG (the
#         script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S16). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $RESPONSE_LANG, $TT_COMPILE_DIR, %AUTH_CONTEXT, %PAYMENT_CONTEXT, %PREVIEW_CONTEXT );

# Mixed-identity compile cache (field 2026-07-11): TT creates its compile
# cache mirror dirs itself with plain mkdir, i.e. with the PROCESS umask -
# under the usual 0022 that yields 0755 dirs, and on a group-shared docroot
# ANY identity may render first (the site user's CLI/dev-server vs the
# www-data CGI), after which the other identity cannot write cache/tt and its
# compile cache is silently disabled (and lazysite-check flags the tree).
# Scope umask 0002 around every surface that creates compile-cache dirs so
# they come out group-writable; the setgid cache dir supplies the shared
# group. Callers restore the returned old value when done.
sub _cache_umask { return umask 0002 }

# A TT compile-cache problem must never break rendering. TT 2.x raises a
# fatal file error when it cannot write a .ttc ("cache failed to write"),
# and TT 3.x dies outright from Provider's mkdir - either way a stale or
# unwritable cache/tt subtree took every page down (field-hit 2026-07-09).
# Run process() under eval; on any failure retry once on a fresh instance
# with the on-disk compile cache disabled. Returns (ok, error_text).
sub _tt_render {
    my ( $opts, $template, $vars, $out_ref ) = @_;
    # Compile-cache dirs are created inside new()/process() - see _cache_umask.
    my $old_umask = _cache_umask();
    my @r         = _tt_render_impl( $opts, $template, $vars, $out_ref );
    umask $old_umask;
    return @r;
}

sub _tt_render_impl {
    my ( $opts, $template, $vars, $out_ref ) = @_;
    my %opts = %{$opts};
    my $err  = 'cannot create TT instance';
    for my $attempt ( 0, 1 ) {
        delete @opts{qw(COMPILE_DIR COMPILE_EXT)} if $attempt;
        # eval BOTH stages: TT 3.x Provider dies in new() pre-creating the
        # compile-dir mirror of INCLUDE_PATH; TT 2.x fails later in process().
        my $tt = eval { Template->new(%opts) };
        unless ($tt) { $err = $@ ? "$@" : $err; next }
        ${$out_ref} = '';
        my $ok = eval { $tt->process( $template, $vars, $out_ref ) };
        $err = $@ ? "$@" : ( $ok ? '' : $tt->error() . '' );
        if ($ok) {
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                'rendered without the TT compile cache', error => 'retry' )
                if $attempt;
            return ( 1, '' );
        }
        return ( 0, $err ) if $attempt;
    }
    return ( 0, $err );
}

# SM1012 S7: THE TEMPLATE OBJECT FOR A CONTENT PASS - cut from render_content,
# built per call as it was (memoising it would be a change of behaviour). When
# Template->new dies rather than returning false - it does when the compile
# directory cannot be made - the umask is not put back; SM1012 records it, and
# t/unit/processor/113 pins it.
#
# Content pass uses ABSOLUTE => 0 - the content body is a string reference
# and should never need file access. ABSOLUTE => 1 would allow TT to follow
# absolute paths found in the content, which causes parse errors on CSS etc.
# (content is processed as a string ref, which TT never writes to the
# compile cache - so an unwritable cache/tt cannot fail this instance;
# only the make_path needs guarding.)
# TT 3.x pre-creates compile-dir mirrors in new() - group-writable
# creation whichever identity renders first (_cache_umask).
sub _tt_engine {
    my $old_umask = _cache_umask();
    eval { make_path($TT_COMPILE_DIR) } unless -d $TT_COMPILE_DIR;
    my $tt = Template->new(
        ABSOLUTE    => 0,
        ENCODING    => 'utf8',
        EVAL_PERL   => 0,                                     # L-2
        FILTERS     => { url_safe => \&_url_safe_filter },    # SM970
        COMPILE_DIR => $TT_COMPILE_DIR,                       # P-4
        COMPILE_EXT => '.ttc',                                # P-4
    ) or do { umask $old_umask; die "Template error: " . Template->error() . "\n" };
    umask $old_umask;
    return $tt;
}

# SM1012 S8: WHAT THE MANAGER UI NEEDS TO KNOW ABOUT THIS USER - cut from
# render_content. Returns the nav-gating capabilities (a hash ref), the scope
# root and home domain of a bound editor, and the editor's scopes (an array
# ref); all empty for a visitor who is not signed in.
#
# SM154 (P3): expose what the domain-aware manager UI needs - whether the
# user may manage domains (gates the Domains nav entry), and a bound editor's
# own content_root + home_domain (so the file browser roots there instead of
# the docroot the confinement would deny). Only computed when authenticated.
sub _render_manager_facts {
    my ($groups_str) = @_;
    my $mgr_user = $AUTH_CONTEXT{auth_user} // '';
    my %manager_caps;
    my ( $scope_root, $home_domain ) = ( '', '' );
    my @my_scopes;
    if ( length $mgr_user ) {
        # A sysop (unsecured/dev fallback: no group grants manager) implicitly
        # holds every cap; otherwise resolve the nav-gating caps from the groups.
        # SM160: the Domains page is gated by manage_domains (carved out of
        # manage_config); both are surfaced so the manager UI can gate each area.
        my $all = !_site_grants_manager();
        # manage_users is surfaced too so the nav can offer a "grant this to
        # enable" hint (SM186) for capability-gated areas, but only to a user who
        # can actually grant it. SM191 generalises that hint, so the content-area
        # caps (content/nav/themes/layouts) and audit are surfaced as well.
        # SM579 phase 2: manage_connectors joins them for the Connectors page.
        # SM842: manage_forms, for the Handlers page, which any of the three
        # destination capabilities (forms, data, connectors) reaches.
        # A capability the layout gates on and this list omits is a nav entry
        # that is invisible to everyone, including its holder - t/lint/83 asks
        # exactly that question, and asked it of this.
        # SM957: read_submissions gates the Submissions entry, and notifications
        # decides whether that entry carries the bell's unread count.
        for my $cap (
            qw(manage_config manage_domains manage_users
            manage_content manage_nav manage_themes manage_layouts audit
            manage_data manage_connectors manage_forms read_submissions
            notifications)
            )
        {
            $manager_caps{$cap}
                = ( $all || _groups_grant_cap( $cap, split /\s*,\s*/, $groups_str ) ) ? 1 : 0;
        }
        # SM165/SM157: access lives on the DOMAIN (allowed_groups + locked_users).
        # A single-domain editor is rooted at their one scope; a multi-domain
        # editor keeps scope_root empty and gets the full scope LIST (dav_scopes)
        # so the file browser can offer a domain switcher. Server-side confinement
        # (with the sub-user ceiling) holds regardless of this rooting hint.
        @my_scopes   = _domain_scopes( $mgr_user, split /\s*,\s*/, $groups_str );
        $scope_root  = ( @my_scopes == 1 ) ? $my_scopes[0] : '';
        $home_domain = _domain_home( $mgr_user, split /\s*,\s*/, $groups_str );
    }
    return \%manager_caps, $scope_root, $home_domain, \@my_scopes;
}

# SM1012 S9: THE SITE'S LANGUAGE AND THE PAGE'S, SANITISED - cut from
# render_content, which sets $RESPONSE_LANG from the second where it did.
#
# SM179 (P1): language awareness. site_lang is the host's language (conf
# `lang:` or the alias override); page_lang lets a page override it via front
# matter; both default to 'en'. $RESPONSE_LANG feeds the Content-Language header.
# SEC: page_lang is CONTENT-PARTNER controllable (a page's front-matter `lang:`),
# and lands in <html lang="..."> and the Content-Language header. TT does not
# auto-escape and this var is outside the SEC-2026-07 stash-escape block, so
# sanitise to a bare BCP-47-ish tag (letters + hyphen) - no quotes, angle
# brackets or CR/LF - closing a stored-XSS / header-injection path where a
# content-only write could otherwise execute script in every visitor's browser.
sub _render_lang {
    my ( $meta, %site_vars ) = @_;
    my $site_lang = $site_vars{lang} || 'en';
    my $page_lang = $meta->{lang}    || $site_lang;
    s/[^A-Za-z-]//g for $site_lang, $page_lang;
    $site_lang ||= 'en';
    $page_lang ||= 'en';
    return $site_lang, $page_lang;
}

# SM1012 S10: THE PAGE BODY'S TEMPLATE VARIABLES - cut from render_content,
# which passes what it has resolved by name: the page's meta and query, the
# site's and the page's tt vars, the manager facts (S8) and the languages (S9).
# The stash is built here, and only here: every escaped family enters at this
# one point (SM709, H5, SM869), beside its `_raw` twin (SM824). The request
# contexts (%AUTH_CONTEXT, %PAYMENT_CONTEXT, %PREVIEW_CONTEXT) are read as
# render_content read them.
sub _render_stash {
    my (%in) = @_;
    my ( $meta, $query, $editor_flag, $manager_caps, $scope_root, $home_domain, $my_scopes,
        $site_lang, $page_lang )
        = @in{qw(meta query editor_flag manager_caps scope_root home_domain my_scopes site_lang page_lang)};
    my %site_vars = %{ $in{site_vars} };
    my %page_vars = %{ $in{page_vars} };
    my @languages = @{ $in{languages} };
    my $query_esc = _esc_query_stash($query);    # SM869: see query => below

    my $private  = _front_matter_private();      # P13: the engine's lists stay out
    my $reserved = _front_matter_reserved();
    my $vars     = {
        %site_vars,
        %page_vars,
        %AUTH_CONTEXT,
        %PAYMENT_CONTEXT,
        %PREVIEW_CONTEXT,    # SM071: preview override wins over site layout/theme

        # SM709: ESCAPE THE AUTH VARIABLES HERE, and only here.
        #
        # Same treatment, and the same reasoning, as page_title below: the single
        # point they enter the stash, so every layout and every page emits them
        # safely even when it interpolates them without a `| html` filter - which
        # is what the shipped example in docs/auth.md does, and what an author
        # copying it will do.
        #
        # THEY WERE THE ONLY UNESCAPED FAMILY IN THE STASH. query.* is escaped
        # below (SM869; it was in parse_query_string), page_title/page_subtitle
        # four lines down; auth_* came
        # straight from X-Remote-* and was escaped nowhere. Two families sat here
        # with different safety properties, documented in one list, and nothing
        # told an author which was which.
        #
        # WHY NOT AT THE AUTH BOUNDARY, which is the obvious place and is wrong.
        # %AUTH_CONTEXT is ALSO the input to access control - the ACL identity and
        # its groups, _is_manager, the manager request gate, the editor flag above.
        # Escaping it there would test an escaped value against an unescaped users
        # file. That fails CLOSED, so it presents as a lockout rather than a leak,
        # and it is invisible to any test whose fixture user has no character
        # needing escaping - SM702's shape exactly. %AUTH_CONTEXT stays raw; only
        # this rendering copy is escaped.
        #
        # auth_user and auth_groups are constrained at creation ([a-zA-Z0-9_.-] and
        # [A-Za-z0-9_-]) so escaping them is a no-op today. They are escaped anyway:
        # one rule is cheaper to hold than a per-variable exception table, and the
        # constraint is not applied at all when a trusted proxy supplies the header.
        auth_user   => _esc_html( $AUTH_CONTEXT{auth_user} ),
        auth_name   => _esc_html( $AUTH_CONTEXT{auth_name} ),
        auth_email  => _esc_html( $AUTH_CONTEXT{auth_email} ),
        auth_groups => [
            map { _esc_html($_) } @{
                ref $AUTH_CONTEXT{auth_groups} eq 'ARRAY'
                ? $AUTH_CONTEXT{auth_groups}
                : []
            }
        ],
        # SEC-2026-07 (H5): escape the author-controllable front-matter fields
        # HERE, at the single point they enter the stash, so EVERY layout - the
        # bundled fallback/manager layouts AND every third-party/library layout
        # we cannot edit - emits them safely even when it interpolates them
        # without a `| html` filter. $meta->{...} stays raw for the search index
        # and page scan, which never render it as HTML.
        page_title    => _esc_html( $meta->{title} ),
        page_subtitle => _esc_html( $meta->{subtitle} ),

        # SM824 I1/I3 (ruled R7, 2026-10-02): THE DOCUMENTED EXCEPTION.
        #
        # The escaping above has no inverse, and a layout that wants to emit
        # JSON-LD needs the author's TEXT - `&amp;` inside a JSON string is wrong
        # rather than merely ugly, and entity-decoding in a template is the thing
        # the single escape point exists to avoid. So each escaped value gains a
        # `_raw` twin, and `| json` (below, in FILTERS) is how a layout encodes
        # one safely.
        #
        # THIS NAMES AN EXCEPTION THAT ALREADY EXISTED rather than introducing
        # one: `sections` has always reached the layout raw, three lines of this
        # same hash below. The ruling chose to document and bound that rather
        # than walk-and-escape `sections` - which would have held the invariant
        # everywhere and made JSON-LD from front matter unreachable, which is
        # what the reporter said it would do.
        #
        # THE RULE FOR A LAYOUT AUTHOR, and it is the whole contract: a `_raw`
        # value is NOT safe in HTML. Use the escaped name in markup, and the raw
        # name only inside `| json`. A `_raw` interpolated into a page body is an
        # XSS hole the author opened deliberately - which is why the plain names
        # keep the escaping and remain what every shipped layout uses.
        #
        # NOT an escalation, and the reporter graded it so first: only the page
        # author can write front matter, and that same author can already put raw
        # HTML in the page body.
        page_title_raw    => ( $meta->{title}    // '' ),
        page_subtitle_raw => ( $meta->{subtitle} // '' ),

        # SM459: the page's OWN custom front-matter, as page_<key>.
        #
        # A custom key was readable by every page EXCEPT the one that declared
        # it: the scan passes it through, the stash never did. So a fact needed
        # by an index AND by the page's own layout had to be written twice -
        # top-level for the scan, again inside tt_page_var - and the copies
        # drifted silently.
        #
        # ESCAPED, and that is why they arrive PREFIXED rather than bare. The
        # H5 note above is the constraint: author-controllable front matter is
        # escaped at this single point so every layout, including ones we do
        # not ship and cannot edit, emits it safely without needing `| html`.
        # Injecting bare custom keys into the stash would hand every such
        # layout an unescaped author string. page_<key> also cannot collide
        # with a site var or a tt_page_var, so nothing an author already
        # depends on changes meaning.
        #
        # Scalars, and (P13, ruled 2026-10-12) a list of scalars as a list, each
        # item escaped the same way - `categories: [a, b]` is page_categories,
        # [% FOREACH c IN page_categories %]. A hash has no escaped form.
        ( map {
                ( "page_$_" => ref $meta->{$_} eq 'ARRAY'
                    ? [ map { _esc_html($_) } grep { !ref } @{ $meta->{$_} } ]
                    : _esc_html( $meta->{$_} ) )
            }
            grep {
                !$reserved->{$_}
                    && !/^(?:tt_|_)/
                    && defined $meta->{$_}
                    && ( !ref $meta->{$_} || ( ref $meta->{$_} eq 'ARRAY' && !$private->{$_} ) )
            } keys %{$meta} ),

        # SM300: `subtitle` was doing three jobs at once - the visible
        # subheading, <meta name="description">, and the llms.txt description.
        # A page with a designed hero renders a subtitle directly above that
        # hero, so its author had to choose between a subheading they did not
        # want and NO description for search engines or AI clients. A live site
        # took the second, so its most important page had neither.
        #
        # meta_desc / meta_title OVERRIDE, and fall back to subtitle / title, so
        # every page that does not use them renders exactly as it did. Both were
        # already named as frozen front-matter in ADR 0008 and neither existed.
        page_meta_desc =>
            _esc_html( $meta->{meta_desc} // $meta->{subtitle} ),
        page_meta_title => _esc_html( $meta->{meta_title} // $meta->{title} ),
        page_author     => _esc_html( $meta->{author} ),

        # SM824 I1: the raw twins, under the contract documented above. The
        # fallbacks mirror the escaped pairs exactly - meta_desc falls back to
        # subtitle, meta_title to title - so a layout reading the raw name gets
        # the same VALUE it would have got escaped, never a different one.
        page_meta_desc_raw  => ( $meta->{meta_desc}  // $meta->{subtitle} // '' ),
        page_meta_title_raw => ( $meta->{meta_title} // $meta->{title}    // '' ),
        page_author_raw     => ( $meta->{author}     // '' ),
        page_modified       => $meta->{page_modified}     || '',
        page_modified_iso   => $meta->{page_modified_iso} || '',
        # SM796: escaped, like every other client-influenced value entering
        # this stash. It sat raw between two _esc_html'd neighbours and is
        # interpolated into an href by the shipped 402 and 403 pages. Live
        # reflection needs a front end that omits REDIRECT_URL and passes
        # breakout characters undecoded, which the shipped stacks do not - but
        # an invariant with one exception is not an invariant, and the next
        # reader of this block cannot tell the exception was considered.
        request_uri => _esc_html( $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '' ),
        # The visitor's address, via SM929's one definition: the direct peer unless
        # it is a trusted proxy, and then the rightmost hop of X-Forwarded-For that
        # a trusted peer did not contribute. Per-request, so only correct on a
        # `nocache: true` page - a cached page would bake the first visitor's.
        #
        # THIS USED TO TAKE THE FIRST HOP WHENEVER THE HEADER WAS PRESENT, with no
        # trust check at all, and the sanitiser below was the only defence - which
        # stopped markup reaching the page and did nothing about the address being
        # invented. Measured on a live site 2026-10-01: a request carrying
        # `X-Forwarded-For: 203.0.113.7` rendered 203.0.113.7. The sanitiser stays
        # as depth, on a value that is now a parsed address rather than a string.
        client_ip => do {
            my $ip = _request_address( _trusted_proxy_spec() );
            $ip =~ s/[^0-9A-Fa-f:.\[\]]//g;
            $ip;
        },
        # SM463: the docroot-relative KEY, never the absolute path.
        #
        # This stripped $DOCROOT off the source path with no boundary - and
        # the private store is "<docroot>-lazysite-private", so for a GATED
        # page `public_html` matched as a bare prefix and the result was
        # "-lazysite-private/intranet/tasks/index.md". The admin bar then put
        # that in /manager/edit?path=..., where it reached browser history,
        # bookmarks, Referer headers and screenshots - a server filesystem
        # path travelling in a URL.
        #
        # It also broke the editor: that spelling fails validate_path, which
        # joins it back onto $DOCROOT, so the link opened blank. ONE fault,
        # two symptoms, one fix.
        #
        # _content_rel is the existing translation and is boundary-safe: it
        # requires "$DOCROOT/" WITH the slash before falling back to the
        # private root, which is exactly the superset-sibling case the bare
        # strip got wrong. rel is what the ACL store, the blocklist and the
        # audit are all keyed on; full is where the bytes are, and only the
        # engine needs that.
        page_source => do {
            my $rel = _content_rel( $meta->{_md_path} // '' );
            defined $rel && length $rel ? "/$rel" : '';
        },
        # SM869: THE STASH'S COPY, ESCAPED HERE AND ONLY HERE - the single point
        # the family enters the stash (SM709), so a page or layout printing
        # [% query.x %] without a filter is safe. Already escaped, so a
        # `| html` on it escapes twice: the shipped pages no longer add one.
        # $query itself stays raw - it is %RENDER_QUERY, the engine's copy.
        query            => $query_esc,
        params           => $query_esc,
        lazysite_version => _lazysite_version(),    # asset cache-buster (?v=)

        # SM698: WHICH MANAGER STYLE. The name of a shipped sheet, never a path
        # - the value reaches an href, so a free-form string would let a config
        # edit point the manager at any URL. An unknown or absent name falls
        # back to `classic`, which is the sheet every instance had before this
        # setting existed, so a typo degrades to the status quo rather than to
        # an unstyled manager.
        manager_style   => _manager_style(),
        enabled_plugins => _enabled_plugins(),         # conditional manager nav
        manager_caps    => $manager_caps,              # SM154: gate the Domains nav
        scope_root      => $scope_root,                # SM154: a bound editor's root
        home_domain     => $home_domain,               # SM154: a bound editor's domain
        dav_scopes      => join( ',', @{$my_scopes} ), # SM157: multi-domain switcher list
        site_lang       => $site_lang,                 # SM179: the host's language
        page_lang       => $page_lang,                 # SM179: per-page override
        languages       => \@languages,                # SM179 P2: switcher/hreflang
        t               => {},                         # SM179 P5: layout chrome strings
        smtp_configured => ( -f "$LAZYSITE_DIR/forms/smtp.conf" ) ? 1 : 0, # gate emailed reset
            # SM099: a cache-safe sign in / out control. BOTH links ship hidden; the
            # injected auth-sync script reveals the right one from the lzs_session
            # cookie. Themes drop [% auth_control %] into their header instead of a
            # server-side [% IF authenticated %], which bakes the wrong state into the
            # cached HTML (the "shows Sign in while logged in" bug).
        auth_control =>
            '<a href="/login" data-ls-auth-in class="ls-auth ls-auth-in" style="display:none">Sign in</a>'
            . '<a href="/cgi-bin/lazysite-auth.pl?action=logout" data-ls-auth-out class="ls-auth ls-auth-out" style="display:none">Sign out</a>',
        sections => $meta->{sections} || [],    # D035 Phase 3: data-driven pages
        editor   => $editor_flag,
        year     => sprintf( '%04d', (localtime)[5] + 1900 ),
        search_enabled => ( -f "$DOCROOT/search-results.md" || -f "$DOCROOT/search-results.url" ) ? 1 : 0,
    };
    return $vars;
}

# SM1012 S11: THE BODY THROUGH THE TEMPLATE, ITS CODE PROTECTED - cut from
# render_content. Code blocks become placeholders, a TAGS directive is made a
# comment, the body is processed (the raw body on a template error), the
# blocks come back in one pass, and a block the render multiplied is said out
# loud. The `last` is its own loop's.
#
# Protect <pre><code> blocks and inline <code> elements from TT processing
sub _tt_process_protected {
    my ( $tt, $html_body, $vars ) = @_;
    my $protected_body = $html_body;
    my @code_blocks;
    my $cbk = _placeholder_key($protected_body);    # SM967: a value cannot spell it
    $protected_body =~ s{(<pre><code[^>]*>)(.*?)(</code></pre>)}{
        my $placeholder = "CODEBLOCK${cbk}_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;
    $protected_body =~ s{(<code>)(.*?)(</code>)}{
        my $placeholder = "CODEBLOCK${cbk}_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;

    # SM968: A PAGE BODY CANNOT CHANGE THE TEMPLATE TAGS.
    #
    # `[% TAGS {{ }} %]` switches the tags for the rest of the body. The form
    # prefill and outcome banner write the visitor's text into this body BEFORE
    # it is parsed, and _tt_inert makes it inert by encoding `[` and `%` - which
    # holds only while the tags are `[% %]`. After a TAGS line, `?x={{ site_name }}`
    # prefilled the site's own value: the visitor's text was the template. No
    # escape can cover every tag pair an author might choose, so the directive
    # is made a comment here, at the one point every body is parsed, and the
    # author is told. Nothing shipped uses it; a layout keeps the ability.
    if ( $protected_body =~ s/\[%([-=~+]?\s*)(?=TAGS\s)/[%#$1/g ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'a page body set TAGS - the directive is ignored: a page body uses [% %] tags' );
    }

    my $processed_body = '';
    $tt->process( \$protected_body, $vars, \$processed_body )
        or do {
        log_event( "ERROR", $ENV{REDIRECT_URL} // "-", "template error, using raw content", error => $tt->error() );
        $processed_body = $protected_body;
        };

    # SM931, RULED 2026-10-01: RESTORE IN ONE PASS, NOT ONE SUBSTITUTION PER BLOCK.
    #
    # MEASURED ON A LIVE PAGE: 27 rows rendered from a `json:` file, each carrying a
    # token in an inline code span, published the literal string `CODEBLOCK_0_END` in
    # 22 customer-facing cells. The body is protected ONCE, before TT; TT then
    # duplicated the placeholder - once per loop iteration - and a substitution
    # without /g gave exactly one copy back. The other 22 were the engine's own
    # internal placeholder, on a page that was otherwise completely correct, so
    # nothing about the output invited suspicion except the cells themselves.
    #
    # THE REPORTED FIX WAS `/g` AND IT IS THE WRONG ONE. The loop is the problem,
    # not the missing flag: each iteration rescans text that earlier iterations
    # inserted, so a protected block whose own text CONTAINS a later placeholder -
    # the realistic instance being this project's own documentation of this
    # mechanism - gets that text substituted too. One pass with a callback fixes the
    # leak AND removes the ordering hazard, because the regex engine resumes
    # scanning after inserted text rather than over it.
    #
    # A PLACEHOLDER WITH NO BLOCK IS LEFT ALONE, never replaced with the empty
    # string: an author who writes CODEBLOCK_7_END in their own prose keeps it, and
    # a genuine internal leak stays visible to the check below rather than being
    # quietly swallowed.
    $processed_body =~ s{(CODEBLOCK\Q$cbk\E_(\d+)_END)}
                        { defined $code_blocks[$2] ? $code_blocks[$2] : $1 }gse;

    # SM931 item 2: SAY SO WHEN THE RENDER MULTIPLIED PROTECTED CONTENT.
    #
    # One pass stops the engine's placeholder reaching the page, and it cannot make
    # the author's code span interpolate: inside a loop a span cannot be both
    # protected from TT and expanded by it, protecting it is the right default, and
    # the honest position is that the combination is unsupported. So the author now
    # sees their own `[% ... %]` repeated, which they can act on - but only if
    # somebody tells them where it came from. This is the difference between a
    # five-minute diagnosis and finding it by reading rendered HTML, which is how it
    # was found. SM932 forwards WARN and above to syslog by default, so this has a
    # sink that does not depend on where a CGI's STDERR goes.
    if (@code_blocks) {
        for my $i ( 0 .. $#code_blocks ) {
            my $count = () = $processed_body =~ /\Q$code_blocks[$i]\E/g;
            next if $count <= 1;
            log_event(
                'WARN',
                $ENV{REDIRECT_URL} // '-',
                'the render multiplied a protected code block, so its template '
                    . 'directives are published unrendered - a code span inside a '
                    . 'loop cannot be both protected from the template and expanded '
                    . 'by it',
                block  => $i,
                copies => $count,
            );
            last;
        }
    }
    return $processed_body;
}

sub render_content {
    my ( $meta, $html_body, $query, $before_render ) = @_;
    $query //= {};

    my $tt = _tt_engine();    # SM1012 S7

    my %site_vars = resolve_site_vars();
    my %page_vars = resolve_tt_vars( $meta->{tt_page_var} || {} );

    my $groups_ref = $AUTH_CONTEXT{auth_groups};
    my $groups_str = ref $groups_ref eq 'ARRAY' ? join( ',', @$groups_ref ) : ( $groups_ref // '' );
    my $editor_flag = _is_manager( \%site_vars, $AUTH_CONTEXT{auth_user} // '', $groups_str ) ? 1 : 0;

    my ( $manager_caps, $scope_root, $home_domain, $my_scopes )
        = _render_manager_facts($groups_str);    # SM1012 S8

    my ( $site_lang, $page_lang ) = _render_lang( $meta, %site_vars );    # SM1012 S9
    $RESPONSE_LANG = $page_lang;
    # SM179 P2: the language-set switcher data ({ lang, url, current, exists }),
    # empty unless this host is in a lang_group with siblings. Layouts render a
    # switcher and hreflang from it.
    my @languages = _language_set(
        ( $site_vars{alias_host} // '' ),
        ( $site_vars{lang_group} // '' ),
        ( $ENV{REDIRECT_URL}     // $ENV{REQUEST_URI} // '/' ),
    );

    my $vars = _render_stash(    # SM1012 S10
        meta         => $meta,
        query        => $query,
        editor_flag  => $editor_flag,
        manager_caps => $manager_caps,
        scope_root   => $scope_root,
        home_domain  => $home_domain,
        my_scopes    => $my_scopes,
        site_lang    => $site_lang,
        page_lang    => $page_lang,
        site_vars    => \%site_vars,
        page_vars    => \%page_vars,
        languages    => \@languages,
    );

    # SM249: the variables are now complete, and the body has not been rendered
    # yet - so this is the one point at which a caller can add to them and have
    # the page body see them.
    #
    # render_template uses it to resolve the layout and the active theme here
    # rather than after the body render, which is why [% theme_assets %] now
    # works in a page body. It used to resolve in the step BETWEEN this function
    # returning and the layout render, so a page body referencing it got an
    # empty string with no error - the variable existed by the time the layout
    # was rendered and never during the body.
    #
    # Callers that render a body with NO layout (raw pages, api pages) pass
    # nothing and are unaffected: no layout means no theme, and theme_assets
    # stays absent for them, which is the correct answer rather than a
    # misleading one.
    $before_render->($vars) if $before_render;

    my $processed_body = _tt_process_protected( $tt, $html_body, $vars );    # SM1012 S11

    return ( $processed_body, $vars );
}

1;
