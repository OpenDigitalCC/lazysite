package main;

# lazysite-processor/layout.pm - layout, theme and injection: the step that
# wraps a rendered body in its layout and edits the finished HTML.
#
# HOLDS   render_template(), which renders the body (render_content) and then
#         its layout, or the fallback layout; the layout and theme resolution -
#         get_layout_path, fetch_remote_layout, resolve_theme,
#         _layout_default_theme, _layout_strings, resolve_layout_vars,
#         _section_indexes, _section_theme, _theme_version,
#         _render_fallback_layout; generate_theme_css (the processor's theme
#         token generator, lint 61); the injectors that edit the finished
#         HTML - _inject_auth_sync, _inject_data_helper, _inject_meta,
#         _inject_canonical, and the admin bar (_inject_admin_bar,
#         _admin_bar_choice, _inject_admin_bar_live); _enabled_plugins,
#         _manager_style, _asset_fingerprint; _engine_mtime and
#         _lazysite_version with their per-process memos.
# OWNS    which layout and theme a page renders in; the theme's custom
#         properties as CSS; what the engine adds to a finished page (auth
#         sync, data helper, generator meta, canonical link, admin bar); the
#         engine version and install time a render is keyed and stamped with.
# CALLS   render_content, _tt_render, _cgi_can_write, _content_abs,
#         _content_rel, _esc_html, _is_manager, _json_filter, _markdown_filter,
#         _url_safe_filter, fetch_url, log_event (the script and its parts);
#         decode_json, sha256_hex, dirname and make_path (imported by the
#         script's `use`, before its parts load).
# READS   $DOCROOT, $LAZYSITE_DIR, $LAYOUT_DIR, $LAYOUT_CACHE_DIR,
#         $MANAGER_LAYOUT, $FALLBACK_LAYOUT, $REMOTE_TTL, $REQUEST_CROOT,
#         $TT_COMPILE_DIR, %AUTH_CONTEXT (the script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S17). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $LAYOUT_DIR, $LAYOUT_CACHE_DIR, $MANAGER_LAYOUT, $FALLBACK_LAYOUT, $REMOTE_TTL, $REQUEST_CROOT, $TT_COMPILE_DIR, %AUTH_CONTEXT );

# --- Layout, theme and injection ---
#
# Layout and theme resolution (local and remote), render_template and the
# _inject_* family that edits the finished HTML.

sub get_layout_path {
    my ( $meta, $vars ) = @_;

    # Manager path gets its own dedicated template. D013: manager lives
    # outside layouts/ entirely — it's internal plumbing, not a
    # themeable layout.
    my $manager_path = $vars->{manager_path} || '/manager';
    # Match the URI resolution used for content (and request_uri TT var):
    # behind the auth wrapper, REDIRECT_URL may be unset while REQUEST_URI
    # carries the real path, so the manager-layout check must fall back too.
    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';
    if ( index( $uri, $manager_path ) == 0 ) {
        return ( $MANAGER_LAYOUT, undef ) if -f $MANAGER_LAYOUT;
        return ( undef,           undef );
    }

    my $name = $meta->{layout} || $vars->{layout} || '';

    if ($name) {
        # Remote layout: URL in layout key. Remote keeps the flat
        # /lazysite-assets/CACHE_KEY/ asset convention (D013 decision:
        # remote is a single bundled package).
        if ( $name =~ m{^https?://} ) {
            my ( $cached, $theme_key ) = fetch_remote_layout($name);
            return ( $cached, $theme_key ) if $cached;
            log_event( "WARN", $ENV{REDIRECT_URL} // "-",
                "remote layout fetch failed", name => $name );
            return ( undef, undef );
        }

        $name =~ s/[^a-zA-Z0-9_-]//g;
        $name ||= '';

        if ($name) {
            # D013: layouts/NAME/layout.tt. No flat-template fallback.
            my $layout_path = "$LAYOUT_DIR/$name/layout.tt";
            return ( $layout_path, $name ) if -f $layout_path;

            log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                'layout not found, using fallback', layout => $name );
        }
    }

    return ( undef, undef );
}

# D013: resolve the theme for a given (validated) layout. Returns a hash
# with theme_name, theme_data (decoded theme.json), and is_active (true
# iff theme.json's layouts[] contains the layout name). When the theme
# cannot be loaded or is incompatible, returns an empty hash and the
# caller proceeds with no theme (no theme_assets, no theme_css).
sub resolve_theme {
    my ( $layout_name, $theme_name ) = @_;
    return {} unless defined $layout_name && length $layout_name;
    return {} unless defined $theme_name  && length $theme_name;

    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    return {} unless length $theme_name;

    my $theme_dir  = "$LAYOUT_DIR/$layout_name/themes/$theme_name";
    my $theme_json = "$theme_dir/theme.json";
    return {} unless -f $theme_json;

    open my $fh, '<:utf8', $theme_json or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'cannot open theme.json', path => $theme_json );
        return {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    unless ( ref $data eq 'HASH' ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'invalid theme.json', path => $theme_json );
        return {};
    }

    # Strict: theme must declare compatibility with the active layout.
    my $layouts = $data->{layouts};
    unless ( ref $layouts eq 'ARRAY' && grep { $_ eq $layout_name } @$layouts ) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
            'theme not declared for layout; rendering without theme styling',
            theme => $theme_name, layout => $layout_name );
        return {};
    }

    return {
        theme_name => $theme_name,
        theme_data => $data,
        is_active  => 1,
    };
}

# SM179 P5: chrome strings for a layout. layouts/<layout>/strings/<lang>.json,
# when present, overlays strings/en.json (the English base) so a layout writes
# [% t.footer_credit %] and any key missing from the site language falls back to
# English rather than vanishing. Layout-dir confined (name + lang code both
# validated); an absent strings/ directory yields {} and changes nothing.
sub _layout_strings {
    my ( $layout, $lang ) = @_;
    return {} unless defined $layout && $layout =~ /^[A-Za-z0-9_-]+$/;
    my $dir = "$LAYOUT_DIR/$layout/strings";
    return {} unless -d $dir;

    my $load = sub {
        my ($code) = @_;
        return {} unless defined $code && $code =~ /^[A-Za-z-]+$/;
        my $path = "$dir/$code.json";
        return {} unless -f $path;
        open my $fh, '<:raw', $path or return {};
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $data = eval { decode_json($raw) };
        return ( ref $data eq 'HASH' ) ? $data : {};
    };

    my %t = %{ $load->('en') };    # English base supplies the fallback keys
    if ( defined $lang && length $lang && lc $lang ne 'en' ) {
        my $over = $load->($lang);
        @t{ keys %$over } = values %$over;    # the site language wins per key
    }
    return \%t;
}

# SM: the layout's declared default theme (from its layout.json), used as the
# asset fallback when no compatible theme is active - so a preview/per-page layout
# still resolves theme_assets to a sensible mirror instead of rendering unstyled.
sub _layout_default_theme {
    my ($layout) = @_;
    return '' unless defined $layout && $layout =~ /^[A-Za-z0-9_-]+$/;
    open my $jf, '<:utf8', "$LAYOUT_DIR/$layout/layout.json" or return '';
    my $raw = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($raw) };
    my $dt   = ( ref $meta eq 'HASH' ) ? ( $meta->{default_theme} // '' ) : '';
    return ( $dt =~ /^[A-Za-z0-9_-]+$/ ) ? $dt : '';
}

# D013: generate a <style> block of CSS custom properties from a theme's
# config object. Naming convention: --theme-GROUP-KEY. Only scalar
# (non-ref) values are emitted — a theme author using a nested object
# under a group key is a shape error and is skipped silently.
sub generate_theme_css {
    my ($theme_data) = @_;
    return '' unless ref $theme_data eq 'HASH';
    my $config = $theme_data->{config};
    return '' unless ref $config eq 'HASH';

    my @lines;
    for my $group ( sort keys %$config ) {
        my $group_val = $config->{$group};
        next unless ref $group_val eq 'HASH';
        next unless $group =~ /^[A-Za-z0-9_-]+$/;
        for my $key ( sort keys %$group_val ) {
            my $v = $group_val->{$key};
            next if ref $v;
            next unless $key =~ /^[A-Za-z0-9_-]+$/;
            my $safe = defined $v ? $v : '';
            # Strip anything that could break out of a declaration — the
            # theme schema says values are strings, not CSS expressions.
            $safe =~ s/[;\{\}<>]//g;
            push @lines, "  --theme-$group-$key: $safe;";
        }
    }
    return '' unless @lines;
    return "<style>\n:root {\n" . join( "\n", @lines ) . "\n}\n</style>";
}

sub fetch_remote_layout {
    my ($url) = @_;

    # Derive a safe cache filename from the URL
    my $cache_key = $url;
    $cache_key =~ s{https?://}{};
    $cache_key =~ s{[^a-zA-Z0-9_-]}{_}g;
    $cache_key = substr( $cache_key, 0, 200 );    # limit length

    my $cache_path = "$LAYOUT_CACHE_DIR/$cache_key.tt";

    # Serve from cache if fresh (use $REMOTE_TTL - same as remote pages)
    if ( -f $cache_path ) {
        my @st = stat($cache_path);
        if ( @st && ( time() - $st[9] ) < $REMOTE_TTL ) {
            return ( $cache_path, $cache_key );
        }
    }

    # Fetch remote layout
    my $content = fetch_url($url);
    unless ( defined $content && length $content ) {
        # Return stale cache if available
        return -f $cache_path ? ( $cache_path, $cache_key ) : ( undef, undef );
    }

    # Write to cache
    make_path($LAYOUT_CACHE_DIR) unless -d $LAYOUT_CACHE_DIR;
    open( my $fh, '>:utf8', $cache_path ) or do {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "cannot write layout cache", path => $cache_path, error => $! );
        return ( undef, undef );
    };
    print $fh $content;
    close $fh;

    # Attempt to fetch theme.json manifest from same directory
    my $base_url = $url;
    $base_url =~ s{/[^/]+$}{};    # strip filename to get directory URL
    my $manifest_url = "$base_url/theme.json";
    my $manifest_raw = fetch_url($manifest_url);

    if ( defined $manifest_raw ) {
        my $manifest = eval { decode_json($manifest_raw) };
        if ( $manifest && ref $manifest->{files} eq 'ARRAY' ) {
            my $asset_dir = "$DOCROOT/lazysite-assets/$cache_key";
            make_path($asset_dir) unless -d $asset_dir;

            for my $file ( @{ $manifest->{files} } ) {
                # D013: remote packages now point at a layout.tt URL.
                # Still accept legacy view.tt in the files list so a
                # transitional manifest doesn't re-fetch it.
                next if $file eq 'layout.tt' || $file eq 'view.tt';
                next if $file =~ /\.\./;                              # no traversal

                my $file_url     = "$base_url/$file";
                my $file_content = fetch_url($file_url);
                next unless defined $file_content;

                my $file_path = "$asset_dir/$file";
                my $file_dir  = dirname($file_path);
                make_path($file_dir) unless -d $file_dir;

                open( my $afh, '>:raw', $file_path ) or next;
                print $afh $file_content;
                close $afh;
            }
        }
    }

    return ( $cache_path, $cache_key );
}

# SM812: the section index pages above a page, nearest first - every index.md
# between the page's own directory and the request's content root, NOT the
# content root's own index.md.
#
# A section describes itself on its index page (SM656 reads admin_bar: there),
# so a theme set once on docs/index.md dresses everything under docs/. The ROOT
# index is left out on purpose: it is the home page, which routinely wears a
# treatment of its own, and a home-page theme restyling the whole site would be
# the surprise this feature exists to remove. The site's theme is set in
# lazysite.conf, which is where that decision already lives.
#
# Relative to the content root, not the docroot, so a domain's own index is its
# root - never a section of the primary site. Each index resolves through the
# private store as the page does (SM286), so a gated section still has one.
sub _section_indexes {
    my ($md_path) = @_;
    return () unless defined $md_path && length $md_path;
    my $rel = _content_rel($md_path);
    return () unless defined $rel;
    my $croot = $REQUEST_CROOT // $DOCROOT;
    my $top   = ( $croot eq $DOCROOT ) ? '' : _content_rel($croot);
    return () unless defined $top;

    my @out;
    my $dir = $rel;
    while ( $dir =~ s{/[^/]*\z}{} ) {
        last if length $top && index( $dir, "$top/" ) != 0;
        push @out, _content_abs("$DOCROOT/$dir/index.md");
    }
    return @out;
}

# The theme a page inherits from its nearest section that names one, or undef.
# Sanitised as the page's own key is, by _peek_md.
sub _section_theme {
    my ($md_path) = @_;
    for my $idx ( _section_indexes($md_path) ) {
        my $theme = _peek_md($idx)->{theme};
        return $theme if defined $theme;
    }
    return undef;
}

# SM249: resolve the layout and the active theme INTO $vars.
#
# Split out of render_template and moved ahead of the body render so that
# [% theme_assets %], [% theme %], [% theme_css %], [% layout_name %] and [% t %]
# are available to a page body, not only to the layout. Previously an author who
# wrote [% theme_assets %]/hero.jpg in a page got an empty string and no error,
# because the variable was populated in the step between the body render and the
# layout render - it existed for the layout and never for the body.
#
# Returns ( $layout, $layout_key ) so the caller still knows which template to
# render and whether it was remote.
#
# get_layout_path can fetch a remote layout over the network, so it must be
# called ONCE per request. That is why this moved rather than being duplicated.
sub resolve_layout_vars {
    my ( $meta, $vars ) = @_;

    my ( $layout, $layout_key ) = get_layout_path( $meta, $vars );

    # D013: $layout_key is the token used for asset URL derivation.
    # - Local layout name (e.g. "default") — asset dir becomes
    #   /lazysite-assets/LAYOUT/THEME/ once a theme resolves.
    # - Remote URL's sanitised cache key — asset dir stays flat at
    #   /lazysite-assets/CACHE_KEY/ (remote is a single bundled
    #   package; D013 nested structure does not apply).
    # - undef for the manager path and for the embedded fallback.
    my $is_remote_layout = defined $layout
        && index( $layout, $LAYOUT_CACHE_DIR ) == 0;

    if ( defined $layout_key && $is_remote_layout ) {
        # Remote: flat asset path, no theme resolution (§3 decision).
        # Clear theme/theme_css so templates don't try to index into
        # the conf string under theme.config.
        $vars->{theme_assets} = "/lazysite-assets/$layout_key";
        $vars->{theme}        = {};
        $vars->{theme_css}    = '';
    }
    elsif ( defined $layout_key ) {
        # Local layout. Expose layout_name and resolve the active theme
        # against it, populating theme_name, theme, theme_assets, and
        # theme_css when the theme is compatible. When no theme (or an
        # incompatible one) is active, $vars->{theme} is replaced with
        # an empty hash so [% theme.config.foo %] renders empty rather
        # than trying to index into the raw conf string.
        $vars->{layout_name} = $layout_key;
        # SM179 P5: load this layout's chrome strings for the site language into
        # [% t %] (English base overlaid by the site language). No strings/ dir =>
        # {}; layouts that don't localise are unaffected.
        $vars->{t} = _layout_strings( $layout_key, $vars->{site_lang} // 'en' );
        # SM120: a page may pin a theme via front matter (theme:), sanitised the
        # same way as layout:; falls back to the active/site theme.
        #
        # SM275: this said "preview-only", which it is not and never was. The
        # pin is a general per-page override - FEATURES.md documents it that
        # way and the code treats it that way - so the comment described a
        # narrower feature than the one below it. A wrong-but-plausible
        # statement costs more than an absent one: a reader trusting it would
        # not reach for the pin on a page they meant to keep.
        # resolve_theme still gates on layout compatibility, so an incompatible pin
        # renders as no theme rather than breaking.
        #
        # SM812: precedence is the page, then its nearest section's index, then
        # the site or domain theme. An inherited theme is treated exactly as a
        # pin - including an incompatible one - so moving the key from each page
        # to the section's index changes nothing about how a page renders.
        my $page_theme = $meta->{theme};
        $page_theme = _section_theme( $meta->{_md_path} ) // $vars->{theme}
            unless defined $page_theme && $page_theme =~ /^[A-Za-z0-9_-]+$/;
        my $info = resolve_theme( $layout_key, $page_theme );
        if ( $info->{is_active} ) {
            $vars->{theme_name}   = $info->{theme_name};
            $vars->{theme}        = $info->{theme_data};
            $vars->{theme_assets} = "/lazysite-assets/$layout_key/" . $info->{theme_name};
            # SM352: prefer the mirrored FILE. The tokens are written into the
            # theme's own asset mirror at activation and install, so the page
            # links them instead of carrying a <style> block - the last inline
            # block on the site side, and the one that looked like it needed a
            # nonce because its content is per-theme.
            #
            # It never did: the values come from theme.json, so they are the
            # same on every page of every domain this instance serves.
            #
            # THE INLINE PATH REMAINS for a site whose mirror predates this.
            # Falling back to the block is what stops an upgrade unstyling a
            # site that has not re-mirrored yet - SM365 is exactly the lesson
            # that an upgrade does not refresh what it does not touch. It goes
            # away on the next activation, and t/lint/56 still counts it,
            # because a fallback nobody can see is a fallback nobody removes.
            my $tokens = "$DOCROOT$vars->{theme_assets}/theme-tokens.css";
            $vars->{theme_css}
                = -f $tokens
                ? '<link rel="stylesheet" href="'
                . $vars->{theme_assets}
                . '/theme-tokens.css?v=' . _asset_fingerprint($tokens) . '">'
                : generate_theme_css( $info->{theme_data} );
        }
        else {
            $vars->{theme}     = {};
            $vars->{theme_css} = '';
            # SM: no compatible theme is active for this (previewed or per-page)
            # layout. Fall theme_assets back to the layout's declared default_theme
            # mirror if it is installed, so the page loads that theme's stylesheet
            # instead of rendering unstyled - no per-layout [% ELSE %] link needed.
            my $dt = _layout_default_theme($layout_key);
            if ( length $dt && -d "$DOCROOT/lazysite-assets/$layout_key/$dt" ) {
                $vars->{theme_assets} = "/lazysite-assets/$layout_key/$dt";
            }
        }
    }
    else {
        $vars->{theme}     = {};
        $vars->{theme_css} = '';
    }

    # SM830: [% theme_version %], the cache key for whatever theme_assets names,
    # so a layout links `main.css?v=[% theme_version %]` and an edited theme is a
    # new URL. Always set - the engine version where there is no mirror - so a
    # template can use it unconditionally.
    $vars->{theme_version} = _theme_version( $vars->{theme_assets} );

    return ( $layout, $layout_key );
}

# SM830: the mirror's own fingerprint, written by the manager when it writes the
# mirror (Manager::Themes::_write_mirror_fingerprint) - a hash over every file,
# so it moves when the bytes do and not on a re-activation of identical ones.
# A mirror written before 0.13.13 has none until its next activation, and the
# answer there is the engine version, which is what these links carried before.
sub _theme_version {
    my ($assets) = @_;
    return _lazysite_version() unless defined $assets && $assets =~ m{\A/lazysite-assets/[A-Za-z0-9_/-]+\z};
    if ( open my $fh, '<', "$DOCROOT$assets/.fingerprint" ) {
        my $v = <$fh> // '';
        close $fh;
        return $1 if $v =~ /\A([0-9a-f]{12})\s*\z/;
    }
    return _lazysite_version();
}

# The built-in fallback layout, rendered into $$out_ref. Written out twice
# inside render_template, verbatim - once for "no layout resolved" and once for
# "the resolved layout failed to render" - so it is one helper now. Returns 1 on
# success; on either failure it logs the same event the inline copies logged and
# returns 0, and the caller returns the unwrapped body exactly as before.
sub _render_fallback_layout {
    my ( $vars, $out_ref ) = @_;

    my $tt_fallback = Template->new(
        ENCODING  => 'utf8',
        EVAL_PERL => 0,
        FILTERS   => { url_safe => \&_url_safe_filter },    # SM970
        )
        or do {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance' );
        return 0;
        };

    $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, $out_ref )
        or do {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error() );
        return 0;
        };

    return 1;
}

sub render_template {
    my ( $meta, $html_body, $query ) = @_;
    $query //= {};

    # SM249: the layout and theme are resolved by the hook below, which
    # render_content calls once the variables are complete and BEFORE it renders
    # the body - so the body sees theme_assets and friends. The hook runs
    # exactly once per render_content call, so the remote-layout fetch inside
    # get_layout_path still happens at most once per request.
    my ( $layout, $layout_key );
    my ( $processed_body, $vars ) = render_content(
        $meta, $html_body, $query,
        sub { ( $layout, $layout_key ) = resolve_layout_vars( $meta, $_[0] ) },
    );

    # SM964: NO SECOND INCLUDE PASS. There was one here, over the template's
    # OUTPUT, meant for `::: include` blocks whose path is a template variable.
    # It never served that: Markdown has wrapped such a block in a paragraph by
    # now, so it did not match, and the docs say these blocks are not resolved.
    # What it DID match was a block that arrived as data - a visitor-written
    # table row listed on a public page could pull an unpublished file, or a
    # sign-in-only page's body, into the output (the SM869 adversarial review).
    # A path taken from data would hand the choice of file to whoever writes the
    # data, so the feature is not built either. t/unit/data/64.

    $vars->{content} = $processed_body;
    my $output = '';

    if ( !defined $layout ) {
        # No layout found - use built-in fallback directly
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "layout not found, using fallback" );
        _render_fallback_layout( $vars, \$output )
            or return $processed_body;

        # Head injection must be layout-independent (SM112 generator meta,
        # SM151 per-host canonical): the real-layout path does it at output
        # time below, so the no-layout fallback path must too, or a fallback
        # site would silently lose its generator meta and its canonical link.
        $output = _inject_meta( $output, $vars );
        $output = _inject_canonical( $output, $vars );

        # DP-3b, for the reason stated immediately above and worth stating
        # once more because it caught me: a no-layout site would otherwise
        # render a data region and never load the script that fills it. The
        # chrome bundle does not need this - the fallback template carries its
        # tag inline - but this one is conditional, so it cannot be in a
        # template that does not know what the body contains.
        $output = _inject_data_helper($output);

        # Admin bar injected per-request at output time, not cached (see note below).
        return $output;
    }

    # Determine if layout is remote (from cache dir) - sandbox it. Derived from
    # $layout rather than carried out of resolve_layout_vars: it is the same
    # one-line test, and passing it back would be a third return value that
    # exists only to avoid retyping it.
    my $is_remote = defined $layout && index( $layout, $LAYOUT_CACHE_DIR ) == 0;

    # D035 content components: resolve [% INCLUDE 'components/NAME.tt' %] against
    # the active layout's own directory, and expose a `markdown` filter so a
    # component can render Markdown fields. Content authors never write TT;
    # components ship inside the trusted layout package and EVAL_PERL stays off.
    my $component_dir = ( defined $layout && length $layout && -e $layout )
        ? dirname($layout) : undef;

    my %tt_opts = (
        ABSOLUTE     => 1,                 # needed to read cache path
        ENCODING     => 'utf8',
        EVAL_PERL    => 0,                 # L-2: no embedded Perl
        INCLUDE_PATH => $component_dir,    # D035: layout-local components
        FILTERS      => {
            markdown => \&_markdown_filter,
            json     => \&_json_filter,
            url_safe => \&_url_safe_filter,    # SM970
        },
        COMPILE_DIR => $TT_COMPILE_DIR,        # P-4
        COMPILE_EXT => '.ttc',                 # P-4
    );
    $tt_opts{RELATIVE} = 0 if $is_remote;      # sandbox remote layouts

    # Try specified layout (with the compile-cache-immune helper - an
    # unwritable cache/tt silently knocked every page down to the fallback
    # layout on TT 2.x, and 500s outright on TT 3.x; field-hit 2026-07-09).
    my ( $layout_ok, $layout_err ) =
        _tt_render( \%tt_opts, $layout, $vars, \$output );

    $layout_ok
        or do {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'layout error, using fallback', layout => $layout, error => $layout_err );
        $output = '';

        # Try built-in fallback layout
        _render_fallback_layout( $vars, \$output )
            or return $processed_body;

        # The manager is operator-facing and auth-gated: surface the
        # failure loudly instead of silently degrading the admin UI to
        # the fallback chrome (public pages keep the silent fallback -
        # a template error must not leak to visitors).
        if ( defined $layout && $layout eq $MANAGER_LAYOUT ) {
            my $e = $layout_err;
            $e =~ s/&/&amp;/g; $e =~ s/</&lt;/g; $e =~ s/>/&gt;/g; $e =~ s/"/&quot;/g;
            my $banner =
                '<div id="ls-layout-error" style="background:#b00020;'
                . 'color:#fff;padding:10px 14px;font:14px/1.4 system-ui,sans-serif;">'
                . '<strong>Manager layout failed to render</strong> - the built-in '
                . 'fallback layout is in use. Error: ' . $e
                . ' &mdash; run <code>tools/lazysite-check.pl --fix</code> '
                . 'against this docroot.</div>';
            $output =~ s/(<body[^>]*>)/$1$banner/i
                or $output = $banner . $output;
        }
        };

    # SM270: say so the moment the site stops being writable, not at the next save.
    #
    # Hestia's v-rebuild-web-domain re-applies its OWN docroot permissions -
    # 2751: setgid, no group write - and a rebuild driven through the control
    # panel (an SSL renewal, an alias change, a panel upgrade) never reaches the
    # lazysite deploy that repairs that. The ordering fix and the end-of-run
    # repair both help only when lazysite RUNS, so a stable-channel site that
    # takes no deploy for a month is unwritable for a month. SM270 was fixed
    # once by ordering and recurred three releases later for exactly this.
    #
    # The engine cannot stop the panel. What it can do is stop the condition
    # being INVISIBLE - the changelog's own words were "nothing notices until
    # the manager fails to save", and this is that notice, arriving on the next
    # manager page load instead.
    #
    # Manager pages only: it is operator-facing and auth-gated, so a public
    # visitor pays nothing and learns nothing. Ownership+mode arithmetic, no
    # write attempt and no fork - the same reasoning lazysite-check uses,
    # because -w answers for the process's real ability and that is what is
    # being questioned.
    if ( defined $layout && $layout eq $MANAGER_LAYOUT ) {
        my @unwritable = grep { !_cgi_can_write($_) } ( $DOCROOT, $LAZYSITE_DIR );
        if (@unwritable) {
            my $where = join ', ', map { my $p = $_; $p =~ s/^\Q$DOCROOT\E\/?/./; $p } @unwritable;
            my $host = $ENV{HTTP_HOST} // '';
            $host =~ s/[^A-Za-z0-9.:-]//g;
            my $banner =
                '<div id="ls-perms-warning" style="background:#8a5300;color:#fff;'
                . 'padding:10px 14px;font:14px/1.4 system-ui,sans-serif;">'
                . '<strong>This site is not writable by the web server.</strong> '
                . 'Saving anything here will fail. Affected: <code>'
                . $where
                . '</code>. This usually follows a control-panel rebuild, which '
                . 're-applies its own permissions. Repair it with <code>sudo '
                . 'lazysite repair'
                . ( length $host ? " --domain $host" : ' --docroot &lt;docroot&gt;' )
                . '</code>.</div>';
            $output =~ s/(<body[^>]*>)/$1$banner/i
                or $output = $banner . $output;
        }
    }

    # SM112: identify the generator (+ optional author/description) in the head,
    # regardless of which layout rendered the page.
    $output = _inject_meta( $output, $vars );

    # SM151: per-host canonical link, so each domain is a first-class site to
    # search engines. Driven by the resolved (per-host) site_url - a declared,
    # stable value, never the request Host - so it is safe to bake into the
    # per-host page cache. Skipped when a layout already emitted a canonical or
    # site_url is unset.
    $output = _inject_canonical( $output, $vars );

    # SM099: client-side sign-in/out so a shared cached page never shows the wrong
    # auth control. Toggles [data-ls-auth-in]/[data-ls-auth-out] from the lzs_session
    # marker cookie. Injected on every page so any layout can opt in with those attrs.
    $output = _inject_auth_sync($output);
    $output = _inject_data_helper($output);

    # NOTE: the manager admin bar is deliberately NOT injected here. It is
    # per-viewer (manager-only) and this output is written to the shared page
    # cache - baking it in would leak it to anonymous visitors, or hide it from
    # managers, depending on who filled the cache. It is injected per-request at
    # output time instead (_inject_admin_bar_live), so the cached HTML is bar-free.

    return $output;
}

# SM099: reveal the correct auth control client-side from the lzs_session marker
# cookie (display-only; the signed HttpOnly cookie is still the gate). One tiny
# inline script before </body>, only acting on opt-in [data-ls-auth-*] elements.
sub _inject_auth_sync {
    my ($html) = @_;
    return $html unless $html =~ m{</body>}i;
    # SM352: the behaviour moved to /assets/lazysite-chrome.js. What is injected
    # is a reference to the bundle, and it is injected ONCE - the bundle is
    # self-contained, so the same reference also carries the frame-suppressor
    # and anything else that joins it later.
    #
    # Still injected here rather than emitted by the layout, because a page
    # rendered by a THEME never goes through the fallback template and would
    # otherwise get no chrome script at all.
    return $html if $html =~ m{/assets/lazysite-chrome\.js};
    my $script = '<script src="/assets/lazysite-chrome.js?v='
        . _lazysite_version() . '" defer></script>';
    # Inject before the LAST </body>, not the first: a page can legitimately
    # carry a literal "</body>" inside a JS string (e.g. the editor builds an
    # iframe srcdoc: frame.srcdoc = '...</body></html>'). Splicing a
    # <script>...</script> in there closes the page's own inline <script> early
    # - "SyntaxError: literal not terminated" - and kills the whole script. The
    # negative lookahead anchors the match to the document's real closing tag.
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

# DP-3b: the data helper, injected only for a page that actually uses it.
#
# UNLIKE THE CHROME BUNDLE, THIS IS CONDITIONAL. Chrome goes on every page
# because every page has chrome. A page with no live or client-side table has
# no use for this, and shipping a script to every visitor so that a handful of
# pages can refresh a list is a cost paid by everyone for the benefit of a few.
#
# THE TRIGGER IS THE RENDERED MARKUP, not the binding. A `db:` binding declares
# a MODE, but the markup is what declares a REGION - and the two can disagree
# in both directions: a page may carry a `data-ls-db` region with no binding at
# all (that is what mode=client is), and a layout may ignore a binding
# entirely. Looking at what was actually rendered cannot be wrong about what
# the page contains.
sub _inject_data_helper {
    my ($html) = @_;
    return $html unless $html =~ m{</body>}i;
    return $html unless $html =~ m{\bdata-ls-db\b};
    return $html if $html =~ m{/assets/lazysite-data\.js};
    my $script = '<script src="/assets/lazysite-data.js?v='
        . _lazysite_version() . '" defer></script>';

    # Before the LAST </body>, for the reason spelled out in _inject_auth_sync:
    # a page can carry a literal "</body>" inside a JS string, and splicing a
    # script tag in there terminates the page's own inline script early.
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

# SM112: read the installed release version once (from the install state).
my $LAZYSITE_VERSION;
# SM886: and when that state was last written, which is when this engine was
# installed. Memoised beside the version and for the same reason.
my $ENGINE_MTIME;
# Enabled plugins from lazysite.conf's `plugins:` list, for conditional manager
# nav (e.g. hide "Visitor statistics" when the stats plugin is disabled). Keyed
# by both the raw entry (stats.pl) and its extensionless id (stats) so the layout
# can write `enabled_plugins.stats`.
sub _enabled_plugins {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my %en;
    my $conf = "$LAZYSITE_DIR/lazysite.conf";
    open my $fh, '<:utf8', $conf or return \%en;
    my $in = 0;
    while (<$fh>) {
        chomp;
        # SM915: BOTH SPELLINGS. SM817 renamed this list to `extensions:` and
        # said the two open the same one; this reader took the old name alone, so
        # on a site that adopted the new one every entry read as disabled and the
        # manager nav hid entries for extensions that were in fact enabled. The
        # sibling reader in this same file (_unit_enabled) already had it right.
        if (/^(?:extensions|plugins)\s*:\s*$/) { $in = 1; next }
        if ( $in && /^\s+-\s+(.+?)\s*$/ ) {
            my $e = $1;
            $en{$e} = 1;                           # raw entry, e.g. stats.pl
            ( my $base = $e ) =~ s{.*/}{};         # basename (drop any path prefix)
            $en{$base} = 1;
            ( my $id = $base ) =~ s/\.[^.]+$//;    # extensionless id, e.g. stats
            $en{$id} = 1 if length $id;
        }
        elsif ( $in && /^\S/ ) { $in = 0 }
    }
    close $fh;
    return \%en;
}

# SM698: the manager style an instance has chosen.
#
# A CLOSED SET, not a filename. `manager_style` in lazysite.conf names one of
# the sheets the engine ships; anything else is ignored. The alternative - let
# the setting carry a path or a URL - puts an attacker-or-typo-controlled value
# into a <link href> on every manager page, which is a stylesheet-injection
# surface for the sake of flexibility nobody asked for. Uploading a sheet
# (SM698 step 5) will need its own mechanism and its own boundary; it will not
# be this setting widening.
sub _manager_style {
    my %SHIPPED = map { $_ => 1 } qw(classic accessible modern);
    my $want    = '';
    my $conf    = "$LAZYSITE_DIR/lazysite.conf";
    if ( -f $conf && open my $fh, '<', $conf ) {
        while ( my $line = <$fh> ) {
            next unless $line =~ /\A\s*manager_style\s*:\s*(\S+)/;
            $want = lc $1;
            last;
        }
        close $fh;
    }
    return $SHIPPED{$want} ? $want : 'classic';
}

# SM830: A THEME IS AUTHORED ON ITS OWN CLOCK, so its cache key has to be its own.
#
# The tokens link carried `?v=<engine version>`. That is exactly the right key
# for a stylesheet the ENGINE ships, because the engine version is what changes
# it - and exactly the wrong one for a theme, which changes whenever somebody
# edits theme.json. Within one release the query string never moved, so a
# browser that had the URL had no reason to ask again. Measured in the field on
# 0.13.11: the mirrored file was regenerated correctly with the new colour, and
# the page went on serving the old one from cache.
#
# A CONTENT HASH, NOT AN MTIME. Activation rewrites the mirror, and an mtime key
# would expire every visitor's cache on every activation even when nothing in
# the file changed. The hash moves when, and only when, the bytes do - which is
# the property `?v=` exists to carry. The file is a few hundred bytes of custom
# properties and is read only on a render, never on a cache hit.
#
# If it cannot be read the engine version is the answer, which is no worse than
# before: a cache key must never be the thing that breaks a stylesheet link.
sub _asset_fingerprint {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return _lazysite_version();
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return _lazysite_version() unless defined $bytes;
    return substr( sha256_hex($bytes), 0, 12 );
}

# SM886: WHEN THIS ENGINE WAS INSTALLED, as a cache dependency.
#
# A render bakes the engine into itself - the generator meta, the ?v= asset
# busting tokens, the head contract, every security header the build emits. It
# is therefore a dependency of the cached page exactly as lazysite.conf, the nav
# file and the section indexes are, and it was the one never added. An upgrade
# changes no source, so a page nobody edits kept its pre-upgrade render for
# ever: the field measured that twice, most recently on ten sites serving home
# pages from 0.14.0 and 0.13.15 while answering a fresh 404 as 0.14.1.
#
# THE INSTALL STATE IS THE RIGHT FILE TO WATCH. It is what the installer
# rewrites on every install, upgrade and rollback, and it is already the source
# of the version this render reports - so the fact the page claims about itself
# and the fact the cache is judged on are the same fact. Keyed on its MTIME
# rather than its version string, so a rollback to an older build invalidates
# too; "different from the render" is the property that matters, not "newer".
#
# A site with no install state - the dev server, a test fixture - gets 0 and is
# unaffected, which is the behaviour it had before this existed.
#
# Memoised per process, like _lazysite_version. A persistent worker that has not
# been restarted is still RUNNING the old engine, so it is correct for it to go
# on serving that engine's renders; N142A restarts the workers an upgrade
# touches, and a restarted worker reads the new mtime.
sub _engine_mtime {
    return $ENGINE_MTIME if defined $ENGINE_MTIME;
    $ENGINE_MTIME = ( stat "$LAZYSITE_DIR/.install-state.json" )[9] // 0;
    return $ENGINE_MTIME;
}

sub _lazysite_version {
    return $LAZYSITE_VERSION if defined $LAZYSITE_VERSION;
    $LAZYSITE_VERSION = '';
    my $path = "$LAZYSITE_DIR/.install-state.json";
    if ( open my $fh, '<', $path ) {
        local $/; my $j = <$fh>; close $fh;
        my $d = eval { decode_json($j) };
        $LAZYSITE_VERSION = $d->{version} if $d && $d->{version};
    }
    return $LAZYSITE_VERSION;
}

# Inject <meta name="generator"> (+ author/description when available) just after
# the opening <head>. Opt out with meta_generator: false in lazysite.conf.
sub _inject_meta {
    my ( $html, $vars ) = @_;
    return $html unless $html =~ /<head[^>]*>/i;
    my $off = lc( $vars->{meta_generator} // '' );
    return $html if $off eq 'false' || $off eq 'off' || $off eq '0';

    my $esc = sub {
        my $s = shift // '';
        $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
        return $s;
    };
    my $ver = _lazysite_version();
    my @m = ( '<meta name="generator" content="' . $esc->( 'lazysite' . ( $ver ? " $ver" : '' ) ) . '">' );
    # SEC-2026-07 (H5): page_author / page_subtitle are already HTML-escaped at
    # the stash source (render_content), so they are emitted raw here - re-
    # escaping would double-encode ("&lt;" -> "&amp;lt;").
    if ( length( $vars->{page_author} // '' ) ) {
        push @m, '<meta name="author" content="' . ( $vars->{page_author} // '' ) . '">';
    }
    # Only add description if the layout did not already emit one.
    if ( length( $vars->{page_meta_desc} // '' ) && $html !~ /<meta\s+name=["']description["']/i ) {
        push @m, '<meta name="description" content="' . ( $vars->{page_meta_desc} // '' ) . '">';
    }
    my $block = "\n    " . join( "\n    ", @m );
    $html =~ s/(<head[^>]*>)/$1$block/i;
    return $html;
}

# SM151: emit a per-host canonical <link rel="canonical"> in the head. The base
# comes from the resolved (per-host) site_url - a declared value, never the
# untrusted request Host - so it is stable and safe to cache per host. The path
# is the request's own clean URL (extension stripped, /index collapsed to /).
# No-ops when: the head is absent, site_url is unset, or the layout already
# emitted a canonical (the engine defers to an explicit one).
sub _inject_canonical {
    my ( $html, $vars ) = @_;
    return $html unless $html =~ /<head[^>]*>/i;
    return $html if $html     =~ /rel=["']canonical["']/i;

    my $base = $vars->{site_url};
    return $html unless defined $base && length $base;
    $base =~ s{/+$}{};

    my $path = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '/';
    $path =~ s/[?#].*$//;                # drop query / fragment
    $path = "/$path" unless $path =~ m{^/};
    $path =~ s{\.(?:html|md|url)$}{};    # clean serving extension
    $path =~ s{/index$}{/};              # /foo/index -> /foo/
    $path = '/' if $path eq q{} || $path eq '/index';

    my $href = $base . $path;
    $href =~ s/&/&amp;/g;
    $href =~ s/</&lt;/g;
    $href =~ s/>/&gt;/g;
    $href =~ s/"/&quot;/g;

    my $tag = qq{\n    <link rel="canonical" href="$href">};
    $html =~ s/(<head[^>]*>)/$1$tag/i;
    return $html;
}

sub _inject_admin_bar {
    my ( $html, $vars ) = @_;

    my $manager = $vars->{manager} // '';
    return $html unless $manager eq 'enabled';

    my $page_source = $vars->{page_source} // '';
    my $request_uri = $vars->{request_uri} // '';

    # Don't inject on manager pages - they have their own chrome
    my $manager_path = $vars->{manager_path} || '/manager';
    return $html if $request_uri eq $manager_path
        || index( $request_uri, "$manager_path/" ) == 0;

    # Who is viewing? Use the same rule as the /manager route protection.
    my $auth_user   = $ENV{HTTP_X_REMOTE_USER}   // '';
    my $auth_groups = $ENV{HTTP_X_REMOTE_GROUPS} // '';
    my $is_manager  = _is_manager( $vars, $auth_user, $auth_groups );

    # Manager tools: Manage / Edit / no-password warning / sign-out.
    # SM069: the core theme switcher that used to live here has been
    # removed. It POSTed to action=theme-activate from a live-site
    # page without the CSRF token (the manager-api CSRF wrapper only
    # runs on /manager/* pages), so the server rejected the POST and
    # the switch silently failed. The duplicate is also out of scope:
    # /manager/config's Active theme dropdown (SM044) is now the
    # single path to set the site-wide active theme.
    my $manager_tools = '';
    if ($is_manager) {
        $manager_tools .= '<a href="/manager/" style="color:#6db3f2;text-decoration:none;">Manage</a>';

        if ($page_source) {
            $manager_tools .= '<a href="/manager/edit?path=' . $page_source
                . '" style="color:#6db3f2;text-decoration:none;">Edit</a>';
        }

        if ( $ENV{LAZYSITE_AUTH_NO_PASSWORD} ) {
            $manager_tools .= '<span style="color:#f5a623;">&#9888; No password set for your account.</span>';
            $manager_tools .= '<a href="/manager/users" style="color:#f5a623;text-decoration:underline;">Set one</a>';
        }

        my $user = $vars->{auth_name} || $vars->{auth_user} || '';
        if ($user) {
            # SM709: _esc_html AT THE SINK, because this is string concatenation
            # and not a template - there is no filter to get wrong and no stash
            # escaping to inherit. This reads %AUTH_CONTEXT directly (below), so
            # the escaping applied where the TT stash is built does not reach it.
            # A display name permits quotes and angle brackets: cmd_user_settings_set
            # strips only \r\n\t and caps at 64.
            $manager_tools .= '<span style="margin-left:auto;">' . _esc_html($user) . '</span>';
            $manager_tools .= '<a href="/cgi-bin/lazysite-auth.pl?action=logout" style="color:#888;text-decoration:none;">Sign out</a>';
        }
    }

    # F0017 stub: when the cookie-based per-visitor theme variant
    # switcher lands, it will populate $variant_switcher here,
    # outside the $is_manager gate so all visitors can use it. For
    # now the bar never carries a switcher.
    my $variant_switcher = '';

    # Nothing to show? Skip the bar entirely.
    return $html unless length $manager_tools || length $variant_switcher;

    # In normal flow (NOT position:fixed) so the bar never overlaps a theme's own
    # fixed/sticky header: it sits above the page and scrolls away with it. A fixed
    # bar collided with sticky theme headers at top:0 (both want the viewport top),
    # and there is no engine-only way to offset an arbitrary theme's sticky header -
    # so the bar yields the top instead. No spacer needed: an in-flow bar occupies
    # its own height.
    #   position:relative + a max z-index gives the bar its OWN stacking context on
    # top, without leaving the flow. A plain static bar paints BELOW a theme's
    # positioned header (sticky/z-index), which then covers the bar's links and eats
    # the clicks; relative+z-index keeps the bar clickable while it scrolls normally.
    my $bar = '<div id="ls-admin-bar" style="'
        . 'position:relative;z-index:2147483647;'
        . 'background:#1a1a1a;color:#aaa;font:12px system-ui,sans-serif;'
        . 'padding:2px 12px;display:flex;align-items:center;gap:10px;'
        . '">';
    $bar .= $manager_tools;
    $bar .= $variant_switcher;
    $bar .= '</div>';

    # Hide in iframes (e.g. the editor's srcdoc preview)
    # SM352: the frame-suppression this used to inline is in
    # /assets/lazysite-chrome.js, which hides ls-admin-bar alongside the site
    # bar and rule. The bar carries no script of its own now.
    #
    # It does not need to inject the bundle reference either: _inject_auth_sync
    # runs on the same response and injects it once.

    # Anchor to the FIRST <body> after </head>, not the first <body> anywhere: a
    # page can carry a literal "<body>" inside a head comment or script string
    # (e.g. the manager CSRF wrapper's explanatory comment). Splicing the bar -
    # which itself contains <script>...</script> - into a head <script> closes that
    # script early and corrupts the whole page. Fall back to a bare <body> only if
    # there is no </head> (fragment), where there is no head to be confused by.
    if ( $html =~ m{</head\s*>}i ) {
        $html =~ s{(</head\s*>[\s\S]*?<body[^>]*>)}{$1$bar}i;
    }
    else {
        $html =~ s/(<body[^>]*>)/$1$bar/i;
    }

    return $html;
}

# Inject the manager admin bar at OUTPUT time, per-request, so it is never written
# to the shared page cache - baking it in would leak it to anonymous visitors, or
# hide it from a manager, depending on who filled the cache. Sources everything
# from the live request: site config (manager on/off + manager_groups),
# %AUTH_CONTEXT (the viewer), and the page's source path for the Edit link. No-op
# on body-less / non-HTML output.
# SM656 part two: a SECTION can decline the bar, by saying so once on its own
# index page, and a page inside it may still say otherwise.
#
# The filing's second remedy: "these pages are already governed as a section by
# one ACL entry. A section that is an application is an application throughout,
# and saying it once beats saying it on every page." An application is rarely
# one page, and requiring the key on each of them means the next page added is
# the one that gets it wrong.
#
# NO NEW STORE AND NO NEW CONFIG FILE. The section's index page is where a
# section already describes itself, so the key it already understands is read
# from there. Walking up stops at the docroot.
#
# A PAGE STILL WINS over its section, in both directions: a page inside a
# declining section may ask for the bar back with `admin_bar: bar`. Inheritance
# that could only take the bar away would leave one page in an application
# section - the section's own documentation, say - with no way to be a document
# again.
sub _admin_bar_choice {
    my ($md_path) = @_;
    return undef unless defined $md_path && length $md_path;

    my $own = _peek_md($md_path)->{admin_bar};
    return $own if defined $own;

    # THE STARTUP-CAPTURED DOCROOT, not $ENV{DOCUMENT_ROOT}. Under the FastCGI
    # pool a worker's environment is set once when it starts; reading it per
    # request is the stale-value class t/lint/43 exists to refuse, and on a
    # multi-site pool it is how one site's request resolves against another
    # site's root.
    my $docroot = $DOCROOT // '';
    return undef unless length $docroot;
    my $dir = $md_path;
    $dir =~ s{/[^/]*\z}{};

    # Bounded: stop at the docroot, and never walk above it even if the path is
    # not under it (a symlinked or mis-rooted md_path must not send this up the
    # filesystem).
    # The loop condition is the ONLY bound, deliberately. Two further guards
    # were written here first - skipping the page's own index, and breaking at
    # the docroot - and sabotage showed neither could change the answer: a page
    # carrying its own key has already returned above, and stripping past the
    # docroot fails this regex on the next pass. Untested branches that cannot
    # fire are what SM656 part one refused to ship, so they are gone rather than
    # kept as reassurance.
    my $guard = 0;
    while ( length $dir && $dir =~ m{^\Q$docroot\E(?:/|\z)} && $guard++ < 32 ) {
        my $want = _peek_md("$dir/index.md")->{admin_bar};
        return $want if defined $want;
        $dir =~ s{/[^/]*\z}{};
    }
    return undef;
}

sub _inject_admin_bar_live {
    my ( $html, $md_path ) = @_;
    return $html unless defined $html && $html =~ /<body/i;
    my %sv = resolve_site_vars();
    return $html unless ( $sv{manager} // '' ) eq 'enabled';

    # SM656: a page may decline the bar, and a page that has already declared
    # itself not-a-document declines it by default.
    #
    # The existing control is the `ui` capability - a property of the person,
    # and the only lever. It works while every page is a content page. On a
    # site carrying an application it stops working: the sysop who both
    # administers the site and USES the application must see the bar on every
    # page or none, and the documented way to remove it is to take `ui` away,
    # which removes the manager UI with it. That is not a trade anyone should
    # make to stop an Edit link appearing over a data-entry screen.
    #
    # NOT ALSO DEFAULTING api:/raw: PAGES TO none, though the filing suggested
    # it and it sounds free. Measured: an api: page renders no <body> at all,
    # so the guard at the top of this sub already returns before anything is
    # injected - the branch could never fire, and its tests passed whether the
    # code was there or not. The filing said as much in passing ("it would not
    # have helped here"); shipping unreachable code with vacuous tests behind
    # it is worse than not shipping it.
    if ( defined $md_path && length $md_path ) {
        my $want = _admin_bar_choice($md_path);
        return $html if defined $want && $want eq 'none';
    }

    my $page_source = $md_path // '';
    $page_source =~ s{^\Q$DOCROOT\E/}{};    # docroot-relative, for the Edit link

    my $groups   = $AUTH_CONTEXT{auth_groups} || [];
    my $bar_vars = {
        %sv,   # manager, manager_path, manager_groups
               # Behind the auth wrapper (every /manager/* page) REDIRECT_URL is unset and
               # the real path is in REQUEST_URI - same resolution as the request_uri TT
               # var and get_layout_path. Using REDIRECT_URL alone left request_uri empty,
               # so the "skip on manager pages" guard never fired and the bar was injected
               # into the manager page (and into a <body> in its head comment).
        request_uri => ( $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '' ),
        page_source => $page_source,
        auth_user   => $AUTH_CONTEXT{auth_user} // '',
        auth_name   => $AUTH_CONTEXT{auth_name} // '',
        auth_groups =>
            ( ref $groups eq 'ARRAY' ? join( ',', @$groups ) : ( $groups // '' ) ),
    };
    return _inject_admin_bar( $html, $bar_vars );
}

1;
