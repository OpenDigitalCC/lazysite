#!/usr/bin/perl
use strict;
use warnings;
use Text::MultiMarkdown;
use Template;
use File::Basename qw(dirname);
use File::Path     qw(make_path);
# P-1: LWP::UserAgent is require()d lazily inside fetch_url / fetch_oembed
# / fetch_remote_layout. These paths are rare relative to cache-hit
# traffic, so deferring the ~20ms of LWP module load keeps the hot path
# fast.
use Cwd    qw(realpath);
use Encode qw(decode);
# Socket + URI moved to Lazysite::Fetch (SM096): they backed only the SSRF guard,
# now on the lazily-loaded fetch path, so the hot render path no longer loads them.
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use POSIX       qw(strftime);
use Fcntl       qw(O_WRONLY O_APPEND O_CREAT);    # SM140: first-party access log

my $LOG_COMPONENT = 'processor';

# --- Plugin descriptor ---

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    # SM042: the processor stays a registered CORE plugin (the registry probes
    # lazysite-processor.pl + lazysite-auth.pl via --describe), but it no longer
    # carries the site-config schema. Site settings are now read and written
    # directly through the control API (config-read / config-set); config.md's
    # SITE_SCHEMA is the sole form definition, and config-set's allow-list is the
    # sole write gate. The old config_keys / config_schema here (mirrored by
    # config.md, a standing drift hazard) are retired.
    print JSON::PP::encode_json( {
            id   => 'lazysite',
            name => 'Site Configuration',
            description => 'Core lazysite.conf settings, managed on the Config page via the control API (config-read / config-set).',
            version     => '1.0',
            config_file => '',
            actions     => [],
    } );
    exit 0;
}

# --- Configuration ---

my $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

my $LAZYSITE_DIR   = "$DOCROOT/lazysite";
my $LAZYSITE_URI   = "/lazysite";
my $PREVIEW_COOKIE = 'lzs_preview';         # SM071: theme/layout preview cookie

# SM201: engine-required system pages (auth + error) are served with a fallback so
# a deleted or never-seeded content copy never 404s the sign-in / sign-up flow,
# and a content-rooted subdomain without its own copy still serves them.
# Resolution order: the per-domain content root, then the primary docroot root,
# then the protected engine default under lazysite/templates/system/ (code-
# shipped, DAV-blocklisted - an agent cannot delete it). The set is FIXED so an
# arbitrary missing page can never trigger the fallback.
my %SYSTEM_PAGES = map { $_ => 1 } qw(login claim 402 403 404);

sub _system_page_md {
    my ( $base, $croot ) = @_;
    return undef unless defined $base && $SYSTEM_PAGES{$base};
    $croot = $DOCROOT unless defined $croot && length $croot;
    for my $cand ( "$croot/$base.md", "$DOCROOT/$base.md",
        "$LAZYSITE_DIR/templates/system/$base.md" )
    {
        return $cand if -f $cand;
    }
    return undef;
}

# F0003: lazysite.conf path override
# Priority: --conf arg > LAZYSITE_CONF env var > default
my $CONF_OVERRIDE;
for my $i ( 0 .. $#ARGV ) {
    if ( $ARGV[$i] eq '--conf' && defined $ARGV[ $i + 1 ] ) {
        $CONF_OVERRIDE = $ARGV[ $i + 1 ];
        last;
    }
}
$CONF_OVERRIDE //= $ENV{LAZYSITE_CONF};

my $CONF_FILE = $CONF_OVERRIDE
    ? $CONF_OVERRIDE
    : "$LAZYSITE_DIR/lazysite.conf";
# D013: layouts/ is the new structural root. A local layout lives at
# $LAYOUT_DIR/NAME/layout.tt with optional $LAYOUT_DIR/NAME/layout.json
# metadata. Themes nest under layouts/NAME/themes/THEME/. No flat-template
# fallback ($LAZYSITE_DIR/templates/*.tt) and no default view.tt path —
# if no layout is installed, the embedded $FALLBACK_LAYOUT is the sole
# fallback.
my $LAYOUT_DIR     = "$LAZYSITE_DIR/layouts";
my $REGISTRY_DIR   = "$LAZYSITE_DIR/templates/registries";
my $MANAGER_LAYOUT = "$LAZYSITE_DIR/manager/layout.tt";
my $REMOTE_TTL     = 3600;   # seconds before remote content is refetched (default 1 hour)
my $REGISTRY_TTL   = 14400;  # seconds before registries are regenerated (default 4 hours)
# SM091: the cache base normally lives under the docroot, but a read-only
# browse (the dev server's --auto-index) can relocate it off the docroot via
# LAZYSITE_CACHE_DIR so pointing the processor at an arbitrary tree writes
# nothing into it. Unset (production / tests) keeps the original location.
my $CACHE_BASE       = $ENV{LAZYSITE_CACHE_DIR} || "$LAZYSITE_DIR/cache";
my $LAYOUT_CACHE_DIR = "$CACHE_BASE/layouts";
my $CT_CACHE_DIR     = "$CACHE_BASE/ct";
my $TT_COMPILE_DIR   = "$CACHE_BASE/tt";       # P-4 TT on-disk compile cache
my $HOST_CACHE_DIR   = "$CACHE_BASE/hosts";    # SM110 phase 2: per-alias-host page cache
my %AUTH_CONTEXT;         # populated by main() auth check, read by render_content()
my %ACCESS_REC;           # SM140: per-request outcome for the first-party access log
my $RESPONSE_LANG = 'en'; # SM179 (P1): the rendered page's language, set per
                          # request from page_lang; emitted as Content-Language.
my $REQUEST_CROOT;        # SM151: the request's confined content root (undef => docroot),
                          # set by main(), read by resolve_scan() so per-domain search is
                          # boxed to the requesting domain's subtree without re-entering
    # resolve_site_vars (which calls resolve_scan for conf directives)

# Built-in fallback template - used when no layout.tt is found
my $FALLBACK_LAYOUT = <<'END_FALLBACK';
<!DOCTYPE html>
<html lang="[% page_lang || 'en' %]">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    [% IF page_subtitle %]<meta name="description" content="[% page_subtitle %]">[% END %]
    <title>[% page_title %][% IF site_name %]  -  [% site_name %][% END %]</title>
    [%# SM179 P2: hreflang alternates for a language set, plus x-default on the source (first) language %]
    [% FOREACH l IN languages %][% IF l.exists %]<link rel="alternate" hreflang="[% l.lang %]" href="[% l.url %]">
    [% END %][% END %][% IF languages.size %]<link rel="alternate" hreflang="x-default" href="[% languages.0.url %]">
    [% END %]
    <style>
        body { font-family: system-ui, sans-serif; max-width: 800px;
               margin: 2rem auto; padding: 0 1rem; color: #333; }
        .site-bar { display: flex; align-items: center; gap: 0.75rem;
                    padding: 0.5rem 0; font-size: 0.85rem; flex-wrap: wrap; }
        .site-bar a { color: #0066cc; text-decoration: none; font-weight: 600; }
        .site-bar a:hover { text-decoration: underline; }
        .site-bar .edit-btn { font-size: 0.8rem; padding: 0.15rem 0.5rem;
               border: 1px solid #ccc; border-radius: 3px; background: #f9f9f9;
               color: #555; text-decoration: none; cursor: pointer; font-weight: 400; }
        .site-bar .edit-btn:hover { background: #eee; color: #333; }
        .site-bar form { display: flex; gap: 0.3rem; }
        .site-bar input[type="search"] { padding: 0.2rem 0.4rem; font-size: 0.8rem;
               border: 1px solid #ccc; border-radius: 3px; width: 140px; }
        .site-bar button { padding: 0.2rem 0.5rem; font-size: 0.8rem; cursor: pointer; }
        hr.site-rule { border: none; border-top: 1px solid #eee; margin: 0 0 1.5rem; }
        .nav-link { margin-right: 1rem; color: #0066cc; text-decoration: none; }
        .nav-link:hover { text-decoration: underline; }
        .nav-child { margin-right: 0.75rem; font-size: 0.85rem; }
        .nav-link[aria-current="page"] { font-weight: 600; }
        .nav-group {
            font-size: 0.7rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: #888;
            padding: 0.5rem 0 0.2rem;
            margin-right: 0.75rem;
            display: inline-block;
        }
        h1 { border-bottom: 1px solid #eee; padding-bottom: 0.5rem; }
        pre { background: #f5f5f5; padding: 1rem; overflow-x: auto; }
        code { background: #f5f5f5; padding: 0.2em 0.4em; }
        footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #eee;
                 font-size: 0.85rem; color: #888; }
        a { color: #0066cc; }
    </style>
</head>
<body>
<div class="site-bar" id="site-bar">
    <a href="/">[% IF site_name %][% site_name %][% ELSE %]Home[% END %]</a>
    <!-- SM099: client-toggled so the cached page shows the right control. Both
         start hidden; the injected auth-sync script reveals one from the lzs_session
         marker cookie. -->
    <a href="/cgi-bin/lazysite-auth.pl?action=logout" data-ls-auth-out style="font-size:0.8rem;color:#888;font-weight:400;margin-left:auto;display:none;">Sign out</a>
    <a href="/login" data-ls-auth-in style="font-size:0.8rem;margin-left:auto;font-weight:400;display:none;">Sign in</a>
    <noscript><a href="/login" style="font-size:0.8rem;margin-left:auto;font-weight:400;">Sign in</a></noscript>
    <form action="/search-results" method="get">
        <input type="search" name="q" placeholder="Search..." aria-label="Search">
        <button type="submit">Go</button>
    </form>
</div>
[%# SM179 P2: language switcher, rendered from the engine-supplied `languages`.
    Only shown for a language set; only lists languages whose counterpart exists. %]
[% IF languages.size %]<nav class="lang-switcher" aria-label="Language" style="font-size:0.85rem;margin:0.4rem 0;color:#888;">
  [% FOREACH l IN languages %][% IF l.exists %][% IF l.current %]<strong lang="[% l.lang %]">[% l.lang %]</strong>[% ELSE %]<a href="[% l.url %]" hreflang="[% l.lang %]" lang="[% l.lang %]">[% l.lang %]</a>[% END %] [% END %][% END %]</nav>
[% END %]
<hr class="site-rule" id="site-rule">
<script>if(window!==window.top){var b=document.getElementById('site-bar');var r=document.getElementById('site-rule');if(b)b.style.display='none';if(r)r.style.display='none';}</script>
[% IF nav.size %]
<nav style="margin-bottom:1.5rem;padding-bottom:0.75rem;border-bottom:1px solid #eee;font-size:0.9rem;">
  [% FOREACH item IN nav %]
    [%# Three cases, distinguished by whether item.url is set and
        whether children exist:
          - url present                : leaf link or clickable parent
          - url empty/absent           : group heading (not a link) %]
    [% IF item.url %]
    <a href="[% item.url %]" class="nav-link"[% IF request_uri == item.url %] aria-current="page"[% END %]>[% item.label %]</a>
    [% ELSE %]
    <span class="nav-group">[% item.label %]</span>
    [% END %]
    [% IF item.children %]
      [% FOREACH child IN item.children %]
      <a href="[% child.url %]" class="nav-link nav-child"[% IF request_uri == child.url %] aria-current="page"[% END %]>[% child.label %]</a>
      [% END %]
    [% END %]
  [% END %]
</nav>
[% END %]
<main>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
    [% content %]
</main>
<footer>
    [% IF page_modified %]
    <p style="font-size:0.8rem;color:#aaa;">Last updated: <time datetime="[% page_modified_iso %]">[% page_modified %]</time></p>
    [% END %]
    <p>Rendered by <a href="https://lazysite.io">lazysite</a>
    [% IF site_name %]- [% site_name %][% END %]
    - no layout.tt found, using built-in fallback</p>
</footer>
</body>
</html>
END_FALLBACK

# Extension to language identifier map for include code block wrapping
my %LANG_MAP = (
    md   => 'markdown',
    yml  => 'yaml', yaml => 'yaml',
    sh   => 'bash', bash => 'bash',
    pl   => 'perl',
    py   => 'python',
    js   => 'javascript',
    json => 'json',
    html => 'html', htm => 'html',
    css  => 'css',
    conf => 'text', cfg => 'text',
    txt  => 'text',
    toml => 'toml',
    xml  => 'xml',
);

# Allowlist of CGI environment variables that may be interpolated in lazysite.conf
# Note: HTTP_HOST is intentionally excluded - it is request-supplied and untrusted.
# Use SERVER_NAME for host-based URL construction.
my %ENV_ALLOWLIST = map { $_ => 1 } qw(
    SERVER_NAME SERVER_PORT REQUEST_SCHEME HTTPS
    REQUEST_URI REDIRECT_URL
    DOCUMENT_ROOT SERVER_ADMIN
);

# SM110: domain aliases. An alias host serves the SAME site (same files,
# users, plugins) with its own chrome. Only these lazysite.conf keys may
# vary per host via alias.<host>.<key> lines - a strict whitelist because
# the Host header is request-supplied: were a security-relevant key
# (manager, auth_*, webdav_*, update_*) overridable per host, any client
# could pick its own policy just by sending a matching Host header. The
# whitelisted keys are presentation-only.
#
# SM151: first-class multi-site adds two more presentation/routing keys.
# content_root roots the host at its own docroot-relative content subtree
# (confine_content_root() enforces the boundary - it can never reach the
# lazysite/ management tree or escape the docroot). site_url gives the host
# its own canonical/absolute base URL for links, sitemap and feeds. Both are
# still presentation/routing only - they move no auth, management or update
# surface, so they stay safe to select via a declared Host.
my %ALIAS_OVERRIDE_KEYS = map { $_ => 1 }
    qw(site_name theme layout nav_file search_default content_root site_url
    lang lang_group);    # SM179: per-host language + language-set membership

# SM151 P6: content-type by extension for per-domain static files served by the
# processor (_serve_content_static). Kept small - the SEO artefacts
# (xml/rss/atom/txt) plus common web assets; anything unlisted falls back to
# octet-stream (a safe download). Declared here in the config block so it is
# initialised before the request is dispatched.
my %STATIC_CT = (
    xml   => 'application/xml; charset=utf-8',
    rss   => 'application/rss+xml; charset=utf-8',
    atom  => 'application/atom+xml; charset=utf-8',
    txt   => 'text/plain; charset=utf-8',
    json  => 'application/json; charset=utf-8',
    css   => 'text/css; charset=utf-8',
    js    => 'text/javascript; charset=utf-8',
    svg   => 'image/svg+xml',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    ico   => 'image/x-icon',
    pdf   => 'application/pdf',
    woff  => 'font/woff',
    woff2 => 'font/woff2',
);

# --- Auth ---

{
    # F7 (D007): single-pass front-matter peek, memoised per
    # request. Callers in main() previously opened the .md file up
    # to five times (peek_auth, peek_payment, peek_query_params,
    # peek_ttl, peek_content_type); now the first peek reads the
    # file, the rest hit this cache. Cache key is (path, mtime) so
    # an mtime change between peeks (shouldn't happen within one
    # request, but be safe) invalidates.
    my %_peek_cache;

    sub _reset_peek_cache { %_peek_cache = () }

    sub _peek_md {
        my ($path) = @_;
        return {} unless $path;
        my @st = stat($path);
        return {} unless @st;
        my $key = "$path:$st[9]";
        return $_peek_cache{$key} if exists $_peek_cache{$key};

        my %m;
        my @groups;
        my @qp;
        my ( $in_groups, $in_qp );

        open my $fh, '<:utf8', $path or do {
            $_peek_cache{$key} = \%m;
            return \%m;
        };
        while ( my $line = <$fh> ) {
            last if $. > 1 && $line =~ /^---/;

            # scalar keys
            if    ( $line =~ /^auth\s*:\s*(\w+)/i )   { $m{auth}    = lc $1 }
            elsif ( $line =~ /^ttl\s*:\s*(\d+)/ )     { $m{ttl}     = $1 }
            elsif ( $line =~ /^api\s*:\s*true/i )     { $m{api}     = 1 }
            elsif ( $line =~ /^nocache\s*:\s*true/i ) { $m{nocache} = 1 }
            elsif ( $line =~ /^raw\s*:\s*true/i )     { $m{raw}     = 1 }
            elsif ( $line =~ /^content_type\s*:\s*(.+)/ ) {
                ( my $v = $1 ) =~ s/^\s+|\s+$//g;
                $m{content_type} = $v;
            }

            # payment.* scalar keys
            for my $pk ( qw(payment payment_amount payment_currency
                payment_network payment_address
                payment_asset payment_description) ) {
                if ( $line =~ /^\Q$pk\E\s*:\s*(.+)$/ ) {
                    ( my $v = $1 ) =~ s/\s+$//;
                    $m{$pk} = $v;
                }
            }

            # auth_groups: block
            if ( $line =~ /^auth_groups\s*:\s*$/ ) {
                $in_groups = 1; $in_qp = 0; next;
            }
            if ($in_groups) {
                if ( $line =~ /^\s+-\s+(.+)$/ ) {
                    ( my $g = $1 ) =~ s/^\s+|\s+$//g;
                    push @groups, $g;
                    next;
                }
                $in_groups = 0 if $line !~ /^\s/;
            }

            # query_params: block
            if ( $line =~ /^query_params\s*:\s*$/ ) {
                $in_qp = 1; $in_groups = 0; next;
            }
            if ($in_qp) {
                if ( $line =~ /^[ \t]+-[ \t]*(\S+)/ ) {
                    push @qp, $1;
                    next;
                }
                $in_qp = 0 if $line !~ /^\s/;
            }
        }
        close $fh;

        $m{groups}       = \@groups if @groups;
        $m{query_params} = \@qp     if @qp;

        $_peek_cache{$key} = \%m;
        return \%m;
    }
}

sub peek_auth {
    my ($path) = @_;
    my $m = _peek_md($path);
    # Matches the old peek_auth contract: hashref with `auth`
    # (possibly undef) and `groups` (always arrayref, possibly
    # empty). peek_auth was the only peek that returned {} on
    # "no file" rather than undef; preserve that.
    return {} unless $path && -f $path;
    return {
        auth   => $m->{auth},
        groups => $m->{groups} // [],
    };
}

sub check_auth {
    my ( $uri, $auth_meta, $site_vars ) = @_;

    my $auth_level = $auth_meta->{auth}
        || $site_vars->{auth_default}
        || 'none';

    # Login page always public
    my $redirect_path = $site_vars->{auth_redirect} || '/login';
    return { ok => 1 } if index( $uri, $redirect_path ) == 0;

    # Manager pages have their own access control - skip auth_default enforcement
    # but still read auth headers so TT vars are populated
    my $manager_path = $site_vars->{manager_path} || '/manager';
    if ( index( $uri, "$manager_path/" ) == 0 || $uri eq $manager_path ) {
        $auth_level = 'none';
    }

    # Convert header names to env var format (X-Remote-User -> HTTP_X_REMOTE_USER)
    my $make_env = sub {
        my $h = shift;
        $h = 'HTTP_' . uc($h);
        $h =~ s/-/_/g;
        return $h;
    };

    my $auth_user = $ENV{ $make_env->( $site_vars->{auth_header_user} || 'X-Remote-User' ) } // '';
    my $auth_name = $ENV{ $make_env->( $site_vars->{auth_header_name} || 'X-Remote-Name' ) } // '';
    my $auth_email = $ENV{ $make_env->( $site_vars->{auth_header_email} || 'X-Remote-Email' ) } // '';
    my $auth_groups = $ENV{ $make_env->( $site_vars->{auth_header_groups} || 'X-Remote-Groups' ) } // '';

    my $authenticated = $auth_user ne '' ? 1 : 0;

    # For 'none' pages, return auth context without enforcement
    if ( $auth_level eq 'none' ) {
        return {
            ok            => 1,
            auth_user     => $auth_user,
            auth_name     => $auth_name,
            auth_email    => $auth_email,
            auth_groups   => [ split /\s*,\s*/, $auth_groups ],
            authenticated => $authenticated,
        };
    }

    if ( !$authenticated && $auth_level eq 'required' ) {
        my $next = uri_encode($uri);
        return { redirect => "$redirect_path?next=$next" };
    }

    # Group check
    my @required = @{ $auth_meta->{groups} // [] };
    if ( $authenticated && @required ) {
        my %user_groups = map  { lc($_) => 1 } split /\s*,\s*/, $auth_groups;
        my $in_group    = grep { $user_groups{ lc($_) } } @required;
        unless ($in_group) {
            return {
                forbidden            => 1,
                auth_user            => $auth_user,
                auth_name            => $auth_name,
                auth_denied_reason   => 'insufficient_groups',
                auth_required_groups => \@required,
            };
        }
    }

    return {
        ok            => 1,
        auth_user     => $auth_user,
        auth_name     => $auth_name,
        auth_email    => $auth_email,
        auth_groups   => [ split /\s*,\s*/, $auth_groups ],
        authenticated => $authenticated,
    };
}

# SM095: does any of these groups carry capability $cap (from groups-settings.json)?
# DELIBERATE local copy of Lazysite::Auth::Settings::groups_grant_cap - the
# processor's render path is module-free by design, so it cannot import the
# shared helper. Recorded in docs/adr/0001-capability-resolution.md; keep this
# in sync with the shared implementation (raw-octets read + decode_json).
sub _groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    my $f = "$DOCROOT/lazysite/auth/groups-settings.json";
    return 0 unless -f $f;
    require JSON::PP;
    open my $fh, '<:raw', $f or return 0;
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
    close $fh;
    for my $g ( _group_closure(@groups) ) {    # SM121: compound-expanded
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{$cap};
    }
    return 0;
}

# SM138: does ANY group grant manager access (ui / manage_users / the manager
# flag)? When none does, the site is unsecured/dev and any authenticated user is
# a manager. Local copy of the same decision Auth::Settings::site_grants_manager
# makes - the render path stays module-free (ADR 0001).
sub _site_grants_manager {
    my $f = "$DOCROOT/lazysite/auth/groups-settings.json";
    return 0 unless -f $f;
    require JSON::PP;
    open my $fh, '<:raw', $f or return 0;
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
    close $fh;
    for my $g ( keys %{$gs} ) {
        my $cfg = $gs->{$g};
        next unless ref $cfg eq 'HASH';
        return 1 if $cfg->{ui} || $cfg->{manage_users} || $cfg->{manager};
    }
    return 0;
}

# SM155: the content-root scope(s) a set of groups confine their members to, and
# the single-domain home_domain pointer. Module-free raw-octets read of
# groups-settings.json to keep the render path module-free (ADR 0001), a local
# copy of Lazysite::Auth::Settings::group_scopes / group_home_domain (kept in
# step). Used to root a delegated editor's file browser at their own domain.
sub _group_settings {
    my $f = "$DOCROOT/lazysite/auth/groups-settings.json";
    return {} unless -f $f;
    require JSON::PP;
    open my $fh, '<:raw', $f or return {};
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
    close $fh;
    return ref $gs eq 'HASH' ? $gs : {};
}

# SM121: compound groups - a group may list another GROUP as a member, so its
# members inherit the parent's caps/scope. Module-free copies of
# Auth::Settings::_group_closure and _groups_membership, kept in step, so the
# render path expands the request's groups the same way the resolver does
# (ADR 0001). Without this a member of a compound group would get its inherited
# caps over the API/dav but be denied at the render path (e.g. manager access).
sub _group_membership_map {
    my $f = "$DOCROOT/lazysite/auth/groups";
    my %g;
    return %g unless -f $f;
    open my $fh, '<:utf8', $f or return %g;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $grp, $mem ) = split /:\s*/, $_, 2;
        next unless defined $mem;
        $g{$grp} = [ map { s/^\s+|\s+$//gr } split /,/, $mem ];
    }
    close $fh;
    return %g;
}

sub _group_closure {
    my (@seed) = @_;
    return @seed unless @seed;
    my %membership = _group_membership_map();
    my $gs         = _group_settings();
    my %is_group   = map { $_ => 1 } ( keys %membership, keys %{$gs} );
    my %parent;
    for my $g ( keys %membership ) {
        for my $m ( @{ $membership{$g} } ) {
            push @{ $parent{$m} }, $g if $is_group{$m} && $m ne $g;
        }
    }
    my %eff   = map { $_ => 1 } grep { defined && length } @seed;
    my @stack = keys %eff;
    while ( defined( my $g = pop @stack ) ) {
        for my $p ( @{ $parent{$g} || [] } ) {
            next if $eff{$p};
            $eff{$p} = 1;
            push @stack, $p;
        }
    }
    return keys %eff;
}

sub _group_scopes {
    my (@groups) = @_;
    return () unless @groups;
    @groups = _group_closure(@groups);    # SM121: compound-expanded
    my $gs = _group_settings();
    my ( %seen, @scopes );
    for my $g (@groups) {
        next unless ref $gs->{$g} eq 'HASH';
        my $s = $gs->{$g}{dav_scope};
        next unless defined $s && length $s;
        push @scopes, $s unless $seen{$s}++;
    }
    return @scopes;
}

sub _group_home_domain {
    my (@groups) = @_;
    @groups = _group_closure(@groups);    # SM121: compound-expanded
    my $gs = _group_settings();
    my @hd;
    for my $g (@groups) {
        next unless ref $gs->{$g} eq 'HASH';
        my $s = $gs->{$g}{dav_scope};
        next unless defined $s && length $s;
        push @hd, ( $gs->{$g}{home_domain} // '' );
    }
    return ( @hd == 1 && length $hd[0] ) ? $hd[0] : '';
}

# SM165: the module-free render-path copy of the DOMAIN-access scope resolution
# (a local copy of Auth::DomainAccess, kept in step, ADR 0001). Roots the file
# browser at the domains a user's groups allow (narrowed by any lock). The
# AUTHORITATIVE confinement - including the sub-user ceiling - is applied
# SERVER-SIDE by the manager API / WebDAV via resolve_user_scopes; this render
# copy is only the UI rooting hint, so it omits the ceiling (a sub-user still
# cannot ACT outside its ceiling).
sub _read_domain_access {
    my $f   = "$LAZYSITE_DIR/lazysite.conf";
    my %dom = ( '' => { content_root => '', allowed_groups => [], locked_users => [] } );
    open my $fh, '<:utf8', $f or return %dom;
    while ( my $l = <$fh> ) {
        chomp $l;
        $l =~ s/^\s+|\s+$//g;
        next if $l =~ /^#/ || !length $l;
        if ( $l =~ /^content_root\s*:\s*(.+)/ ) {
            ( $dom{''}{content_root} = $1 ) =~ s/^\s+|\s+$//g;
        }
        elsif ( $l =~ /^alias\.(.+)\.(content_root|allowed_groups|locked_users)\s*:\s*(.+)/x ) {
            my ( $h, $k, $v ) = ( $1, $2, $3 );
            $v =~ s/^\s+|\s+$//g;
            $dom{$h} ||= { content_root => '', allowed_groups => [], locked_users => [] };
            if ( $k eq 'content_root' ) { $dom{$h}{content_root} = $v }
            else { $dom{$h}{$k} = [ grep { length } map { s/^\s+|\s+$//gr } split /,/, $v ] }
        }
    }
    close $fh;
    return %dom;
}

sub _domain_eff {
    my ( $user, @groups ) = @_;
    @groups = _group_closure(@groups);
    my %g   = map { $_ => 1 } @groups;
    my %dom = _read_domain_access();
    my ( %allowed, %locked );
    for my $h ( keys %dom ) {
        my @ag = @{ $dom{$h}{allowed_groups} || [] };
        if ( $h eq '' ) { $allowed{$h} = 1 if !@ag || grep { $g{$_} } @ag }
        else            { $allowed{$h} = 1 if @ag && grep { $g{$_} } @ag }
        $locked{$h} = 1
            if defined $user && grep { $_ eq $user } @{ $dom{$h}{locked_users} || [] };
    }
    my @eff = %locked ? ( grep { $allowed{$_} } keys %locked ) : ( keys %allowed );
    return ( \%dom, \@eff );
}

sub _domain_scopes {
    my ( $dom, $eff ) = _domain_eff(@_);
    return () unless @{$eff};
    my ( %seen, @sc );
    for my $h ( @{$eff} ) {
        my $cr = $dom->{$h}{content_root} // '';
        next unless length $cr;
        push @sc, $cr unless $seen{$cr}++;
    }
    return @sc;
}

sub _domain_home {
    my ( $dom, $eff ) = _domain_eff(@_);
    my @rooted = grep { length( $dom->{$_}{content_root} // '' ) } @{$eff};
    return ( @rooted == 1 ) ? $rooted[0] : '';
}

sub _is_manager {
    my ( $site_vars, $auth_user, $auth_groups ) = @_;
    return 0 unless $auth_user;
    # SM095: Manager-UI access is the `ui` channel capability, granted via a
    # group. SM138: the lazysite.conf manager_groups fallback is retired (the
    # migration granted those groups their capabilities explicitly).
    return 1 if _groups_grant_cap( 'ui', split /\s*,\s*/, ( $auth_groups // '' ) );
    unless ( _site_grants_manager() ) {
        # L-3: config advisory, not an operational warning (DEBUG - under CGI
        # every request is a new process; the dev server surfaces it once).
        log_event( 'DEBUG', '-',
            'no group grants manager access - any authenticated user has it',
            suggestion => 'grant the ui capability to a group on the Groups page' );
        return 1;
    }
    return 0;
}

sub serve_403 {
    my ($auth_result) = @_;
    my $md_path = _system_page_md('403') // "$DOCROOT/403.md";          # SM201 fallback

    $ACCESS_REC{s} //= 403;    # SM140
    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $html_path = "$DOCROOT/403.html";
        my $page      = process_md( $md_path, $html_path, ( stat($md_path) )[9], {} );
        print "Status: 403 Forbidden\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print $page;
    }
    else {
        print "Status: 403 Forbidden\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        my $lang = _chrome_lang();
        print qq{<!DOCTYPE html><html lang="$lang"><head><meta charset="utf-8">};
        print "<title>403 Forbidden</title></head><body>";
        print '<h1>' . _chrome('forbidden.title') . '</h1>';
        if ( ( $auth_result->{auth_denied_reason} // '' ) eq 'insufficient_groups' ) {
            print '<p>' . _chrome('forbidden.insufficient') . '</p>';
        }
        else {
            print '<p>' . _chrome('auth.required') . '</p>';
        }
        print "</body></html>";
    }
}

# --- Payment ---

my %PAYMENT_CONTEXT;    # populated by main(), read by render_content()
my %PREVIEW_CONTEXT;    # SM071: preview layout/theme override, set by main()

sub peek_payment {
    my ($path) = @_;
    my $m = _peek_md($path);
    my %out;
    for my $k ( qw(payment payment_amount payment_currency
        payment_network payment_address
        payment_asset payment_description) ) {
        $out{$k} = $m->{$k} if defined $m->{$k};
    }
    return \%out;
}

sub check_payment {
    my ( $uri, $payment_meta, $auth_result, $site_vars ) = @_;

    return { ok => 1 } unless
        ( $payment_meta->{payment} // '' ) eq 'required';

    # Check group bypass - auth_groups in payment_meta
    my @bypass_groups = @{ $payment_meta->{auth_groups} // [] };
    if ( @bypass_groups && $auth_result->{authenticated} ) {
        my %user_groups = map { lc($_) => 1 }
            @{ $auth_result->{auth_groups} // [] };
        my $bypassed = grep { $user_groups{ lc($_) } } @bypass_groups;
        return { ok => 1, bypassed => 1 } if $bypassed;
    }

    # Check payment proof header
    my $verified_header = $site_vars->{payment_header_verified}
        || 'X-Payment-Verified';
    my $verified_env = 'HTTP_' . uc($verified_header);
    $verified_env =~ s/-/_/g;

    my $verified = $ENV{$verified_env} // '';
    if ( $verified eq '1' ) {
        my $payer_header = $site_vars->{payment_header_payer}
            || 'X-Payment-Payer';
        my $payer_env = 'HTTP_' . uc($payer_header);
        $payer_env =~ s/-/_/g;
        return {
            ok    => 1,
            paid  => 1,
            payer => $ENV{$payer_env} // '',
        };
    }

    return {
        payment_required => 1,
        amount           => $payment_meta->{payment_amount}      // '0',
        currency         => $payment_meta->{payment_currency}    // 'USD',
        network          => $payment_meta->{payment_network}     // 'base',
        address          => $payment_meta->{payment_address}     // '',
        asset            => $payment_meta->{payment_asset}       // '',
        description      => $payment_meta->{payment_description} // '',
    };
}

sub serve_402 {
    my ($payment_result) = @_;

    # Build x402 payment response header
    # Assumption: amount is in human-readable decimal (e.g. 0.01 USD)
    # Convert to smallest unit assuming USDC (6 decimals)
    my $amount_raw = int( ( $payment_result->{amount} // 0 ) * 1_000_000 );
    my $network    = $payment_result->{network} || 'base';
    my $address    = $payment_result->{address} || '';
    my $asset      = $payment_result->{asset}   || '';

    my $x_payment = encode_json( {
            version => '1.0',
            accepts => [ {
                    scheme            => 'exact',
                    network           => $network,
                    maxAmountRequired => "$amount_raw",
                    to                => $address,
                    asset             => $asset,
                    extra             => {
                        name    => $payment_result->{currency} || 'USDC',
                        version => '1',
                    },
            } ],
    } );

    binmode( STDOUT, ':utf8' );

    my $md_path = _system_page_md('402') // "$DOCROOT/402.md";    # SM201 fallback
    if ( -f $md_path ) {
        # Set payment context for TT rendering
        %PAYMENT_CONTEXT = (
            payment_required    => 1,
            payment_amount      => $payment_result->{amount}      // '',
            payment_currency    => $payment_result->{currency}    // '',
            payment_network     => $payment_result->{network}     // '',
            payment_address     => $payment_result->{address}     // '',
            payment_description => $payment_result->{description} // '',
        );
        my $page = process_md( $md_path, "$DOCROOT/402.html",
            ( stat($md_path) )[9], {} );
        print "Status: 402 Payment Required\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "X-Payment-Response: $x_payment\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print $page;
    }
    else {
        print "Status: 402 Payment Required\r\n";
        print "Content-type: text/html; charset=utf-8\r\n";
        print "X-Payment-Response: $x_payment\r\n";
        print "Cache-Control: no-store, private\r\n\r\n";
        print "<!DOCTYPE html><html><head><title>Payment Required</title></head><body>";
        print "<h1>Payment Required</h1>";
        print "<p>This content requires payment of ";
        print( ( $payment_result->{amount} // '0' ) . " "
                . ( $payment_result->{currency} // 'USD' ) );
        print ".</p></body></html>";
    }
}

# --- Main ---

# One request, end to end: per-request state reset, main(), the SM140 access
# record, and the die-guard that turns an unhandled error into a proper 500
# (previously a headerless crash). Shared verbatim by the single-shot CGI
# path and every FastCGI loop iteration (SM142) - state hygiene lives HERE,
# not at file scope, so a persistent worker cannot leak between requests.
sub handle_one_request {
    reset_request_state();
    %ACCESS_REC   = ();
    %AUTH_CONTEXT = ();
    my $main_ok = eval { main(); 1 };
    if ( !$main_ok ) {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'unhandled error',
            error => "$@" );
        if ( !defined $ACCESS_REC{s} ) {    # nothing emitted yet - answer 500
            $ACCESS_REC{s} = 500;
            print "Status: 500 Internal Server Error\n";
            print "Content-type: text/plain; charset=utf-8\n\n";
            print "500 Internal Server Error\n";
        }
    }
    _access_record();
    return;
}

# SM142: dual-mode dispatch. Spawned with STDIN as a FastCGI listen socket
# (spawn-fcgi / systemd socket / the SM139 pool unit), the worker services
# requests from an accept loop - modules compiled once, ~10x on cache hits.
# Invoked as a plain CGI (no listen socket, or FCGI.pm absent), it runs the
# single-shot path on native handles, byte-identical to the pre-SM142
# behaviour. Knobs (set by the pool unit): LAZYSITE_FCGI_WORKERS (prefork
# size via FCGI::ProcManager; 0/unset = single worker, the spawner manages),
# LAZYSITE_FCGI_MAX_REQUESTS (worker recycles after N requests; memory
# hygiene; default 500).
my $_fcgi = eval { require FCGI; FCGI::Request() };
if ( $_fcgi && $_fcgi->IsFastCGI() ) {
    my $workers = ( $ENV{LAZYSITE_FCGI_WORKERS} || 0 ) + 0;
    my $pm;
    if ( $workers > 0 && eval { require FCGI::ProcManager; 1 } ) {
        $pm = FCGI::ProcManager->new( { n_processes => $workers } );
        $pm->pm_manage();
    }
    my $max    = ( $ENV{LAZYSITE_FCGI_MAX_REQUESTS} || 500 ) + 0;
    my $served = 0;
    while ( $_fcgi->Accept() >= 0 ) {
        $pm->pm_pre_dispatch() if $pm;
        handle_one_request();
        $pm->pm_post_dispatch() if $pm;
        last                    if ++$served >= $max;    # recycle; the manager respawns
    }
}
else {
    handle_one_request();
}

# Parse the request's query string into a hash of name => value.
# Values are URL-decoded, UTF-8 decoded, and HTML-escaped so they
# are safe for interpolation in rendered pages. Returns a hashref.
#
# UTF-8 handling: after percent-decoding to raw bytes, we decode
# the byte string as UTF-8 so the resulting Perl string holds
# proper code points (e.g. %E2%9C%93 -> U+2713). Without this
# step TT's :utf8 output layer would treat each raw byte as a
# Latin-1 character and re-encode it individually, producing
# mojibake (C3 A2 C2 9C C2 93 instead of E2 9C 93 for U+2713).
#
# Malformed UTF-8 in the query string falls back to the raw
# byte-decoded string (rather than crashing the request) - the
# strict Encode::decode throws on invalid sequences and we catch.
sub parse_query_string {
    my ($qs_source) = @_;
    my %query_params;
    return \%query_params unless defined $qs_source && length $qs_source;
    for my $pair ( split /&/, $qs_source ) {
        my ( $key, $val ) = split /=/, $pair, 2;
        next unless defined $key && length $key;
        $key =~ s/\+/ /g;
        $key =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $val = '' unless defined $val;
        $val =~ s/\+/ /g;
        $val =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

        # Decode as UTF-8. eval + strict-mode guard falls back to
        # the raw byte string on malformed input.
        $key = eval { decode( 'UTF-8', $key, 1 ) } // $key;
        $val = eval { decode( 'UTF-8', $val, 1 ) } // $val;

        # HTML-escape value before storing so TT renders it safely.
        # Applied after UTF-8 decode so we're escaping Unicode
        # characters, not individual UTF-8 bytes.
        $val =~ s/&/&amp;/g;
        $val =~ s/</&lt;/g;
        $val =~ s/>/&gt;/g;
        $val =~ s/"/&quot;/g;
        $val =~ s/'/&#39;/g;
        $query_params{$key} = $val;
    }
    return \%query_params;
}

# C-1 trust gate. Strip HTTP_X_REMOTE_* and HTTP_X_PAYMENT_*
# headers from %ENV unless one of the trusted-source signals is
# present: LAZYSITE_AUTH_TRUSTED=1 (set by lazysite-auth.pl after
# cookie validation) or auth_proxy_trusted: true in lazysite.conf
# (operator opt-in for upstream auth proxies). Logs a WARN if a
# client attempted to set these directly.
sub apply_trust_gate {
    my ($uri)         = @_;
    my %sv            = resolve_site_vars();
    my $proxy_trusted = lc( $sv{auth_proxy_trusted} // 'false' );
    my $auth_trusted  = $ENV{LAZYSITE_AUTH_TRUSTED} // '';
    return if ( $auth_trusted eq '1' ) || ( $proxy_trusted eq 'true' );

    if ( $ENV{HTTP_X_REMOTE_USER} ) {
        log_event( 'WARN', $uri,
            'untrusted auth header ignored - set auth_proxy_trusted: true to enable proxy auth',
            header => 'X-Remote-User',
            value  => substr( $ENV{HTTP_X_REMOTE_USER}, 0, 32 ) );
    }
    if ( $ENV{HTTP_X_PAYMENT_VERIFIED} ) {
        log_event( 'WARN', $uri,
            'untrusted payment header ignored',
            header => 'X-Payment-Verified' );
    }
    for my $hdr ( qw(
        HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS
        HTTP_X_REMOTE_NAME HTTP_X_REMOTE_EMAIL
        HTTP_X_PAYMENT_VERIFIED HTTP_X_PAYMENT_PAYER
        ) ) {
        delete $ENV{$hdr};
    }
}

# Enforce manager-path access control. Returns truthy if the
# request was fully handled (manager disabled -> forbidden,
# unauthenticated -> redirect, /manager -> /manager/ fixup).
# Caller must treat a truthy return as "done, stop processing
# this request". Returns falsy when the URI is not a manager
# path, or the user is authorised to proceed.
sub handle_manager_path {
    my ($uri)        = @_;
    my %sv           = resolve_site_vars();
    my $manager_path = $sv{manager_path} || '/manager';

    return 0
        unless $uri eq $manager_path
        || index( $uri, "$manager_path/" ) == 0;

    $ACCESS_REC{ch} = 'manager';    # SM140: operator traffic, not visitors

    my $manager_enabled = lc( $sv{manager} // 'disabled' );
    if ( $manager_enabled ne 'enabled' ) {
        forbidden();
        return 1;
    }

    my $auth_user   = $ENV{HTTP_X_REMOTE_USER}   // '';
    my $auth_groups = $ENV{HTTP_X_REMOTE_GROUPS} // '';

    unless ( _is_manager( \%sv, $auth_user, $auth_groups ) ) {
        my $redirect = $sv{auth_redirect} || '/login';
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        # SM188: when the user is NOT authenticated (a stale/invalid session -
        # e.g. the cookie-signing secret changed, or the session was revoked),
        # clear the JS lzs_session marker so /login shows the sign-in form instead
        # of a marker-driven "you are already signed in" screen that hides the
        # form and traps them in a redirect loop. An AUTHENTICATED non-manager
        # keeps their marker - they are legitimately signed in, just not an admin.
        if ( $auth_user eq '' ) {
            print "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0"
                . ( $ENV{HTTPS} ? "; Secure" : "" ) . "\r\n";
        }
        print "Location: $redirect?next=" . uri_encode($uri) . "\r\n\r\n";
        return 1;
    }

    # /manager -> /manager/ for directory index
    if ( $uri eq $manager_path ) {
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        print "Location: $manager_path/\r\n\r\n";
        return 1;
    }
    return 0;
}

# Attempt to serve a cached .html. Returns truthy if the request
# was served from cache. Callers should return on truthy.
# $html_stat and $md_stat are arrayrefs (possibly empty).
sub try_serve_cache {
    my ( $base, $md_path, $html_path, $html_stat, $md_stat ) = @_;
    return 0 unless @$md_stat && @$html_stat;

    # A cached render also depends on lazysite.conf: site_name, theme, layout,
    # nav, per-host alias overrides (site_url, lang, ...) all bake into the HTML.
    # A conf change that doesn't touch the .md must still invalidate the cache, or
    # a stale page is served - the reported "content-language: en / English chrome
    # on a French host after the conf declared alias.<host>.lang". So the cache is
    # fresh only when it post-dates BOTH its source AND the conf. This holds under
    # one-shot CGI and any persistent (FastCGI) worker alike - it is keyed on file
    # mtimes, not on a process's memory.
    my $conf_mtime = ( stat $CONF_FILE )[9] // 0;

    if ( $html_stat->[9] >= $md_stat->[9] && $html_stat->[9] >= $conf_mtime ) {
        $ACCESS_REC{c} = 1;    # SM140: served from the page cache
        log_event( 'DEBUG', $ENV{REDIRECT_URL} // '-', 'cache hit' );
        my $ct  = read_ct($base);
        my $ttl = peek_ttl($md_path);
        output_page( _inject_admin_bar_live( read_file($html_path), $md_path ),
            $ct, $ttl );
        return 1;
    }

    # mtime stale but page-level TTL may still keep the cache valid - still gated
    # on the conf being no newer than the cache.
    my $ttl = peek_ttl($md_path);
    if ( defined $ttl
        && $html_stat->[9] >= $conf_mtime
        && is_fresh_ttl_val_stat( $html_stat, $ttl ) )
    {
        my $ct = read_ct($base);
        output_page( _inject_admin_bar_live( read_file($html_path), $md_path ),
            $ct, $ttl );
        return 1;
    }
    return 0;
}

# Match the auth surface (login / logout) for "never cache these"
# decisions. The URL may be either the conf-configured
# auth_redirect value (default /login) or the corresponding
# /logout path; both are matched for their exact value and any
# sub-path.
sub is_auth_surface {
    my ($uri)         = @_;
    my %sv            = resolve_site_vars();
    my $auth_redirect = $sv{auth_redirect} || '/login';
    my $logout_path   = $auth_redirect;
    $logout_path =~ s{/login\b}{/logout};
    return $uri eq $auth_redirect
        || index( $uri, "$auth_redirect/" ) == 0
        || $uri eq $logout_path
        || index( $uri, "$logout_path/" ) == 0;
}

sub main {
    # M-2 / PC-2: localise %ENV for the request so $ENV writes below (log
    # level, NOCACHE, etc.) cannot leak across requests under FastCGI / D016.
    local %ENV = %ENV;

    my $uri = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '';

    # Capture query string before stripping
    my $qs_source = '';
    if ( $uri =~ s/\?(.*)$// ) {
        $qs_source = $1;
    }
    elsif ( defined $ENV{QUERY_STRING} && length $ENV{QUERY_STRING} ) {
        $qs_source = $ENV{QUERY_STRING};
    }
    my %query_params = %{ parse_query_string($qs_source) };

    # Block access to lazysite system directory
    if ( $uri eq $LAZYSITE_URI || index( $uri, $LAZYSITE_URI . '/' ) == 0 ) {
        forbidden();
        return;
    }

    # SM156: public instance marker. A domain-configuration check (the Domains
    # panel / `lazysite-domains check`) fetches this over the candidate host to
    # confirm the request TERMINATES on THIS install. Served BEFORE auth so it
    # answers on a freshly pointed domain with no session; CORS-open so the
    # manager's browser-side probe (a different origin) can read it. The body is
    # non-sensitive: a stable per-install id (one-way over the docroot path) and
    # the host we were asked for. Values are hex / DNS-alphabet only, so the
    # hand-built JSON needs no escaping.
    if ( $uri eq '/.well-known/lazysite-instance.json' ) {
        my $inst  = _instance_id();
        my $rhost = _request_host();
        binmode( STDOUT, ':utf8' );
        print "Status: 200 OK\r\n";
        print "Content-Type: application/json; charset=utf-8\r\n";
        print "Access-Control-Allow-Origin: *\r\n";
        print "Cache-Control: no-store\r\n\r\n";
        print qq({"ok":1,"instance":"$inst","host":"$rhost"});
        return;
    }

    # SM190: the OAuth discovery metadata (.well-known/oauth-authorization-server
    # and oauth-protected-resource) ship as api: content pages, so they render and
    # cache like any page - but they must not advertise an OAuth AS that
    # lazysite-oauth.pl 404s while oauth_enabled is off (the default). Gate them on
    # the killswitch here, BEFORE the render/cache path: a disabled service is not
    # advertised, and no stale "advertising" page is cached (a 404 is not cached).
    if ( $uri
        =~ m{^ /\.well-known/oauth-(?:authorization-server|protected-resource) (?:\.\w+)? \z}x
        && !_conf_flag_enabled('oauth_enabled') )
    {
        not_found($uri);
        return;
    }

    # Set log level from conf (env var takes priority). No local needed
    # here - %ENV is already localised at the top of main().
    {
        my %sv = resolve_site_vars();
        $ENV{LAZYSITE_LOG_LEVEL} = $sv{log_level}
            if $sv{log_level} && !$ENV{LAZYSITE_LOG_LEVEL};
        $ENV{LAZYSITE_LOG_FORMAT} = $sv{log_format}
            if $sv{log_format} && !$ENV{LAZYSITE_LOG_FORMAT};

        # SM110: alias-host cache handling happens where $html_path is
        # computed below - phase 2 gives each alias host its own cache slot
        # (phase 1's blanket NOCACHE is retired). See
        # docs/feature-requests/SM110-domain-aliases.md.
    }

    # Trust gate: strip HTTP_X_REMOTE_* / HTTP_X_PAYMENT_* unless
    # a trusted source (auth wrapper or configured proxy) set them.
    apply_trust_gate($uri);

    # Manager path gate. Returns truthy when the request is
    # already handled (forbidden, redirected, or bounced to login).
    return if handle_manager_path($uri);

    # NOTE: managers are NOT forced past the cache any more. The admin bar is no
    # longer baked into the rendered (cached) HTML - it is injected per-request at
    # output time (_inject_admin_bar_live) - so a manager can be served the same
    # bar-free cached page as everyone else and still get their bar. This both
    # restores cache benefit for managers and fixes the bar "not always showing"
    # when a manager request happened to be served from cache.

    # Sanitise URI against path traversal
    my $base = sanitise_uri($uri);
    unless ( defined $base ) {
        not_found($uri);
        return;
    }

    # SM073: .brief sidecars are private - never served publicly. In
    # production Apache denies them directly (FilesMatch); this covers
    # processor-routed requests (the dev server, or any non-existent path).
    if ( $base =~ /\.brief$/ ) {
        not_found($uri);
        return;
    }

    # SM151: per-domain content root. When the resolved site vars carry a
    # content_root (a base `content_root:` on the primary host, or an alias's
    # whitelisted override), the request is served from that confined subtree -
    # the domain's own '/'. confine_content_root() guarantees the root stays
    # inside the docroot and never reaches the lazysite/ tree (spec S1/S2); an
    # invalid or missing root degrades to the docroot root with a WARN (S6), so
    # one mis-configured domain can never take the instance down or leak a
    # sibling's tree. Unset content_root => $croot == $DOCROOT (unchanged).
    my $croot = $DOCROOT;
    {
        my %sv = resolve_site_vars();
        if ( defined $sv{content_root} && length $sv{content_root} ) {
            my $c = confine_content_root( $DOCROOT, $sv{content_root} );
            if ( defined $c ) {
                $croot = $c;
            }
            else {
                log_event( 'WARN', $uri,
                    'content_root rejected - serving docroot root',
                    host         => ( $sv{alias_host} || '-' ),
                    content_root => $sv{content_root} );
            }
        }
    }

    # SM151: publish the content root for this request so resolve_scan() (search)
    # boxes its glob to this domain's subtree. Set here, after confinement.
    $REQUEST_CROOT = $croot;

    my $md_path   = "$croot/$base.md";
    # SM201: a system page (login / claim / error) whose content-root copy is
    # absent falls back to the docroot root, then the protected engine default -
    # so a deleted or never-seeded copy self-heals instead of 404ing.
    if ( !-f $md_path && ( my $sys = _system_page_md( $base, $croot ) ) ) {
        $md_path = $sys;
    }
    my $url_path  = "$croot/$base.url";
    my $html_path = "$croot/$base.html";

    # SM110 phase 2: the page cache is host-keyed. An alias host reads and
    # writes its cached render in its own slot - $HOST_CACHE_DIR/<host>/,
    # mirroring the page's docroot-relative path - so an alias render can
    # never be served to the primary host or vice versa. The primary host
    # keeps the .html sibling exactly as before, and an alias host gets
    # exactly the same caching rules (protected/NOCACHE/TTL gating below is
    # host-agnostic), just in its own slots. $static_html_path stays on the
    # SIBLING for the SM133 legacy static-HTML fallback - that is authored
    # content, not a render cache. (SM151: the sibling now sits under the
    # domain's content root $croot, so a domain's legacy static pages live in
    # its own subtree; the render cache slot below is still host-keyed.)
    # Filesystem safety: _request_host() admits only DNS-shaped hosts
    # (labels of [a-z0-9-] joined by single dots - no '/', no '..', no
    # leading dot), so $sv{alias_host} is safe to use as one path segment.
    my $static_html_path = $html_path;
    {
        my %sv = resolve_site_vars();
        $html_path = "$HOST_CACHE_DIR/$sv{alias_host}/$base.html"
            if $sv{alias_host};
    }

    # Stat both source and cache files once - pass results to avoid redundant syscalls
    my @html_stat = stat($html_path);
    my @md_stat   = stat($md_path);

    # Auth check - before cache reads to prevent serving protected cached pages
    my $auth_protected = 0;
    my $auth_result    = { ok => 1 };
    my $auth_peek      = {};
    my %site_vars_peek;
    if (@md_stat) {
        $auth_peek      = peek_auth($md_path);
        %site_vars_peek = resolve_site_vars();
        $auth_result    = check_auth( $uri, $auth_peek, \%site_vars_peek );

        if ( $auth_result->{redirect} ) {
            binmode( STDOUT, ':utf8' );
            print "Status: 302 Found\r\n";
            # SM188: check_auth only returns a redirect for an UNauthenticated
            # request, so this bounce always means "no valid session" - clear the
            # stale lzs_session marker (see the manager bounce above) so the login
            # page shows the form rather than trapping the user.
            print "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0"
                . ( $ENV{HTTPS} ? "; Secure" : "" ) . "\r\n";
            print "Location: " . $auth_result->{redirect} . "\r\n\r\n";
            return;
        }
        if ( $auth_result->{forbidden} ) {
            %AUTH_CONTEXT = (
                authenticated        => 1,
                auth_user            => $auth_result->{auth_user}            // '',
                auth_name            => $auth_result->{auth_name}            // '',
                auth_denied_reason   => $auth_result->{auth_denied_reason}   // '',
                auth_required_groups => $auth_result->{auth_required_groups} // [],
                no_password          => $ENV{LAZYSITE_AUTH_NO_PASSWORD} ? 1 : 0,
            );
            serve_403($auth_result);
            return;
        }

        # Set auth context for TT rendering
        %AUTH_CONTEXT = (
            authenticated => $auth_result->{authenticated} // 0,
            auth_user     => $auth_result->{auth_user}     // '',
            auth_name     => $auth_result->{auth_name}     // '',
            auth_email    => $auth_result->{auth_email}    // '',
            auth_groups   => $auth_result->{auth_groups}   // [],
            no_password   => $ENV{LAZYSITE_AUTH_NO_PASSWORD} ? 1 : 0,
        );

        # Mark as protected if the page requires ANY auth (not just 'required')
        # or is group-restricted. A protected page is never served from - nor
        # written to - the global .html cache. This must cover EVERY non-public
        # auth level, notably `auth: manager`: a manager page's server-rendered
        # shell embeds per-user, capability-gated chrome (the nav menu gated on
        # manager_caps), so caching it would (a) serve a stale menu that ignores a
        # just-granted capability until the cache is busted - the "I granted the
        # cap but the Domains link never appeared without a re-login" bug - and
        # (b) leak one user's capability-gated menu to another via the shared
        # cache. Only `auth: none` (public) stays cacheable.
        my $auth_level = $auth_peek->{auth}
            || $site_vars_peek{auth_default}
            || 'none';
        $auth_protected = 1
            if $auth_level ne 'none'
            || ( $auth_peek->{groups} && @{ $auth_peek->{groups} } );
    }

    # Payment check (after auth - auth group bypass may apply)
    my $payment_protected = 0;
    if (@md_stat) {
        my $payment_peek = peek_payment($md_path);

        # Merge auth_groups from auth peek for bypass check
        if ( exists $auth_peek->{groups} && @{ $auth_peek->{groups} } ) {
            $payment_peek->{auth_groups} = $auth_peek->{groups};
        }

        my $payment_result = check_payment(
            $uri, $payment_peek, $auth_result, \%site_vars_peek );

        if ( $payment_result->{payment_required} ) {
            serve_402($payment_result);
            return;
        }

        if ( ( $payment_peek->{payment} // '' ) eq 'required' ) {
            $payment_protected = 1;

            %PAYMENT_CONTEXT = (
                payment_required => 0,
                payment_amount   => $payment_peek->{payment_amount}   // '',
                payment_currency => $payment_peek->{payment_currency} // '',
                payment_address  => $payment_peek->{payment_address}  // '',
                payment_paid     => $payment_result->{paid}           // 0,
                payment_payer    => $payment_result->{payer}          // '',
                payment_bypassed => $payment_result->{bypassed}       // 0,
            );
        }
    }

    # Combined protection flag. auth_protected / payment_protected come
    # from front-matter; is_auth_surface() covers login/logout, which
    # ship with `auth: none` but must never be cached because they
    # embed per-request TT variables (query.next etc.).
    my $protected = $auth_protected || $payment_protected
        || is_auth_surface($uri);

    # SM071: theme/layout preview. A valid preview cookie overrides the
    # active layout/theme for this request only (%PREVIEW_CONTEXT, merged
    # in render_content) and forces the request uncacheable - never served
    # from cache, never written to cache (NOCACHE), and no-store on output
    # via the protected flag. Reset per request so a stale value cannot
    # leak under a persistent interpreter.
    %PREVIEW_CONTEXT = ();
    if ( my $pv = check_preview() ) {
        %PREVIEW_CONTEXT       = ( layout => $pv->{layout}, theme => $pv->{theme} );
        $protected             = 1;
        $ENV{LAZYSITE_NOCACHE} = '1';
        log_event( 'INFO', $uri, 'preview render',
            layout => $pv->{layout}, theme => $pv->{theme}, user => $pv->{user} );
    }

    # Check if this page declares query_params and request has matching ones
    my $has_query_request = 0;
    my $declared_params   = undef;

    if ( %query_params && @md_stat ) {
        $declared_params = peek_query_params($md_path);
        if ($declared_params) {
            # Check if any declared param appears in the request
            for my $p (@$declared_params) {
                if ( exists $query_params{$p} ) {
                    $has_query_request = 1;
                    last;
                }
            }
        }
    }

    # nocache: true - render fresh on every request (dynamic per-request content
    # such as the visitor's own IP); never served from or written to the cache.
    if ( @md_stat && _peek_md($md_path)->{nocache} ) {
        $ENV{LAZYSITE_NOCACHE} = '1';
    }

    # Fast path: serve from cache if eligible. Skip when NOCACHE,
    # query-carrying request, or any protection flag is set.
    unless ( $ENV{LAZYSITE_NOCACHE} || $has_query_request || $protected ) {
        return if try_serve_cache( $base, $md_path, $html_path,
            \@html_stat, \@md_stat );
    }

    # .md exists but no cache yet - process it
    # realpath check runs here on the write path only, not on cache hits
    if (@md_stat) {
        # SM151: confine against the domain's content root (== $DOCROOT when no
        # content_root), so a symlink inside one domain's tree cannot serve a
        # sibling domain's or the docroot's files (spec S1).
        my $real = realpath($md_path);
        if ( !_path_under( $real, $croot ) ) {
            not_found($uri);
            return;
        }

        # Filter query params to declared allowlist only
        my %filtered_query;
        if ( $declared_params && $has_query_request ) {
            for my $p (@$declared_params) {
                $filtered_query{$p} = $query_params{$p}
                    if exists $query_params{$p};
            }
        }

        # Inject protection flag into filtered_query to prevent caching
        if ($protected) {
            $filtered_query{_protected} = 1;
        }

        my $page = process_md( $md_path, $html_path, $md_stat[9], \%filtered_query );
        my $ct   = peek_content_type($md_path);
        my $ttl  = $protected ? undef : peek_ttl($md_path);
        write_ct( $base, $ct ) unless $protected;
        log_event( 'INFO', $uri, 'page rendered' );
        # Admin bar added here (post-cache, per-viewer), not inside the cached page.
        output_page( _inject_admin_bar_live( $page, $md_path ), $ct, $ttl, $protected );
        return;
    }

    # Found .url - fetch remote content
    if ( -f $url_path ) {
        my $real = realpath($url_path);
        if ( !_path_under( $real, $croot ) ) {
            not_found($uri);
            return;
        }
        my $page = process_url( $url_path, $html_path, ( stat($url_path) )[9] );
        my $ct   = peek_content_type($url_path);
        write_ct( $base, $ct );
        output_page( _inject_admin_bar_live( $page, $url_path ), $ct );
        return;
    }

    # SM133: static-HTML fallback for migrations. With no .md/.url source but a
    # sibling static <base>.html present, serve it verbatim (a legacy page from a
    # pre-lazysite site) rather than 404ing. Auto-detected - no setting. A .md
    # always wins (handled above), so a page flips to lazysite the moment its
    # Markdown lands; a final cache-invalidate then clears any stale render.
    # NOTE: verbatim serve does NOT process Apache SSI - for SSI sites the vhost
    # rewrite (lazysite-app.tpl) maps the clean URL to the .html so Apache expands
    # includes; this branch is the portable net (dev server / non-Apache fronts).
    # (SM110: checked against the SIBLING path - a legacy static page is
    # authored content shared by every host, never a per-host render cache.)
    if ( -f $static_html_path ) {
        my $real = realpath($static_html_path);
        if ( _path_under( $real, $croot ) ) {
            my $ct = read_ct($base) || 'text/html; charset=utf-8';
            log_event( 'INFO', $uri, 'static-html fallback (no .md source)' );
            output_page( read_file($static_html_path), $ct );
            return;
        }
    }

    # SM151 P6: per-domain static files. On a content-rooted host, a request for
    # a real static file under the content root (sitemap.xml, feed.rss, robots.txt,
    # images, css, downloads) is served from that subtree with a content-type from
    # its extension - so each domain's own SEO artefacts and assets serve at its
    # URL. Production fronts serve these directly or via a per-host vhost rewrite;
    # this is the portable net (dev server / FallbackResource-only fronts). Gated
    # on $croot ne $DOCROOT so the primary docroot's behaviour is unchanged.
    if ( $croot ne $DOCROOT && _serve_content_static( $croot, $base ) ) {
        return;
    }

    # SM134: alias redirects. A page may declare `aliases:` (old/alternate URLs);
    # those are maintained in lazysite/aliases.json. Only when nothing else matched,
    # a requested path that is a known alias redirects to the canonical page - 301
    # by default, 302 for `aliases_temp:` entries (SM134 follow-ups). The target
    # is always the declaring page's own URL, so this is not an open redirect.
    if ( my $hit = _alias_lookup() ) {
        my ( $canon, $code ) = @{$hit};
        my $phrase = $code == 302 ? 'Found' : 'Moved Permanently';
        log_event( 'INFO', $uri, 'alias redirect', to => $canon, code => $code );
        # SEC-2026-07 (Low/Info): $canon is author-controlled (front-matter
        # aliases -> aliases.json). Strip CR/LF from the Location header (no
        # header injection) and HTML-escape it in the body (no reflected XSS).
        ( my $loc = $canon ) =~ s/[\r\n]//g;
        my $canon_h = _esc_html($canon);
        print "Status: $code $phrase\r\n";
        print "Location: $loc\r\n";
        print "Content-Type: text/html; charset=utf-8\r\n\r\n";
        print qq(<!DOCTYPE html><html><body>Moved to )
            . qq(<a href="$canon_h">$canon_h</a></body></html>\n);
        return;
    }

    # No source found - serve 404 page
    not_found($uri);
}

# Inline alias lookup for the 404 path: read lazysite/aliases.json and return
# [canonical URL, redirect code] for the requested path, or undef. Kept inline (no
# module load on the miss path); the map is written by Lazysite::Aliases on
# save/delete/move/copy. Schema (keep in sync with Lazysite::Aliases): a plain
# string value is a 301 target (the 0.6.1 format); { target, code } carries a 302.
# Anything else, or an unknown code, reads as 301.
sub _alias_lookup {
    my $f = "$DOCROOT/lazysite/aliases.json";
    return undef unless -f $f;
    my $req = $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '';
    $req =~ s/\?.*\z//;                      # drop any query string
    return undef unless length $req && $req =~ m{^/};
    $req =~ s{/+\z}{} unless $req eq '/';    # normalise trailing slash
    open my $fh, '<', $f or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $map = eval { decode_json( $raw // '{}' ) };
    return undef unless ref $map eq 'HASH';
    my $entry = $map->{$req};
    my ( $canon, $code ) =
        ref $entry eq 'HASH' ? ( $entry->{target}, $entry->{code} ) : ( $entry, 301 );
    $code = ( defined $code && $code =~ /\A302\z/ ) ? 302 : 301;
    # The target is our own canonical URL; still refuse anything not a clean
    # site-local path (defence in depth against a hand-edited map).
    return undef unless defined $canon && $canon =~ m{^/} && $canon !~ m{^//};
    return undef if $canon =~ /[\0\r\n]/;
    return [ $canon, $code ];
}

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
        # Strip file extension
        $uri =~ s/\.(html|md|url)$//;
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

# SM151 §7: the directories declared as content roots in lazysite.conf (the base
# `content_root:` and every `alias.<host>.content_root:`), as absolute paths
# under the docroot. A page scan skips any directory in this set that is not its
# own scan root, so a bare-docroot host's sitemap/search never enumerates a
# client subtree, and no domain lists a nested sub-domain's pages. Paths are the
# plain "$DOCROOT/<rel>" string form (not realpath) to match the scan walk,
# which builds "$dir/$entry" from the docroot down; symlinked dirs are already
# skipped separately, so no symlink normalisation is needed here.
sub _declared_content_roots {
    my %roots;
    return \%roots unless -f $CONF_FILE;
    my $text = read_file($CONF_FILE);
    return \%roots unless defined $text;
    while ( $text =~ /^(?:alias\.\S+\.)?content_root\s*:\s*(.+?)\s*$/mg ) {
        ( my $rel = $1 ) =~ s{^/+|/+$}{}g;
        next unless length $rel;
        next if $rel =~ m{(?:^|/)\.\.(?:/|$)};    # ignore traversal shapes
        $roots{"$DOCROOT/$rel"} = 1;
    }
    return \%roots;
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
    my $lzdir = realpath("$docroot/lazysite");    # may not exist

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
sub _serve_content_static {
    my ( $root, $rel ) = @_;
    return 0 unless length $rel;
    my ($ext) = $rel =~ /\.([A-Za-z0-9]+)\z/;
    return 0 unless defined $ext;

    my $path = "$root/$rel";
    return 0 unless -f $path;
    my $real = realpath($path);
    return 0 unless defined $real && index( $real, "$root/" ) == 0;

    open my $fh, '<', $real or return 0;
    binmode $fh;
    my $data = do { local $/; <$fh> };
    close $fh;

    my $ct = $STATIC_CT{ lc $ext } || 'application/octet-stream';
    $ACCESS_REC{s} //= 200;
    $ACCESS_REC{b} = length( $data // '' );
    binmode(STDOUT);
    print "Status: 200 OK\n";
    print "Content-type: $ct\n";
    print "X-Content-Type-Options: nosniff\n";
    print "Cache-Control: no-cache, must-revalidate\n";
    print "\n";
    print $data;
    return 1;
}

sub process_md {
    my ( $md_path, $html_path, $md_mtime, $query ) = @_;
    $query //= {};

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

    # Only cache if no query params - query responses are dynamic
    if ( !%$query ) {
        write_html( $html_path, $page );
        eval { update_registries() };
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'registry update failed', error => $@ ) if $@;
    }

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
        # No cache - render error block
        return render_template(
            { title => 'Content Unavailable' },
            qq(<div class="errorbox">\n<p>Could not fetch remote content from <code>$url</code>.</p>\n</div>\n)
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
    unless ( $INC{'Lazysite/I18n.pm'} ) {
        require Cwd;
        require File::Basename;
        my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
        for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
            if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
        }
        require Lazysite::I18n;
    }
    return Lazysite::I18n::chrome_string( $DOCROOT, _chrome_lang(), $key, @args );
}

sub fetch_url {
    my ($url) = @_;
    unless ( $INC{'Lazysite/Fetch.pm'} ) {
        require Cwd;
        require File::Basename;
        my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
        for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
            if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
        }
        require Lazysite::Fetch;
    }
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
    if (   ( $m->{raw} || $m->{api} )
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
    return $h >= ( ( stat $CONF_FILE )[9] // 0 );
}

# --- D035 Phase 3: minimal nested-YAML for front-matter `sections:` -----------
# A self-contained indentation parser for the subset `sections:` needs: a top
# sequence of single-key maps, nested maps, nested sequences, inline flow maps
# {k: v, ...} / seqs [a, b], and quoted/bareword scalars. Only runs for pages
# that declare `sections:`; everything else is untouched. Not a general YAML.
sub _yaml_scalar {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return undef if $s eq '' || $s eq '~' || lc $s eq 'null';
    return $1    if $s =~ /^"(.*)"$/s;
    return $1    if $s =~ /^'(.*)'$/s;
    return $s;
}

sub _yaml_split_flow {
    my ($s) = @_;
    my @parts;
    my ( $cur, $depth, $q ) = ( '', 0, '' );
    for my $ch ( split //, $s ) {
        if ($q)                          { $cur .= $ch; $q = '' if $ch eq $q; next }
        if ( $ch eq '"' || $ch eq "'" )  { $q = $ch; $cur .= $ch; next }
        if ( $ch eq '{' || $ch eq '[' )  { $depth++; $cur .= $ch; next }
        if ( $ch eq '}' || $ch eq ']' )  { $depth--; $cur .= $ch; next }
        if ( $ch eq ',' && $depth == 0 ) { push @parts, $cur; $cur = ''; next }
        $cur .= $ch;
    }
    push @parts, $cur if $cur =~ /\S/;
    return @parts;
}

sub _yaml_value {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    if ( $s =~ /^\{(.*)\}$/s ) {
        my %h;
        for my $pair ( _yaml_split_flow($1) ) {
            next unless $pair =~ /^\s*(.+?)\s*:\s*(.*)$/s;
            $h{ _yaml_scalar($1) } = _yaml_value($2);
        }
        return \%h;
    }
    if ( $s =~ /^\[(.*)\]$/s ) {
        return [ map { _yaml_value($_) } _yaml_split_flow($1) ];
    }
    return _yaml_scalar($s);
}

# Recursive block parser over [indent, text] tokens.
sub _yaml_block {
    my ( $toks, $i, $ind ) = @_;
    return undef if $$i > $#$toks || $toks->[$$i][0] < $ind;
    my $first = $toks->[$$i][1];

    if ( $first =~ /^-(?:\s|$)/ ) {    # sequence
        my @seq;
        while ( $$i <= $#$toks
            && $toks->[$$i][0] == $ind
            && $toks->[$$i][1] =~ /^-(?:\s|$)/ )
        {
            ( my $rest = $toks->[$$i][1] ) =~ s/^-\s*//;
            my @sub;
            push @sub, [ $ind + 2, $rest ] if length $rest;
            $$i++;
            while ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                push @sub, $toks->[$$i];
                $$i++;
            }
            my $j = 0;
            push @seq, _yaml_block( \@sub, \$j, $ind + 2 );
        }
        return \@seq;
    }

    if ( $first !~ /^[\[{]/ && $first =~ /^(.+?)\s*:\s*(.*)$/ ) {    # mapping
        my %map;
        while ( $$i <= $#$toks && $toks->[$$i][0] == $ind ) {
            my $line = $toks->[$$i][1];
            last if $line     =~ /^-(?:\s|$)/;
            last unless $line =~ /^(.+?)\s*:\s*(.*)$/;
            my ( $k, $v ) = ( _yaml_scalar($1), $2 );
            $$i++;
            if ( defined $v && $v =~ /\S/ ) {
                $map{$k} = _yaml_value($v);
            }
            elsif ( $$i <= $#$toks && $toks->[$$i][0] > $ind ) {
                $map{$k} = _yaml_block( $toks, $i, $toks->[$$i][0] );
            }
            else { $map{$k} = undef }
        }
        return \%map;
    }

    my $v = _yaml_value($first);    # bare scalar / flow
    $$i++;
    return $v;
}

sub _parse_sections {
    my ($block) = @_;
    my @toks;
    for my $line ( split /\n/, $block ) {
        next if $line !~ /\S/;
        next if $line =~ /^\s*#/;
        my ($lead) = $line =~ /^(\s*)/;
        ( my $expanded = $lead ) =~ s/\t/    /g;
        ( my $text     = $line ) =~ s/^\s+//;
        $text =~ s/\s+$//;
        push @toks, [ length $expanded, $text ];
    }
    return [] unless @toks;
    my $i    = 0;
    my $data = _yaml_block( \@toks, \$i, $toks[0][0] );
    return ref $data eq 'ARRAY' ? $data : [];
}

sub parse_yaml_front_matter {
    my ($text) = @_;
    my %meta;

    if ( $text =~ s/\A---\s*\n(.*?)\n---\s*\n//s ) {
        my $yaml = $1;

        # Parse register list (- item lines)
        if ( $yaml =~ /^register\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @registries;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @registries, strip_tt_directives($1);
            }
            $meta{register} = \@registries;
        }

        # Parse tt_page_var block (indented key: value pairs)
        # The alternation (?:\n|$) handles the last line which may have no
        # trailing newline if it is the final line of the front matter block
        if ( $yaml =~ /^tt_page_var\s*:\s*\n((?:[ \t]+\S[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my %tt_vars;
            while ( $block =~ /^[ \t]+(\w+)\s*:\s*(.+)$/mg ) {
                $tt_vars{$1} = $2;
            }
            $meta{tt_page_var} = \%tt_vars;
        }

        # Parse tags list (- item lines)
        if ( $yaml =~ /^tags\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @tags;
            while ( $block =~ /^[ \t]*-[ \t]*(.+?)[ \t]*$/mg ) {
                push @tags, strip_tt_directives($1);
            }
            $meta{tags} = \@tags;
        }

        # Parse auth_groups list (- item lines)
        if ( $yaml =~ /^auth_groups\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @groups;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @groups, $1;
            }
            $meta{auth_groups} = \@groups;
        }

        # Parse query_params list (- item lines)
        if ( $yaml =~ /^query_params\s*:\s*\n((?:[ \t]*-[^\n]*(?:\n|$))*)/m ) {
            my $block = $1;
            my @params;
            while ( $block =~ /^[ \t]*-[ \t]*(\S+)/mg ) {
                push @params, $1;
            }
            $meta{query_params} = \@params;
        }

        # D035 Phase 3: parse the nested `sections:` block (data-driven pages).
        # Captures indented/blank lines after `sections:` up to the next
        # column-0 key, then hands them to the minimal nested-YAML parser.
        if ( $yaml =~ /^sections\s*:[ \t]*\n((?:[ \t]+\S[^\n]*\n?|[ \t]*\n)*)/m ) {
            my $parsed = _parse_sections($1);
            $meta{sections} = $parsed if @$parsed;
        }

        # Parse scalar key: value pairs (skip tt_page_var, register, query_params blocks)
        while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
            next if $1 eq 'tt_page_var';
            next if $1 eq 'register';
            next if $1 eq 'query_params';
            next if $1 eq 'sections'; # nested block; parsed above (and \s* here would eat its first line)
            next if $1 eq 'tags'        && ref $meta{tags} eq 'ARRAY';
            next if $1 eq 'auth_groups' && ref $meta{auth_groups} eq 'ARRAY';
            # Strip TT directives from all scalar values including title and subtitle
            my ( $k, $v ) = ( $1, strip_tt_directives($2) );
            # YAML quoting: a matched pair of surrounding quotes is syntax, not
            # content - strip one level so `title: "Welcome"` yields Welcome (not
            # a literal "Welcome" that a template then double-quotes).
            $v =~ s/\s+\z//;
            $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
            $meta{$k} = $v;
        }

        # Sanitise auth value
        if ( defined $meta{auth} ) {
            $meta{auth} = lc( $meta{auth} );
            $meta{auth} = 'none'
                unless $meta{auth} =~ /^(required|optional|none)$/;
        }

        # Sanitise form name
        if ( defined $meta{form} ) {
            $meta{form} =~ s/[^a-zA-Z0-9_-]//g;
            delete $meta{form} unless length $meta{form};
        }
    }

    return ( \%meta, $text );
}

# --- Forms ---

# --- SM071 Phase 1: theme/layout preview ---------------------------------
#
# A signed, short-lived cookie lets an authorised user render the live
# site against an alternative layout/theme for their session only. The
# cookie reuses the auth-cookie primitive (payload ":" hmac_sha256_hex),
# signed with the shared auth secret at lazysite/auth/.secret. It is
# minted elsewhere (manager UI / SM071 control API); here we only verify
# it and, when valid, expose the override (%PREVIEW_CONTEXT) and force the
# request uncacheable. Payload: v1:<exp-epoch>:<layout>:<theme>:<user>.

# Read a single cookie value from the request. '' when absent.
sub read_request_cookie {
    my ($name) = @_;
    my $cookies = $ENV{HTTP_COOKIE} // '';
    for my $pair ( split /;\s*/, $cookies ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && defined $v;
        return $v if $k eq $name;
    }
    return '';
}

# Read-only load of the shared auth secret. Unlike the auth wrapper we
# never create it here: if it is absent, no valid preview cookie can
# exist, so verification fails closed.
sub load_preview_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    chomp( my $s = <$fh> );
    close $fh;
    return ( defined $s && length $s ) ? $s : undef;
}

# Constant-time compare (mirrors lazysite-auth.pl const_eq).
sub preview_const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b && length $a == length $b;
    my $diff = 0;
    $diff |= ord( substr $a, $_, 1 ) ^ ord( substr $b, $_, 1 )
        for 0 .. length($a) - 1;
    return $diff == 0;
}

# Verify the preview cookie. Returns { layout, theme, user } when a
# valid, unexpired cookie is present, else undef. No filesystem access
# on the common (no-cookie) path.
sub check_preview {
    my $cookie = read_request_cookie($PREVIEW_COOKIE);
    return undef unless length $cookie;

    my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
    return undef unless defined $payload && defined $sig;

    my $secret = load_preview_secret();
    return undef unless defined $secret;
    return undef
        unless preview_const_eq( $sig, hmac_sha256_hex( $payload, $secret ) );

    my ( $ver, $exp, $layout, $theme, $user ) = split /:/, $payload, 5;
    return undef unless defined $ver && $ver eq 'v1';
    return undef unless defined $exp && $exp =~ /^\d+$/ && time() < $exp;
    $layout //= '';
    $theme  //= '';
    return undef
        unless length $layout
        && $layout =~ /^[A-Za-z0-9_-]+$/
        && $theme  =~ /^[A-Za-z0-9_-]*$/;

    return { layout => $layout, theme => $theme, user => ( $user // '' ) };
}

sub load_form_secret {
    my $secret_path = "$LAZYSITE_DIR/forms/.secret";
    my $forms_dir   = "$LAZYSITE_DIR/forms";
    make_path($forms_dir) unless -d $forms_dir;

    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or do {
            log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot read form secret', error => $! );
            return '';
        };
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }

    # M-6: fail closed if CSPRNG unavailable.
    open( my $rand, '<:raw', '/dev/urandom' )
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close($rand);
    die "Short read from /dev/urandom ($got of 32 bytes)\n"
        unless defined $got && $got == 32;
    my $s = unpack( 'H*', $raw );

    open( my $fh, '>', $secret_path ) or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot write form secret', error => $! );
        return $s;
    };
    # 0660: identity-shared secret (site-user CLI/dev-server + www-data CGI,
    # via the setgid forms dir group). Owner-only minting locks the CGI out.
    chmod 0o660, $secret_path;
    print $fh "$s\n";
    close($fh);
    return $s;
}

sub convert_fenced_form {
    my ( $text, $meta ) = @_;
    $meta //= {};

    # SM161: accept BOTH ":::form" and "::: form" as the opening fence. The
    # space used to be required ([ \t]+), but the bind_form tool's own example
    # (and pandoc's own fenced-div convention) writes ":::form" with no space, so
    # an agent following the docs shipped a form that rendered as literal text.
    $text =~ s{
        ^:::[ \t]*form[ \t]*\n    # opening :::form  OR  ::: form
        (.*?)                      # field definitions
        ^:::[ \t]*\n               # closing :::
    }{
        _render_form( $1, $meta );
    }gesmx;

    return $text;
}

sub _render_form {
    my ( $body, $meta ) = @_;

    my $form_name = $meta->{form} // '';
    unless ($form_name) {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'form block found but no form key in front matter' );
        return "<!-- lazysite: form: key required in front matter -->\n";
    }

    my $ts     = time();
    my $secret = load_form_secret();
    my $tk     = hmac_sha256_hex( $ts, $secret );

    # SM098: a '--- step ---' line (optionally '--- step: Title ---') splits the
    # form into wizard steps. Fields accumulate into the current step; without any
    # delimiter there is a single step = the classic single-page form (unchanged).
    my @steps = ( { title => '', fields => [] } );
    for my $line ( split /\n/, $body ) {
        if ( $line =~ /^\s*-{3,}\s*step\b\s*:?\s*(.*?)\s*-{3,}\s*$/i ) {
            push @steps, { title => $1, fields => [] };
            next;
        }
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;

        my ( $name, $label, $rules_str ) = split /\s*\|\s*/, $line, 3;
        $name      //= '';
        $label     //= '';
        $rules_str //= '';
        $name  =~ s/^\s+|\s+$//g;
        $label =~ s/^\s+|\s+$//g;

        next unless length $name;

        if ( $name eq 'submit' ) {
            push @{ $steps[-1]{fields} }, qq(  <div class="form-field form-submit">\n)
                . qq(    <button type="submit">$label</button>\n)
                . qq(  </div>\n);
            next;
        }

        # Parse rules. Tokens are whitespace-separated, but a key:"value" may
        # quote a value that contains spaces (e.g. placeholder:"Your full name"
        # or pattern:"[0-9 +()-]{7,20}").
        my %rules;
        my @rule_tokens;
        my $rs = $rules_str;
        while ( length $rs ) {
            $rs =~ s/^\s+//;
            last unless length $rs;
            # select: takes the REST of the line - its comma-separated options may
            # contain spaces, so put select: last among a field's rules. (Quotes
            # around the list or an option are tolerated and stripped on render.)
            if    ( $rs =~ s/^(select:.*)\z//s )        { push @rule_tokens, $1; }
            elsif ( $rs =~ s/^([A-Za-z]+:)"([^"]*)"// ) { push @rule_tokens, "$1$2"; }
            elsif ( $rs =~ s/^(\S+)// )                 { push @rule_tokens, $1; }
            else                                        { last; }
        }
        for my $r (@rule_tokens) {
            if    ( $r eq 'required' ) { $rules{required} = 1; }
            elsif ( $r eq 'optional' ) { $rules{optional} = 1; }
            elsif ( $r eq 'email' )    { $rules{type}     = 'email'; }
            elsif ( $r =~ /^(tel|date|time|number|url|password)$/ ) { $rules{type} = $1; }
            elsif ( $r eq 'textarea' )          { $rules{textarea} = 1; }
            elsif ( $r eq 'file' )              { $rules{file}     = 1; }
            elsif ( $r eq 'multiple' )          { $rules{multiple} = 1; }
            elsif ( $r =~ /^accept:(.+)/ )      { $rules{accept}   = $1; }
            elsif ( $r =~ /^select:(.+)/ )      { $rules{select}   = [ split /,/, $1 ]; }
            elsif ( $r =~ /^max:(\d+)/ )        { $rules{max}      = $1; }
            elsif ( $r =~ /^min:(\d+)/ )        { $rules{min}      = $1; }
            elsif ( $r =~ /^pattern:(.+)/ )     { $rules{pattern}  = $1; }
            elsif ( $r =~ /^placeholder:(.+)/ ) { $rules{placeholder} = $1; }
        }
        my $ph_attr = '';
        if ( defined $rules{placeholder} ) {
            ( my $ph = $rules{placeholder} ) =~ s/&/&amp;/g;
            $ph =~ s/"/&quot;/g;
            $ph_attr = qq( placeholder="$ph");
        }

        my $req_attr = $rules{required} ? ' required' : '';
        my $max      = $rules{max} || 1000;
        my $req_mark = $rules{required}
            ? ' <span class="required">*</span>' : '';

        my $field_html;
        if ( $rules{file} ) {
            my $acc = '';
            if ( defined $rules{accept} ) {
                ( my $a = $rules{accept} ) =~ s/&/&amp;/g;
                $a =~ s/"/&quot;/g;
                $acc = qq( accept="$a");
            }
            my $mult = $rules{multiple} ? ' multiple' : '';
            $field_html = qq(    <input type="file" name="$name" id="$name")
                . $acc . $mult . qq($req_attr>\n);
        }
        elsif ( $rules{textarea} ) {
            $field_html = qq(    <textarea name="$name" id="$name")
                . qq( maxlength="$max"$ph_attr$req_attr></textarea>\n);
        }
        elsif ( $rules{select} ) {
            $field_html = qq(    <select name="$name" id="$name"$req_attr>\n);
            $field_html .= qq(      <option value="">-- Select --</option>\n);
            for my $opt ( @{ $rules{select} } ) {
                $opt =~ s/^\s+|\s+$//g;
                $opt =~ s/^"+//; $opt =~ s/"+$//; # tolerate a quoted option list / option
                $opt =~ s/^\s+|\s+$//g;
                next unless length $opt;
                $field_html .= qq(      <option value="$opt">$opt</option>\n);
            }
            $field_html .= qq(    </select>\n);
        }
        else {
            my $type  = $rules{type} || 'text';
            my $attrs = '';
            if ( $type eq 'number' ) {
                # For numbers, min/max are value bounds (not maxlength).
                $attrs .= qq( min="$rules{min}") if defined $rules{min};
                $attrs .= qq( max="$rules{max}") if defined $rules{max};
            }
            else {
                $attrs .= qq( maxlength="$max");
            }
            # tel gets a sensible default validation pattern unless overridden.
            my $pat = $rules{pattern};
            $pat = '[\\d\\s()+.-]{6,20}' if !defined $pat && $type eq 'tel';
            if ( defined $pat ) {
                $pat =~ s/&/&amp;/g;
                $pat =~ s/"/&quot;/g;
                $attrs .= qq( pattern="$pat");
            }
            $field_html = qq(    <input type="$type" name="$name" id="$name")
                . $attrs . $ph_attr . qq($req_attr>\n);
        }

        push @{ $steps[-1]{fields} }, qq(  <div class="form-field">\n)
            . qq(    <label for="$name">$label$req_mark</label>\n)
            . $field_html
            . qq(  </div>\n);
    }

    # Drop steps that ended up with no fields (e.g. a leading delimiter).
    @steps = grep { @{ $_->{fields} } } @steps;
    @steps = ( { title => '', fields => [] } ) unless @steps;
    my $multi = @steps > 1;

    my $all_fields = join( '', map { @{ $_->{fields} } } @steps );

    # A form with a file input must POST as multipart/form-data, or the browser
    # sends only the filename, not the bytes.
    my $enctype = $all_fields =~ /type="file"/
        ? qq(\n      enctype="multipart/form-data") : '';

    # SM098: assemble the fields region. Single step = flat (unchanged). Multi =
    # one <fieldset> per step + progress + Back/Next nav; a script shows one step
    # at a time and validates it before advancing. Without JS every step shows and
    # the form still submits (progressive enhancement).
    my ( $fields_html, $multistep_attr, $step_css, $extra_script ) = ( '', '', '', '' );
    if ($multi) {
        $multistep_attr = ' data-multistep="1"';
        my $n = scalar @steps;
        $fields_html = qq(  <div class="lsf-progress" aria-hidden="true">Step )
            . qq(<span class="lsf-cur">1</span> of $n</div>\n);
        for my $i ( 0 .. $#steps ) {
            my $legend = length $steps[$i]{title}
                ? qq(    <legend>$steps[$i]{title}</legend>\n) : '';
            $fields_html .= qq(  <fieldset class="lsf-step" data-step="$i">\n)
                . $legend . join( '', @{ $steps[$i]{fields} } ) . qq(  </fieldset>\n);
        }
        $fields_html .= qq(  <div class="lsf-nav">\n)
            . qq(    <button type="button" class="lsf-back">Back</button>\n)
            . qq(    <button type="button" class="lsf-next">Next</button>\n)
            . qq(  </div>\n);
        $step_css     = _form_step_css();
        $extra_script = _form_step_script($form_name);
    }
    else {
        $fields_html = join( '', @{ $steps[0]{fields} } );
    }

    return <<"END_FORM";
$step_css<form method="POST"
      action="/cgi-bin/form-handler.pl"$enctype
      class="lazysite-form"
      data-form="$form_name"$multistep_attr>
  <input type="hidden" name="_form" value="$form_name">
  <input type="hidden" name="_ts" value="$ts">
  <input type="hidden" name="_tk" value="$tk">
  <div style="position:absolute;left:-9999px;top:-9999px;"
       aria-hidden="true">
    <label for="_hp">Leave this empty</label>
    <input type="text" name="_hp" id="_hp" value=""
           tabindex="-1" autocomplete="off">
  </div>
$fields_html  <div class="form-status" aria-live="polite"></div>
</form>
$extra_script<script>
(function() {
  var form = document.querySelector('.lazysite-form[data-form="$form_name"]');
  if (!form) return;
  form.addEventListener('submit', function(e) {
    e.preventDefault();
    var btn    = form.querySelector('button[type=submit]');
    var status = form.querySelector('.form-status');
    btn.disabled = true;
    status.textContent = 'Sending...';
    fetch(form.action, {
      method: 'POST',
      body: new FormData(form)
    })
    .then(function(r) {
      if (!r.ok) throw new Error('Server returned ' + r.status);
      return r.json();
    })
    .then(function(data) {
      if (data.ok) {
        form.innerHTML = '<p class="form-success">' +
          (data.message || 'Thank you - message sent.') + '</p>';
      } else {
        status.textContent = data.error || 'An error occurred.';
        btn.disabled = false;
      }
    })
    .catch(function(e) {
      status.textContent = 'Could not send: ' + e.message;
      btn.disabled = false;
    });
  });
})();
</script>
END_FORM
}

# SM098: inline CSS for a multi-step form. Without the JS-added `lsf-js` class,
# every step shows and the nav is hidden (progressive enhancement); with it, only
# the active step shows and the Back/Next nav appears.
sub _form_step_css {
    return <<'END_CSS';
<style>
.lazysite-form[data-multistep] .lsf-nav{display:none}
.lazysite-form.lsf-js[data-multistep] .lsf-step:not(.lsf-active){display:none}
.lazysite-form.lsf-js[data-multistep] .lsf-nav{display:flex;gap:.5rem;margin-top:1rem}
.lazysite-form[data-multistep] .lsf-progress{font-size:.9em;opacity:.75;margin-bottom:.75rem}
</style>
END_CSS
}

# SM098: the step-navigation script for a multi-step form. Shows one step at a
# time, validates the visible step (native constraint API) before advancing, and
# keeps the Back/Next/submit affordances in sync. The final step exposes the
# authored submit button; the existing submit handler posts the whole form once.
sub _form_step_script {
    my ($form_name) = @_;
    return <<"END_STEP";
<script>
(function(){
  var form = document.querySelector('.lazysite-form[data-form="$form_name"][data-multistep]');
  if (!form) return;
  form.classList.add('lsf-js');
  var steps = Array.prototype.slice.call(form.querySelectorAll('.lsf-step'));
  if (!steps.length) return;
  var back = form.querySelector('.lsf-back');
  var next = form.querySelector('.lsf-next');
  var cur  = form.querySelector('.lsf-cur');
  var i = 0;
  function show(n){
    i = Math.max(0, Math.min(steps.length - 1, n));
    for (var k = 0; k < steps.length; k++){ steps[k].classList.toggle('lsf-active', k === i); }
    if (cur)  cur.textContent = (i + 1);
    if (back) back.style.display = (i === 0) ? 'none' : '';
    if (next) next.style.display = (i === steps.length - 1) ? 'none' : '';
  }
  function stepValid(){
    var els = steps[i].querySelectorAll('input, select, textarea');
    for (var k = 0; k < els.length; k++){
      if (!els[k].checkValidity()){ els[k].reportValidity(); return false; }
    }
    return true;
  }
  if (next) next.addEventListener('click', function(){ if (stepValid()) show(i + 1); });
  if (back) back.addEventListener('click', function(){ show(i - 1); });
  show(0);
})();
</script>
END_STEP
}

sub convert_fenced_divs {
    my ($text) = @_;

    $text =~ s{
        ^(:::[ \t]+(\S+)[^\n]*)\n  # opening ::: classname [rest of line]
        (.*?)                       # content
        ^:::[ \t]*\n                # closing :::
    }{
        my $opening = $1;
        my $class   = $2;
        my $body    = $3;
        # Skip 'include' and 'oembed' - handled by dedicated converters
        if ( $class eq 'include' || $class eq 'oembed' ) {
            "$opening\n${body}:::\n";
        }
        # Reject class names containing unsafe characters (S4)
        # Valid: word chars and hyphens only, must start with a word char
        elsif ( $class =~ /\A[\w][\w-]*\z/ ) {
            # Render the body's Markdown (block AND inline) so headings/lists
            # inside a box don't leak as literal '##' - Text::MultiMarkdown
            # otherwise treats <div> content as verbatim HTML. Skip pre-render if
            # the body nests another fenced block (include/oembed/form) that the
            # later pipeline passes must still see.
            my $inner = ( $body =~ /^:::/m ) ? $body : convert_md($body);
            qq(<div class="$class">\n${inner}</div>\n);
        }
        else {
            log_event('WARN', $ENV{REDIRECT_URL} // '-', 'fenced div rejected unsafe class', class => $class);
            $body;
        }
    }gsmxe;

    return $text;
}

# --- Content components (D035 Phase 2) ------------------------------------
# A ::: <name> fence whose <name> matches components/<name>.tt under the active
# layout is rendered THROUGH that component: the inner Markdown becomes
# `content`, key="value" pairs on the opening line become `attrs`, and direct
# child ::: <slot> fences become `slots.<slot>`. Fence names with no matching
# component pass through untouched to convert_fenced_divs. Balanced (nesting-
# aware), and byte-preserving for everything that is not a component block.
sub _component_exists {
    my ( $layout_dir, $name ) = @_;
    return 0 unless defined $name   && $name =~ /\A[\w-]+\z/;
    return 1 if defined $layout_dir && -f "$layout_dir/components/$name.tt";
    # Built-in components (e.g. ::: qr) ship under lazysite/templates/components
    # and are available on ANY layout - a layout component of the same name wins.
    return 1 if -f "$LAZYSITE_DIR/templates/components/$name.tt";
    return 0;
}

sub _md_fragment {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    return '' unless defined $text && $text =~ /\S/;
    $text .= "\n" unless $text =~ /\n\z/;    # fence closers need a trailing newline
        # Run the inner through the same fence passes as the page body, so a component
        # can contain nested components, fenced divs and includes - then Markdown.
    my $t = convert_fenced_components( $text, $layout_dir, $md_path, $meta );
    $t = convert_fenced_divs($t);
    $t = convert_fenced_include( $t, $md_path, $meta ) if defined $md_path;
    my $html = convert_md($t);
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    return $html;
}

sub convert_fenced_components {
    my ( $text, $layout_dir, $md_path, $meta ) = @_;
    # Proceed if the active layout has a components/ dir OR built-in components
    # exist (::: qr and friends work even on a layout that ships none).
    return $text
        unless ( defined $layout_dir && -d "$layout_dir/components" )
        || -d "$LAZYSITE_DIR/templates/components";
    return $text unless $text =~ /^:::[ \t]+[\w-]+/m;    # fast bail

    my @lines = split /\n/, $text, -1;
    my @out;
    my $i = 0;
    while ( $i <= $#lines ) {
        my $l = $lines[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*(.*?)[ \t]*$/
            && _component_exists( $layout_dir, $1 ) )
        {
            my ( $name, $attr ) = ( $1, $2 );
            my @inner;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#lines && $depth > 0 ) {
                my $x = $lines[$j];
                if ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @inner, $x }
                elsif ( $x =~ /^:::[ \t]*$/ ) { $depth--; push @inner, $x if $depth > 0 }
                else                          { push @inner, $x }
                $j++;
            }
            if ( $depth != 0 ) { push @out, $l; $i++; next; }    # unbalanced: leave as-is
            push @out, _render_component( $layout_dir, $name, $attr,
                join( "\n", @inner ), $md_path, $meta );
            $i = $j;
        }
        else { push @out, $l; $i++; }
    }
    return join "\n", @out;
}

sub _render_component {
    my ( $layout_dir, $name, $attr_str, $inner, $md_path, $meta ) = @_;

    my %attrs;
    while ( $attr_str =~ /([\w-]+)\s*=\s*"([^"]*)"/g ) { $attrs{$1} = $2 }
    while ( $attr_str =~ /([\w-]+)\s*=\s*'([^']*)'/g ) { $attrs{$1} //= $2 }

    # Direct-child ::: <slot> fences whose name is NOT itself a component become
    # named slots; a child fence that IS a component (or any other content) goes
    # to content, where _md_fragment renders it (nested components).
    my ( %slots, @content_lines );
    my @il = split /\n/, $inner, -1;
    my $i  = 0;
    while ( $i <= $#il ) {
        my $l = $il[$i];
        if ( $l =~ /^:::[ \t]+([\w-]+)[ \t]*.*$/ ) {
            my $fence = $1;
            my @sb;
            my $depth = 1;
            my $j     = $i + 1;
            while ( $j <= $#il && $depth > 0 ) {
                my $x = $il[$j];
                if ( $x =~ /^:::[ \t]+\S/ ) { $depth++; push @sb, $x }
                elsif ( $x =~ /^:::[ \t]*$/ ) { $depth--; push @sb, $x if $depth > 0 }
                else                          { push @sb, $x }
                $j++;
            }
            if ( $depth == 0 ) {
                # A child fence that is itself a component, or a reserved built-in
                # (include/oembed/form), belongs to content so the pipeline renders
                # it; any other name is a named slot.
                if ( _component_exists( $layout_dir, $fence )
                    || $fence =~ /\A(?:include|oembed|form)\z/ )
                {
                    push @content_lines, $l, @sb, ':::';
                }
                else {
                    $slots{$fence} =
                        _md_fragment( join( "\n", @sb ), $layout_dir, $md_path, $meta );
                }
                $i = $j;
                next;
            }
        }
        push @content_lines, $l;
        $i++;
    }

    my $content =
        _md_fragment( join( "\n", @content_lines ), $layout_dir, $md_path, $meta );

    my $tt = Template->new(
        ABSOLUTE  => 1,
        EVAL_PERL => 0,
        # Layout components win; built-in components (lazysite/templates) are the
        # fallback so ::: qr resolves on any layout.
        INCLUDE_PATH => [ grep { defined } ( $layout_dir, "$LAZYSITE_DIR/templates" ) ],
        FILTERS      => { markdown => \&_markdown_filter },
    );
    my $rendered = '';
    $tt->process( "components/$name.tt",
        { content => $content, attrs => \%attrs, slots => \%slots }, \$rendered )
        or do {
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'component render failed',
            component => $name, error => $tt->error() );
        return "<!-- component '$name' failed to render -->";
        };
    $rendered =~ s/\s+\z//;
    return $rendered;
}

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

        # Skip if source contains unresolved TT variables - leave for second pass
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

        # Realpath check - reject if outside the content root or inside the
        # lazysite/ management tree (always at the docroot root).
        my $real = realpath($resolved);
        if ( !_path_under( $real, $base )
            || _path_under( $real, "$DOCROOT/lazysite" ) )
        {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include path invalid", source => $source );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        if ( !-f $real ) {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include file not found", source => $source );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }

        $content = eval { read_file($real) };
        if ( $@ || !defined $content ) {
            log_event( "WARN", $ENV{REDIRECT_URL} // "-", "include failed", source => $source, error => $@ );
            return qq(<span class="include-error" data-src="$source_escaped"></span>\n);
        }
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

sub convert_md {
    my ($body) = @_;

    # Protect <script> AND <style> blocks from Markdown processing. CSS/JS is not
    # Markdown: emphasis would mangle it - e.g. the `*/ ... /*` between two CSS
    # comments pairs into <em>...</em>, swallowing the rules in between (the login
    # page's inline styles regressed exactly this way).
    my @rawblocks;
    $body =~ s{(<(script|style)\b[^>]*>)(.*?)(</\2>)}{
        my $placeholder = "RAWBLOCK_" . scalar(@rawblocks) . "_END";
        push @rawblocks, "$1$3$4";
        $placeholder
    }gsei;

    my $md = Text::MultiMarkdown->new(
        use_fenced_code_blocks => 1,
    );
    my $html = $md->markdown($body);

    # Restore the protected blocks
    for my $i ( 0 .. $#rawblocks ) {
        $html =~ s/(?:<p>)?RAWBLOCK_${i}_END(?:<\/p>)?/$rawblocks[$i]/;
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
    my $html = convert_md("$text");
    $html =~ s/\A\s+//;
    $html =~ s/\s+\z//;
    if ( $html =~ m{\A<p>(.*)</p>\z}s && index( $1, '<p>' ) < 0 ) {
        $html = $1;    # inline: drop the single enclosing paragraph
    }
    return $html;
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
    # Convert unprocessed Markdown links inside <p> tags after TT rendering.
    # Markdown links containing TT variables in the URL are parsed by
    # MultiMarkdown before TT runs, which strips the TT content from the URL.
    # After TT has resolved all variables, this pass converts any remaining
    # Markdown link syntax in paragraph content to HTML anchor tags.
    $html =~ s{\[([^\]]+)\]\(([^)]+)\)}{<a href="$2">$1</a>}g;
    return $html;
}

# --- oEmbed ---

# Known provider endpoints - matched by URL pattern
# Falls back to autodiscovery for unlisted providers
my %OEMBED_PROVIDERS = (
    qr{youtube\.com/watch|youtu\.be/} => 'https://www.youtube.com/oembed',
    qr{vimeo\.com/}                   => 'https://vimeo.com/api/oembed.json',
    qr{/videos/watch/|/videos/embed/} => undef,    # PeerTube - autodiscover
    qr{twitter\.com/|x\.com/}         => 'https://publish.twitter.com/oembed',
    qr{soundcloud\.com/}              => 'https://soundcloud.com/oembed',
);

sub convert_oembed {
    my ($text) = @_;

    $text =~ s{
        ^:::[ \t]+oembed[ \t]*\n          # opening ::: oembed
        [ \t]*(https?://[^\n]+?)[ \t]*\n  # URL
        ^:::[ \t]*\n                      # closing :::
    }{
        my $url  = $1;
        my $html = fetch_oembed($url);
        $html
            ? qq(<div class="oembed">\n$html\n</div>\n)
            : qq(<div class="oembed oembed--failed">\n)
              . qq(<p><a href="$url">$url</a></p>\n)
              . qq(</div>\n);
    }gsmxe;

    return $text;
}

sub fetch_oembed {
    my ($url) = @_;

    my $endpoint = find_oembed_endpoint($url);
    unless ($endpoint) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed no endpoint", url => $url );
        return;
    }

    my $oembed_url = $endpoint . '?url=' . uri_encode($url) . '&format=json';
    my $raw        = fetch_url($oembed_url);
    unless ($raw) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed fetch failed", url => $oembed_url );
        return;
    }

    # Parse JSON safely using JSON::PP (S3)
    # Note: JSON::PP gives correct string values but the html field content
    # itself is still trusted as-is. A compromised or malicious provider
    # could return arbitrary HTML. Restrict OEMBED_PROVIDERS to trusted
    # hosts if this is a concern in your deployment.
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data || !defined $data->{html} ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "oembed parse failed", url => $oembed_url, error => $@ );
        return;
    }

    return $data->{html};
}

sub find_oembed_endpoint {
    my ($url) = @_;

    # Check known providers first
    for my $pattern ( keys %OEMBED_PROVIDERS ) {
        if ( $url =~ $pattern ) {
            my $ep = $OEMBED_PROVIDERS{$pattern};
            return $ep if $ep;
            last;    # Pattern matched but no endpoint - fall through to autodiscovery
        }
    }

    # Autodiscovery - fetch the page and look for oEmbed link tag
    my $page = fetch_url($url);
    return unless $page;

    if ( $page =~ m{<link[^>]+type=["']application/json\+oembed["'][^>]+href=["']([^"']+)["']}ix
        || $page =~ m{<link[^>]+href=["']([^"']+)["'][^>]+type=["']application/json\+oembed["']}ix )
    {
        return $1;
    }

    return;
}

sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

sub strip_tt_directives {
    my ($val) = @_;
    # Strip [% and %] as separate sequences rather than matched pairs.
    # This handles nested attempts like [% [% ... %] %] more robustly
    # than a non-recursive paired match.
    $val =~ s/\[%//g;
    $val =~ s/%\]//g;
    return $val;
}

sub interpolate_env {
    my ($val) = @_;
    # Only interpolate allowlisted environment variables (S5)
    $val =~ s{\$\{(\w+)\}}{
        $ENV_ALLOWLIST{$1} ? ( defined $ENV{$1} ? $ENV{$1} : '' ) : "\${$1}"
    }ge;
    return $val;
}

# tt_page_var `json:` source - load a LOCAL JSON file (docroot-relative or a full
# docroot path) and expose the DECODED data structure (hash/array) to the page so
# the body can [% FOREACH row IN data.rows %]. Docroot-contained only; returns ''
# (a falsey scalar, so FOREACH/IF degrade quietly) on missing / invalid / out-of-
# tree, with a WARN. No remote fetch - use a local data file.
# SM179 P4: resolve a content path against the request's content root FIRST, then
# the docroot (shared files) - so a page's json:/include source is byte-identical
# across per-language roots instead of needing a docroot-absolute path into its own
# root. Every candidate stays under the docroot and outside the lazysite/
# management tree (no wider than the docroot-only resolution it replaces). Returns
# the realpath of the first existing candidate, or undef.
sub _resolve_content_path {
    my ($src) = @_;
    my $croot = $REQUEST_CROOT // $DOCROOT;
    my @cands;
    if ( index( $src, $DOCROOT ) == 0 ) {
        @cands = ($src);    # already a full docroot filesystem path
    }
    else {
        ( my $rel = $src ) =~ s{^/+}{};
        @cands = $croot ne $DOCROOT ? ( "$croot/$rel", "$DOCROOT/$rel" ) : ("$DOCROOT/$rel");
    }
    for my $c (@cands) {
        my $real = realpath($c);
        next
            unless $real
            && _path_under( $real,  $DOCROOT )
            && !_path_under( $real, "$DOCROOT/lazysite" )
            && -f $real;
        return $real;
    }
    return undef;
}

# SM179 P2: the language-set members for the current request - the ordered
# [% languages %] list. For every host that shares the current host's lang_group:
# { lang, url, current, exists } where url is the sibling's site_url + the same
# request path, current marks the active host, and exists stats the counterpart
# page in the sibling's content root. Empty unless the current host is in a
# language set (a lang_group with >= 2 members). A layout renders a switcher and
# hreflang from this; the engine supplies it so nobody hand-rolls either.
sub _language_set {
    my ( $cur_host, $cur_group, $req_path ) = @_;
    return () unless defined $cur_group && length $cur_group;
    my $text = eval { read_file($CONF_FILE) } // '';

    my ( %base, %alias );
    while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) { $base{$1} = $2 }
    while ( $text =~ /^alias\.(\S+)\.(\w+)\h*:\h*(.+)$/mg ) { $alias{ lc $1 }{$2} = $3 }

    my @members;
    push @members, { host => '', %base }
        if ( $base{lang_group} // '' ) eq $cur_group;
    for my $h ( sort keys %alias ) {
        push @members, { host => $h, %{ $alias{$h} } }
            if ( $alias{$h}{lang_group} // '' ) eq $cur_group;
    }
    return () unless @members >= 2;

    ( my $rel = ( $req_path // '/' ) ) =~ s/\?.*$//;    # drop any query string
    $rel                               =~ s{^/+}{};
    $rel                               =~ s{/+$}{};     # 'compare', or '' for home
    my @langs;
    for my $m (@members) {
        ( my $url = $m->{site_url} // '' ) =~ s{/+$}{};
        $url .= length $rel ? "/$rel" : '/';
        my $cr = length( $m->{content_root} // '' ) ? "$DOCROOT/$m->{content_root}" : $DOCROOT;
        my $stem   = length $rel                    ? "$cr/$rel" : "$cr/index";
        my $exists = ( -f "$stem.md" || -f "$stem.url" || -f "$stem.html" ) ? 1 : 0;
        push @langs,
            {
            lang    => ( $m->{lang} // '' ),
            url     => $url,
            current => ( $m->{host} eq $cur_host ? 1 : 0 ),
            exists  => $exists,
            };
    }
    return @langs;
}

sub resolve_json {
    my ($src) = @_;
    my $real = _resolve_content_path($src);
    if ( !defined $real ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-",
            "tt json source not found or outside docroot", src => $src );
        return '';
    }
    # Read RAW bytes, not via read_file() (which opens :utf8 and returns a decoded
    # wide-char string). decode_json expects UTF-8-encoded BYTES; handing it an
    # already-decoded string makes it choke on any non-ASCII (em dashes, curly
    # quotes, arrows) and return undef - i.e. the whole file silently resolves to
    # empty. Raw bytes -> decode_json decodes the UTF-8 itself, correctly.
    my $raw = eval {
        open my $fh, '<:raw', $real or die "open failed: $!";
        local $/;
        my $bytes = <$fh>;
        close $fh;
        $bytes;
    };
    return '' unless defined $raw;
    my $data = eval { decode_json($raw) };
    if ( $@ || !defined $data ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-",
            "tt json source parse failed", src => $src, error => "$@" );
        return '';
    }
    return $data;
}

sub resolve_tt_vars {
    my ($defs) = @_;
    my %vars;

    for my $key ( keys %$defs ) {
        my $val = strip_tt_directives( $defs->{$key} );

        if ( $val =~ s/^scan:// ) {
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_scan($val);
        }
        elsif ( $val =~ s/^json://i ) {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = resolve_json($val);
        }
        elsif ( $val =~ s/^url:// ) {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            my $fetched = fetch_url($val);
            if ( defined $fetched ) {
                $fetched =~ s/^\s+|\s+$//g;
                $vars{$key} = $fetched;
            }
            else {
                log_event( "WARN", $ENV{REDIRECT_URL} // "-", "tt var fetch failed", key => $key, val => $val );
                $vars{$key} = '';
            }
        }
        else {
            $val = interpolate_env($val);
            $val =~ s/^\s+|\s+$//g;
            $vars{$key} = $val;
        }
    }

    return %vars;
}

{
    # P-2: per-process memoization of resolve_site_vars(). This function is
    # called up to 6 times per request (main(), render_content,
    # update_registries, etc). Under CGI, one process = one request, so
    # the cache is request-scoped automatically.
    #
    # *** FastCGI / D016 note ***
    # Under a persistent-process model the cache MUST be reset at the start of
    # every request iteration; handle_one_request() calls reset_request_state()
    # for exactly that. Belt-and-suspenders, the cache is ALSO self-invalidating:
    # it is keyed on (conf mtime, request host), so a conf edit or a different
    # host on the next request re-resolves even if a runner never calls reset.
    # This makes the resolver correct under any process model, not just ones that
    # remember to reset - the durable fix for "conf change invisible to a
    # persistent worker".
    my %_site_vars_cache;
    my $_site_vars_loaded = 0;
    my $_site_vars_sig    = '';

    sub resolve_site_vars {
        return () unless -f $CONF_FILE;
        my $sig
            = ( ( stat $CONF_FILE )[9] // 0 ) . "\0" . ( _request_host() // '' );
        return %_site_vars_cache if $_site_vars_loaded && $sig eq $_site_vars_sig;
        $_site_vars_sig = $sig;

        my $text = read_file($CONF_FILE);
        my %defs;
        while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) {
            $defs{$1} = $2;
        }

        # SM110: domain aliases. When the request's (sanitised) Host header
        # matches a host declared in alias_hosts, overlay that host's
        # whitelisted alias.<host>.<key> overrides onto the base conf. The
        # primary host, any undeclared host, and any malformed Host header
        # all keep the base conf untouched - zero behaviour change when
        # alias_hosts is unset. Alias lines use dotted keys, which the \w+
        # base parse above cannot match, so they never leak into base vars.
        my $alias_host = q{};
        if ( defined $defs{alias_hosts} ) {
            my $req_host = _request_host();
            my %declared;
            for my $h ( split /,/, lc $defs{alias_hosts} ) {
                $h =~ s/^\s+|\s+$//g;
                $declared{$h} = 1 if length $h;
            }
            if ( length $req_host && $declared{$req_host} ) {
                $alias_host = $req_host;
                # Greedy (\S+) so a host whose label collides with a conf
                # key (alias.theme.example.com.theme) still splits at the
                # LAST dot; keys never contain dots.
                while ( $text =~ /^alias\.(\S+)\.(\w+)\h*:\h*(.+)$/mg ) {
                    my ( $host, $key, $val ) = ( lc $1, $2, $3 );
                    next unless $host eq $alias_host;
                    if ( $ALIAS_OVERRIDE_KEYS{$key} ) {
                        $defs{$key} = $val;
                    }
                    else {
                        log_event( 'WARN', $ENV{REDIRECT_URL} // '-',
                            'alias override ignored - key not whitelisted',
                            host => $host, key => $key );
                    }
                }
            }
        }

        my %vars = resolve_tt_vars( \%defs );

        # The active alias host as a TT var ('' on the primary), so layouts
        # can branch per host or mark canonical links. Set AFTER
        # resolve_tt_vars: authoritative, never conf-overridable.
        $vars{alias_host} = $alias_host;

        # SM155: the sanitised host actually being served - primary OR alias -
        # as a TT var, so a single content_root can render differently per
        # domain: [% IF domain == 'clienta.com' %]...[% END %]. Unlike
        # alias_host (empty on the primary), this is always the real host.
        # Authoritative (never conf-overridable) and DNS-alphabet-only, so it
        # can never carry markup; cached per host (each alias host has its own
        # cache slot), so a page served from cache keeps the correct value.
        $vars{domain} = _request_host();

        my $nav_file = $vars{nav_file}
            ? "$DOCROOT/" . $vars{nav_file}
            : "$LAZYSITE_DIR/nav.conf";
        $vars{nav} = parse_nav($nav_file);

        %_site_vars_cache  = %vars;
        $_site_vars_loaded = 1;
        return %_site_vars_cache;
    }

    # Reset all per-request caches. Call at the top of each request loop
    # iteration under FastCGI (D016). Harmless under CGI.
    sub reset_request_state {
        %_site_vars_cache  = ();
        $_site_vars_loaded = 0;
        $_site_vars_sig    = '';
        undef $REQUEST_CROOT;    # SM151: recomputed per request in main()
        _reset_peek_cache();
    }
}

# SM110: the request's Host header, sanitised for alias matching: lowercased,
# port stripped, trailing dot dropped, validated against the DNS hostname
# alphabet. Anything malformed returns '' and the request renders with the
# base conf, exactly like the primary host. Note HTTP_HOST stays EXCLUDED
# from ${VAR} conf interpolation (%ENV_ALLOWLIST) - here its sanitised value
# is only COMPARED against the operator-declared alias list, never emitted
# into output, so a hostile Host header can at worst select a rendering the
# operator explicitly configured.
# SM156: a stable, non-sensitive per-install identifier. One-way over the
# realpath of the docroot, so every host of the same install returns the same
# value and two installs on one server differ. Not derived from any secret, so
# publishing it via the instance marker leaks nothing usable. manager-api
# computes the identical value (same docroot) to compare a check result against.
sub _instance_id {
    my $base = realpath($DOCROOT) // $DOCROOT;
    return substr( hmac_sha256_hex( $base, 'lazysite-instance' ), 0, 32 );
}

sub _request_host {
    my $host = lc( $ENV{HTTP_HOST} // q{} );
    $host =~ s/:\d+\z//;    # strip port
    $host =~ s/\.\z//;      # trailing dot (FQDN form)
    return q{} if length $host > 253;
    return q{}
        unless $host =~ /\A [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )?
                         (?: \. [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )? )* \z/x;
    return $host;
}

sub parse_nav {
    my ($nav_path) = @_;
    return [] unless -f $nav_path;

    open( my $fh, '<:utf8', $nav_path ) or return [];

    my @nav;
    my $current_parent = undef;

    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /^\s*#/;    # comment
        next if $line =~ /^\s*$/;    # blank line

        my $is_child = $line =~ /^\s+/;
        $line =~ s/^\s+|\s+$//g;     # trim

        my ( $label, $url ) = split /\s*\|\s*/, $line, 2;
        $label = defined $label ? $label : '';
        $label =~ s/^\s+|\s+$//g;
        $url = defined $url ? $url : '';
        $url =~ s/^\s+|\s+$//g;

        next unless length $label;

        if ($is_child) {
            # Add to current parent's children
            if ( defined $current_parent ) {
                push @{ $nav[$current_parent]{children} },
                    { label => $label, url => $url };
            }
            # Orphan child (no parent yet) - treat as top-level
            else {
                push @nav, { label => $label, url => $url, children => [] };
            }
        }
        else {
            # Top-level item
            push @nav, { label => $label, url => $url, children => [] };
            $current_parent = $#nav;
        }
    }

    close $fh;
    return \@nav;
}

sub peek_search_default {
    return 1 unless -f $CONF_FILE;
    open( my $fh, '<:utf8', $CONF_FILE ) or return 1;
    while (<$fh>) {
        if (/^search_default\s*:\s*(\S+)/) {
            close $fh;
            return $1 =~ /^false$/i ? 0 : 1;
        }
    }
    close $fh;
    return 1;
}

# Normalise a passed-through front-matter scalar for scan results: trim, strip a
# single layer of matching surrounding quotes (so accent: "#7C5CFF" yields #7C5CFF
# rather than the literal quotes), and strip TT markers as defence in depth.
sub _scan_scalar {
    my ($v) = @_;
    return $v if ref $v;
    $v //= '';
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/^(['"])(.*)\1$/$2/;
    $v =~ s/\[%|%\]//g;
    return $v;
}

sub resolve_scan {
    my ($pattern) = @_;

    # Parse filter modifiers: "filter=FIELD:VALUE" (may repeat)
    my @filters;
    while ( $pattern =~ s/\s+filter=(\w+):([^\s]+)// ) {
        push @filters, { field => $1, value => $2 };
    }

    # Parse sort modifier: "sort=FIELD DIRECTION"
    my $sort_field = 'filename';
    my $sort_dir   = 'asc';
    if ( $pattern =~ s/\s+sort=(\w+)(?:\s+(asc|desc))?//i ) {
        $sort_field = lc($1);
        $sort_dir   = lc($2) if defined $2;
        # date/title/filename are the built-ins; any other identifier sorts on the
        # matching (passed-through) custom front-matter key, e.g. sort=order.
        $sort_field = 'filename' unless $sort_field =~ /^\w+$/;
    }

    # Pattern must be root-relative starting with /
    return [] unless $pattern =~ m{^/};

    # SM151: box the scan to the requesting domain's content root (the domain's
    # '/'), so search on one domain never returns another's pages. Falls back to
    # the docroot for the primary host / when no content_root is in effect.
    my $scan_root = $REQUEST_CROOT // $DOCROOT;
    my $excl      = _declared_content_roots();    # §7: other domains' roots

    # Build filesystem glob pattern
    my $fs_pattern = $scan_root . $pattern;

    # Limit to .md files only
    return [] unless $fs_pattern =~ /\.md$/;

    my @files;
    if ( $fs_pattern =~ m{\*\*} ) {
        # Recursive glob: expand ** by walking directories
        # Split pattern into base dir and file glob parts
        my ( $base, $rest ) = $fs_pattern =~ m{^(.*?)/\*\*/(.*)$};
        if ( defined $base && defined $rest && -d $base ) {
            my $file_re = $rest;
            $file_re =~ s/\./\\./g;
            $file_re =~ s/\*/.*/g;
            $file_re = qr/\A${file_re}\z/;
            my @queue = ($base);
            while ( my $dir = shift @queue ) {
                opendir( my $dh, $dir ) or next;
                for my $entry ( readdir($dh) ) {
                    next if $entry =~ /^\./;
                    my $path = "$dir/$entry";
                    if ( -d $path ) {
                        # SM151: don't follow symlinked dirs - a symlink could
                        # cycle (hanging the walk) or escape the content root
                        # (leaking a sibling domain's pages into search).
                        next if -l $path;
                        # §7: never descend into ANOTHER domain's content root,
                        # so a bare-docroot search excludes client subtrees.
                        next if $excl->{$path} && $path ne $base;
                        push @queue, $path;
                    }
                    elsif ( $entry =~ $file_re ) {
                        push @files, $path;
                    }
                }
                closedir($dh);
            }
        }
    }
    else {
        @files = glob($fs_pattern);
    }

    # Limit to 200 files
    @files = @files[ 0 .. 199 ] if @files > 200;

    # Read site search default once if any filter references searchable
    my $search_default;

    my @pages;
    for my $path ( sort @files ) {
        # Realpath check - confined to the scan root (the domain's content root,
        # or the docroot), so a symlinked file cannot escape the domain (SM151).
        my $real = realpath($path);
        next unless _path_under( $real, $scan_root );
        next unless -f $real;

        # Read front matter
        my $raw = read_file($path);
        my ( $meta, undef ) = parse_yaml_front_matter($raw);

        # Derive URL relative to the scan root, so a boxed domain's results
        # carry that domain's own '/'-relative paths (SM151).
        ( my $url = $path ) =~ s{^\Q$scan_root\E}{};
        $url                =~ s/\.md$//;
        $url                =~ s{/index$}{/};

        # Date from front matter or mtime
        my $date = $meta->{date} || '';
        unless ($date) {
            my @st = stat($path);
            if (@st) {
                my @t = localtime( $st[9] );
                $date = sprintf( "%04d-%02d-%02d",
                    $t[5] + 1900, $t[4] + 1, $t[3] );
            }
        }

        # Parse tags from front matter (YAML list, comma-separated, or single value)
        my $tags_raw = $meta->{tags} // '';
        my @tags;
        if ( ref $tags_raw eq 'ARRAY' ) {
            @tags = @$tags_raw;
        }
        elsif ($tags_raw) {
            @tags = map { s/^\s+|\s+$//gr } split /,/, $tags_raw;
        }

        # Extract raw body for search excerpt
        my $excerpt = '';
        if ( $raw =~ /^---\n.*?\n---\n(.+)/s ) {
            $excerpt = $1;
            # Drop <style>/<script> blocks and HTML comments so their CSS/JS/markup
            # never leaks into the public search excerpt (a page often opens with an
            # inline <style> block).
            $excerpt =~ s{<style\b[^>]*>.*?</style>}{ }gis;
            $excerpt =~ s{<script\b[^>]*>.*?</script>}{ }gis;
            $excerpt =~ s{<!--.*?-->}{ }gs;
            $excerpt =~ s/^\s+|\s+$//g;
            $excerpt = substr( $excerpt, 0, 500 ) if length($excerpt) > 500;
        }

        # Determine searchable status
        my $search_val = $meta->{search} // '';
        my $searchable;
        if ( $search_val =~ /^true$/i ) {
            $searchable = 1;
        }
        elsif ( $search_val =~ /^false$/i ) {
            $searchable = 0;
        }
        else {
            $search_default //= peek_search_default();
            $searchable = $search_default;
        }

        # Pass through custom (non-computed, non-control) front-matter keys so a
        # scanned/registry card is self-describing - [% p.accent %], [% p.kind %],
        # [% p.demo %], [% p.order %] - instead of smuggling data through tags.
        # Computed fields below take precedence; control/internal keys are excluded;
        # surrounding quotes and TT markers are stripped from scalar values.
        my %reserved = map { $_ => 1 } qw(
            url title subtitle date tags excerpt searchable path
            layout theme auth register search );
        my %custom;
        for my $k ( keys %$meta ) {
            next if $reserved{$k} || $k =~ /^(?:tt_|_)/;
            my $v = $meta->{$k};
            if    ( ref $v eq 'ARRAY' ) { $custom{$k} = [ map { _scan_scalar($_) } @$v ] }
            elsif ( !ref $v )           { $custom{$k} = _scan_scalar($v) }
        }

        push @pages, {
            %custom,
            url        => $url,
            title      => $meta->{title}    || '',
            subtitle   => $meta->{subtitle} || '',
            date       => $date,
            tags       => \@tags,
            excerpt    => $excerpt,
            searchable => $searchable,
            # Docroot-relative, never the absolute server path: this object is
            # published in the public /search-index JSON and exposed to templates
            # as [% p.path %]. Leaking /home/<user>/web/... was an info disclosure.
            path => ( $path =~ s{^\Q$DOCROOT\E}{}r ),
        };
    }

    # Apply filters
    for my $filter (@filters) {
        my $field = $filter->{field};
        my $val   = $filter->{value};

        @pages = grep {
            my $page = $_;
            my $pval = $page->{$field};

            if ( !defined $pval ) {
                0;    # field not present - exclude
            }
            elsif ( $val =~ /^>(.+)$/ ) {
                # Greater than
                ( $pval cmp $1 ) > 0;
            }
            elsif ( $val =~ /^<(.+)$/ ) {
                # Less than
                ( $pval cmp $1 ) < 0;
            }
            elsif ( ref $pval eq 'ARRAY' ) {
                # Array contains (for tags)
                grep { lc($_) eq lc($val) } @$pval;
            }
            elsif ( $val =~ /^(true|1)$/i ) {
                # Boolean true
                $pval ? 1 : 0;
            }
            elsif ( $val =~ /^(false|0)$/i ) {
                # Boolean false
                $pval ? 0 : 1;
            }
            else {
                # Exact match (case-insensitive)
                lc($pval) eq lc($val);
            }
        } @pages;
    }

    # Sort pages. date/title/filename are built-ins; any other field sorts on the
    # custom key (numeric-aware, so sort=order gives 2 before 10).
    my @sorted = sort {
        my ( $va, $vb );
        if ( $sort_field eq 'date' ) { ( $va, $vb ) = ( $a->{date}, $b->{date} ) }
        elsif ( $sort_field eq 'title' ) { ( $va, $vb ) = ( lc( $a->{title} ), lc( $b->{title} ) ) }
        elsif ( $sort_field eq 'filename' ) { ( $va, $vb ) = ( $a->{path}, $b->{path} ) }
        else {
            $va = ( defined $a->{$sort_field} && !ref $a->{$sort_field} ) ? $a->{$sort_field} : '';
            $vb = ( defined $b->{$sort_field} && !ref $b->{$sort_field} ) ? $b->{$sort_field} : '';
        }
        my $cmp = ( $va =~ /^-?\d+(?:\.\d+)?$/ && $vb =~ /^-?\d+(?:\.\d+)?$/ )
            ? ( $va <=> $vb ) : ( lc($va) cmp lc($vb) );
        $sort_dir eq 'desc' ? -$cmp : $cmp;
    } @pages;

    return \@sorted;
}

{
    # P-3: cache "do we have any registry templates?" at process level.
    # Most sites don't use registries; this avoids an opendir on every
    # cache-miss render.
    my $_has_registries;    # undef = not yet probed

    sub update_registries {
        # SM110/SM151: registries (sitemap, feeds, llms.txt) are generated per
        # content root. A host with its OWN content_root gets first-class
        # registries - scanned from and written INTO its subtree, with its own
        # per-host site_url - so each domain has a correct sitemap/feeds of just
        # its own pages. A host that is an alias WITHOUT a content root shares
        # the docroot (SM110 chrome-only alias); it is still skipped, or its
        # overlaid vars (site_name etc.) would bake into the docroot-shared
        # registries the primary serves. The primary host - with or without a
        # base content_root - generates as before.
        my %sv       = resolve_site_vars();
        my $root     = $DOCROOT;
        my $has_root = 0;
        if ( defined $sv{content_root} && length $sv{content_root} ) {
            my $c = confine_content_root( $DOCROOT, $sv{content_root} );
            if ( defined $c ) { $root = $c; $has_root = 1; }
        }
        return if $sv{alias_host} && !$has_root;

        if ( !defined $_has_registries ) {
            if ( -d $REGISTRY_DIR ) {
                opendir( my $dh, $REGISTRY_DIR );
                my @t = $dh ? grep { /\.tt$/ } readdir($dh) : ();
                closedir($dh) if $dh;
                $_has_registries = @t ? 1 : 0;
            }
            else {
                $_has_registries = 0;
            }
        }
        return unless $_has_registries;

        opendir( my $dh, $REGISTRY_DIR ) or return;
        my @templates = grep { /\.tt$/ } readdir($dh);
        closedir($dh);

        return unless @templates;

        # Check if any registry needs updating
        my $needs_update = 0;
        for my $tmpl (@templates) {
            ( my $output_name = $tmpl ) =~ s/\.tt$//;
            my $output_path = "$root/$output_name";
            if ( !-f $output_path
                || ( time() - ( stat($output_path) )[9] ) >= $REGISTRY_TTL )
            {
                $needs_update = 1;
                last;
            }
        }
        return unless $needs_update;

        # Scan the source pages of THIS content root only (SM151), so a domain's
        # registries list just its own subtree with content-root-relative URLs.
        my @pages     = scan_pages($root);
        my %site_vars = resolve_site_vars();

        # Compile-cache dirs + .ttc files are minted during new()/process():
        # group-writable creation whichever identity renders first (_cache_umask).
        my $old_umask = _cache_umask();
        make_path($TT_COMPILE_DIR) unless -d $TT_COMPILE_DIR;
        my $tt = Template->new(
            ABSOLUTE    => 1,
            ENCODING    => 'utf8',
            EVAL_PERL   => 0,                  # L-2
            COMPILE_DIR => $TT_COMPILE_DIR,    # P-4
            COMPILE_EXT => '.ttc',             # P-4
        ) or do { umask $old_umask; return };

        for my $tmpl (@templates) {
            ( my $output_name = $tmpl ) =~ s/\.tt$//;
            my $output_path = "$root/$output_name";
            my $tmpl_path   = "$REGISTRY_DIR/$tmpl";

            # Check this specific registry needs updating
            next if -f $output_path
                && ( time() - ( stat($output_path) )[9] ) < $REGISTRY_TTL;

            # Filter pages registered for this registry
            my $registry_name = $output_name;
            my @registered    = grep {
                my $page = $_;
                grep { $_ eq $registry_name } @{ $page->{register} || [] }
            } @pages;

            # SM179 P3: for a language set, attach each page's hreflang alternates
            # so the sitemap can advertise its siblings (xhtml:link). Copy each
            # page hash before augmenting - @pages is shared across registries and
            # only the sitemap consumes `alternates`. A member whose counterpart is
            # absent carries exists=0 and the template omits it.
            if ( $registry_name eq 'sitemap.xml'
                && length( $site_vars{lang_group} // '' ) )
            {
                @registered = map {
                    +{
                        %$_,
                        alternates => [
                            _language_set(
                                ( $site_vars{alias_host} // '' ),
                                $site_vars{lang_group}, $_->{url}
                            )
                        ],
                    }
                } @registered;
            }

            my $vars = {
                %site_vars,
                pages => \@registered,
            };

            my $output = '';
            $tt->process( $tmpl_path, $vars, \$output ) or do {
                log_event( "ERROR", "-", "registry template error", tmpl => $tmpl, error => $tt->error() );
                next;
            };

            open( my $fh, '>:utf8', $output_path ) or do {
                log_event( "WARN", "-", "cannot write registry", path => $output_path, error => $! );
                next;
            };
            print $fh $output;
            close $fh;
        }
        umask $old_umask;
    }
}    # close P-3 _has_registries memo block

sub scan_pages {
    # SM151: scan a specific content root (default: the docroot). URLs are
    # derived relative to $root so a per-domain registry carries the domain's
    # own '/'-relative links.
    my ($root) = @_;
    $root //= $DOCROOT;
    my $excl = _declared_content_roots();    # §7: other domains' roots

    my @pages;

    # Find all .md and .url files recursively under the root
    my @queue = ($root);
    while ( my $dir = shift @queue ) {
        opendir( my $dh, $dir ) or next;
        for my $entry ( sort readdir($dh) ) {
            next if $entry =~ /^\./;
            next if $entry =~ /\.brief$/;    # SM073: briefs never index
            my $path = "$dir/$entry";
            # Never index the lazysite/ management tree (auth, templates,
            # cache); relevant when $root is the bare docroot.
            next if $path eq $LAZYSITE_DIR;
            if ( -d $path ) {
                # SM151: do not follow symlinked directories - a symlink can
                # form a cycle (which would hang the walk) or escape the
                # content root (which would leak a sibling domain's pages into
                # this domain's registries). Page serving is realpath-confined
                # (P1); the scanner simply refuses to traverse symlinked dirs.
                next if -l $path;
                # §7: never descend into ANOTHER domain's content root - a
                # bare-docroot host's sitemap must not enumerate client subtrees.
                next if $excl->{$path} && $path ne $root;
                push @queue, $path;
            }
            elsif ( $entry =~ /\.(md|url)$/ ) {
                my $raw;
                if ( $entry =~ /\.md$/ ) {
                    $raw = read_file($path);
                }
                else {
                    # For .url files read the cached .html front matter isn't
                    # available - read from remote is too expensive, skip register
                    # unless a local .md sidecar exists
                    next;
                }

                my ( $meta, undef ) = parse_yaml_front_matter($raw);
                next unless $meta->{register};

                # Get date from front matter or file mtime
                my $date = $meta->{date} || '';
                unless ($date) {
                    my @st = stat($path);
                    if (@st) {
                        my @t = localtime( $st[9] );
                        $date = sprintf( "%04d-%02d-%02d",
                            $t[5] + 1900, $t[4] + 1, $t[3] );
                    }
                }

                # Derive URL from path, relative to the scanned root (SM151)
                ( my $url = $path ) =~ s{^\Q$root\E}{};
                $url                =~ s/\.md$//;
                $url                =~ s{/index$}{/};

                push @pages, {
                    url      => $url,
                    title    => $meta->{title}    || '',
                    subtitle => $meta->{subtitle} || '',
                    date     => $date,
                    register => $meta->{register} || [],
                };
            }
        }
        closedir($dh);
    }

    return @pages;
}

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

sub render_content {
    my ( $meta, $html_body, $query ) = @_;
    $query //= {};

    # Content pass uses ABSOLUTE => 0 - the content body is a string reference
    # and should never need file access. ABSOLUTE => 1 would allow TT to follow
    # absolute paths found in the content, which causes parse errors on CSS etc.
    # (content is processed as a string ref, which TT never writes to the
    # compile cache - so an unwritable cache/tt cannot fail this instance;
    # only the make_path needs guarding.)
    # TT 3.x pre-creates compile-dir mirrors in new() - group-writable
    # creation whichever identity renders first (_cache_umask).
    my $old_umask = _cache_umask();
    eval { make_path($TT_COMPILE_DIR) } unless -d $TT_COMPILE_DIR;
    my $tt = Template->new(
        ABSOLUTE    => 0,
        ENCODING    => 'utf8',
        EVAL_PERL   => 0,                  # L-2
        COMPILE_DIR => $TT_COMPILE_DIR,    # P-4
        COMPILE_EXT => '.ttc',             # P-4
    ) or do { umask $old_umask; die "Template error: " . Template->error() . "\n" };
    umask $old_umask;

    my %site_vars = resolve_site_vars();
    my %page_vars = resolve_tt_vars( $meta->{tt_page_var} || {} );

    my $groups_ref = $AUTH_CONTEXT{auth_groups};
    my $groups_str = ref $groups_ref eq 'ARRAY' ? join( ',', @$groups_ref ) : ( $groups_ref // '' );
    my $editor_flag = _is_manager( \%site_vars, $AUTH_CONTEXT{auth_user} // '', $groups_str ) ? 1 : 0;

    # SM154 (P3): expose what the domain-aware manager UI needs - whether the
    # user may manage domains (gates the Domains nav entry), and a bound editor's
    # own content_root + home_domain (so the file browser roots there instead of
    # the docroot the confinement would deny). Only computed when authenticated.
    my $mgr_user = $AUTH_CONTEXT{auth_user} // '';
    my %manager_caps;
    my ( $scope_root, $home_domain ) = ( '', '' );
    my @my_scopes;
    if ( length $mgr_user ) {
        # An operator (unsecured/dev fallback: no group grants manager) implicitly
        # holds every cap; otherwise resolve the nav-gating caps from the groups.
        # SM160: the Domains page is gated by manage_domains (carved out of
        # manage_config); both are surfaced so the manager UI can gate each area.
        my $all = !_site_grants_manager();
        # manage_users is surfaced too so the nav can offer a "grant this to
        # enable" hint (SM186) for capability-gated areas, but only to a user who
        # can actually grant it. SM191 generalises that hint, so the content-area
        # caps (content/nav/themes/layouts) and audit are surfaced as well.
        for my $cap (
            qw(manage_config manage_domains manage_users
            manage_content manage_nav manage_themes manage_layouts audit)
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

    # SM179 (P1): language awareness. site_lang is the host's language (conf
    # `lang:` or the alias override); page_lang lets a page override it via front
    # matter; both default to 'en'. $RESPONSE_LANG feeds the Content-Language header.
    # SEC: page_lang is CONTENT-PARTNER controllable (a page's front-matter `lang:`),
    # and lands in <html lang="..."> and the Content-Language header. TT does not
    # auto-escape and this var is outside the SEC-2026-07 stash-escape block, so
    # sanitise to a bare BCP-47-ish tag (letters + hyphen) - no quotes, angle
    # brackets or CR/LF - closing a stored-XSS / header-injection path where a
    # content-only write could otherwise execute script in every visitor's browser.
    my $site_lang = $site_vars{lang} || 'en';
    my $page_lang = $meta->{lang}    || $site_lang;
    s/[^A-Za-z-]//g for $site_lang, $page_lang;
    $site_lang ||= 'en';
    $page_lang ||= 'en';
    $RESPONSE_LANG = $page_lang;
    # SM179 P2: the language-set switcher data ({ lang, url, current, exists }),
    # empty unless this host is in a lang_group with siblings. Layouts render a
    # switcher and hreflang from it.
    my @languages = _language_set(
        ( $site_vars{alias_host} // '' ),
        ( $site_vars{lang_group} // '' ),
        ( $ENV{REDIRECT_URL}     // $ENV{REQUEST_URI} // '/' ),
    );

    my $vars = {
        %site_vars,
        %page_vars,
        %AUTH_CONTEXT,
        %PAYMENT_CONTEXT,
        %PREVIEW_CONTEXT,    # SM071: preview override wins over site layout/theme
            # SEC-2026-07 (H5): escape the author-controllable front-matter fields
            # HERE, at the single point they enter the stash, so EVERY layout - the
            # bundled fallback/manager layouts AND every third-party/library layout
            # we cannot edit - emits them safely even when it interpolates them
            # without a `| html` filter. $meta->{...} stays raw for the search index
            # and page scan, which never render it as HTML.
        page_title        => _esc_html( $meta->{title} ),
        page_subtitle     => _esc_html( $meta->{subtitle} ),
        page_author       => _esc_html( $meta->{author} ),
        page_modified     => $meta->{page_modified}     || '',
        page_modified_iso => $meta->{page_modified_iso} || '',
        request_uri       => $ENV{REDIRECT_URL}         || $ENV{REQUEST_URI} || '',
        # The visitor's IP: the first hop of X-Forwarded-For (the original client
        # behind a reverse proxy) if present, else the direct peer REMOTE_ADDR.
        # Per-request, so only correct on a `nocache: true` page - a cached page
        # would bake the first visitor's IP. Sanitised to IP characters only so a
        # spoofed header cannot inject markup into the rendered output.
        client_ip => do {
            my ($first) = split /\s*,\s*/, ( $ENV{HTTP_X_FORWARDED_FOR} // '' );
            my $ip = ( defined $first && length $first ) ? $first : ( $ENV{REMOTE_ADDR} // '' );
            $ip =~ s/[^0-9A-Fa-f:.\[\]]//g;
            $ip;
        },
        page_source => do {
            my $src = $meta->{_md_path} // '';
            $src =~ s{^\Q$DOCROOT\E}{};
            $src || '';
        },
        query            => $query,
        params           => $query,
        lazysite_version => _lazysite_version(),       # asset cache-buster (?v=)
        enabled_plugins  => _enabled_plugins(),        # conditional manager nav
        manager_caps     => \%manager_caps,            # SM154: gate the Domains nav
        scope_root       => $scope_root,               # SM154: a bound editor's root
        home_domain      => $home_domain,              # SM154: a bound editor's domain
        dav_scopes       => join( ',', @my_scopes ),   # SM157: multi-domain switcher list
        site_lang        => $site_lang,                # SM179: the host's language
        page_lang        => $page_lang,                # SM179: per-page override
        languages        => \@languages,               # SM179 P2: switcher/hreflang
        t                => {},                        # SM179 P5: layout chrome strings
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

    # Protect <pre><code> blocks and inline <code> elements from TT processing
    my $protected_body = $html_body;
    my @code_blocks;
    $protected_body =~ s{(<pre><code[^>]*>)(.*?)(</code></pre>)}{
        my $placeholder = "CODEBLOCK_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;
    $protected_body =~ s{(<code>)(.*?)(</code>)}{
        my $placeholder = "CODEBLOCK_" . scalar(@code_blocks) . "_END";
        push @code_blocks, "$1$2$3";
        $placeholder
    }gse;

    my $processed_body = '';
    $tt->process( \$protected_body, $vars, \$processed_body )
        or do {
        log_event( "ERROR", $ENV{REDIRECT_URL} // "-", "template error, using raw content", error => $tt->error() );
        $processed_body = $protected_body;
        };

    # Restore protected code blocks
    for my $i ( 0 .. $#code_blocks ) {
        $processed_body =~ s/CODEBLOCK_${i}_END/$code_blocks[$i]/;
    }

    return ( $processed_body, $vars );
}

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

sub render_template {
    my ( $meta, $html_body, $query ) = @_;
    $query //= {};

    my ( $processed_body, $vars ) = render_content( $meta, $html_body, $query );

    # Second include pass - resolves :::include blocks with TT-variable paths
    if ( $meta->{_md_path} ) {
        $processed_body = convert_fenced_include( $processed_body, $meta->{_md_path}, $meta );
    }

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
        # SM120: a page may pin a theme via front matter (theme:), preview-only and
        # sanitised the same way as layout:; falls back to the active/site theme.
        # resolve_theme still gates on layout compatibility, so an incompatible pin
        # renders as no theme rather than breaking.
        my $page_theme = ( defined $meta->{theme} && $meta->{theme} =~ /^[A-Za-z0-9_-]+$/ )
            ? $meta->{theme} : $vars->{theme};
        my $info = resolve_theme( $layout_key, $page_theme );
        if ( $info->{is_active} ) {
            $vars->{theme_name}   = $info->{theme_name};
            $vars->{theme}        = $info->{theme_data};
            $vars->{theme_assets} = "/lazysite-assets/$layout_key/" . $info->{theme_name};
            $vars->{theme_css}    = generate_theme_css( $info->{theme_data} );
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

    $vars->{content} = $processed_body;
    my $output = '';

    if ( !defined $layout ) {
        # No layout found - use built-in fallback directly
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "layout not found, using fallback" );
        my $tt_fallback = Template->new( ENCODING => 'utf8', EVAL_PERL => 0 )
            or do {
            log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance' );
            return $processed_body;
            };

        $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
            or do {
            log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error() );
            return $processed_body;
            };

        # Head injection must be layout-independent (SM112 generator meta,
        # SM151 per-host canonical): the real-layout path does it at output
        # time below, so the no-layout fallback path must too, or a fallback
        # site would silently lose its generator meta and its canonical link.
        $output = _inject_meta( $output, $vars );
        $output = _inject_canonical( $output, $vars );

        # Admin bar injected per-request at output time, not cached (see note below).
        return $output;
    }

    # Determine if layout is remote (from cache dir) - sandbox it
    my $is_remote = $is_remote_layout;

    # D035 content components: resolve [% INCLUDE 'components/NAME.tt' %] against
    # the active layout's own directory, and expose a `markdown` filter so a
    # component can render Markdown fields. Content authors never write TT;
    # components ship inside the trusted layout package and EVAL_PERL stays off.
    my $component_dir = ( defined $layout && length $layout && -e $layout )
        ? dirname($layout) : undef;

    my %tt_opts = (
        ABSOLUTE     => 1,                                 # needed to read cache path
        ENCODING     => 'utf8',
        EVAL_PERL    => 0,                                 # L-2: no embedded Perl
        INCLUDE_PATH => $component_dir,                    # D035: layout-local components
        FILTERS      => { markdown => \&_markdown_filter },
        COMPILE_DIR  => $TT_COMPILE_DIR,                   # P-4
        COMPILE_EXT  => '.ttc',                            # P-4
    );
    $tt_opts{RELATIVE} = 0 if $is_remote;                  # sandbox remote layouts

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
        my $tt_fallback = Template->new( ENCODING => 'utf8', EVAL_PERL => 0 )
            or do {
            log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'cannot create fallback TT instance' );
            return $processed_body;
            };

        $tt_fallback->process( \$FALLBACK_LAYOUT, $vars, \$output )
            or do {
            log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'fallback layout error', error => $tt_fallback->error() );
            return $processed_body;
            };

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
    my $script = '<script>(function(){var on=/(?:^|;\s*)lzs_session=1(?:;|$)/.test('
        . 'document.cookie),o=document.querySelectorAll("[data-ls-auth-out]"),'
        . 'i=document.querySelectorAll("[data-ls-auth-in]"),k;'
        . 'for(k=0;k<o.length;k++)o[k].style.display=on?"":"none";'
        . 'for(k=0;k<i.length;k++)i[k].style.display=on?"none":"";})();</script>';
    # Inject before the LAST </body>, not the first: a page can legitimately
    # carry a literal "</body>" inside a JS string (e.g. the editor builds an
    # iframe srcdoc: frame.srcdoc = '...</body></html>'). Splicing a
    # <script>...</script> in there closes the page's own inline <script> early
    # - "SyntaxError: literal not terminated" - and kills the whole script. The
    # negative lookahead anchors the match to the document's real closing tag.
    $html =~ s{</body>(?![\s\S]*</body>)}{$script</body>}i;
    return $html;
}

# SM112: read the installed release version once (from the install state).
my $LAZYSITE_VERSION;
# Enabled plugins from lazysite.conf's `plugins:` list, for conditional manager
# nav (e.g. hide "Visitor statistics" when the stats plugin is disabled). Keyed
# by both the raw entry (stats.pl) and its extensionless id (stats) so the layout
# can write `enabled_plugins.stats`.
sub _enabled_plugins {
    my %en;
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    open my $fh, '<:utf8', $conf or return \%en;
    my $in = 0;
    while (<$fh>) {
        chomp;
        if (/^plugins\s*:\s*$/) { $in = 1; next }
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

sub _lazysite_version {
    return $LAZYSITE_VERSION if defined $LAZYSITE_VERSION;
    $LAZYSITE_VERSION = '';
    my $path = "$DOCROOT/lazysite/.install-state.json";
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
    if ( length( $vars->{page_subtitle} // '' ) && $html !~ /<meta\s+name=["']description["']/i ) {
        push @m, '<meta name="description" content="' . ( $vars->{page_subtitle} // '' ) . '">';
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
            $manager_tools .= '<span style="margin-left:auto;">' . $user . '</span>';
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
    $bar .= '<script>if(window!==window.top){var ab=document.getElementById("ls-admin-bar");'
        . 'if(ab)ab.style.display="none";}</script>';

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
sub _inject_admin_bar_live {
    my ( $html, $md_path ) = @_;
    return $html unless defined $html && $html =~ /<body/i;
    my %sv = resolve_site_vars();
    return $html unless ( $sv{manager} // '' ) eq 'enabled';

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

# --- Content type cache ---

sub ct_cache_path {
    my ($base) = @_;
    my $key = $base;
    $key =~ s{/}{:}g;
    return "$CT_CACHE_DIR/$key.ct";
}

sub write_ct {
    my ( $base, $content_type ) = @_;

    # Default or undef content type - clean stale .ct if present
    if ( !defined $content_type || $content_type eq 'text/html; charset=utf-8' ) {
        my $ct_path = ct_cache_path($base);
        unlink $ct_path if -f $ct_path;
        return;
    }

    make_path($CT_CACHE_DIR) unless -d $CT_CACHE_DIR;

    my $ct_path = ct_cache_path($base);
    open( my $fh, '>:utf8', $ct_path ) or do {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "cannot write content type cache", path => $ct_path, error => $! );
        return;
    };
    print $fh $content_type;
    close $fh;
}

sub read_ct {
    my ($base) = @_;
    my $ct_path = ct_cache_path($base);
    return unless -f $ct_path;
    open( my $fh, '<:utf8', $ct_path ) or return;
    my $ct = <$fh>;
    close $fh;
    $ct =~ s/^\s+|\s+$//g if defined $ct;
    return $ct || undef;
}

sub write_html {
    my ( $html_path, $page ) = @_;

    # Skip cache write if LAZYSITE_NOCACHE is set
    return if $ENV{LAZYSITE_NOCACHE};

    # Refuse to write zero-byte content - protects against empty cache
    # files that would permanently block regeneration via DirectoryIndex
    unless ( length($page) ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "refusing zero-byte cache write", path => $html_path );
        return;
    }

    # Verify html_path resolves within docroot - guard against symlink attacks (S1)
    # Use the parent directory for the check since the file may not exist yet.
    # Note: narrow TOCTOU gap exists between this check and the subsequent open() -
    # a symlink created after the check would not be caught. O_NOFOLLOW via sysopen
    # would close this gap but adds complexity not warranted in this deployment context.
    my $check_path = -e $html_path ? $html_path : dirname($html_path);
    # SM110: an alias host's first write targets a slot directory that does
    # not exist yet (lazysite/cache/hosts/<host>/...) - walk up to the
    # nearest EXISTING ancestor for the containment check. The missing
    # segments are created below by make_path as real directories, so the
    # symlink guard's strength is unchanged.
    $check_path = dirname($check_path)
        while !-e $check_path && length($check_path) > 1;
    my $real = realpath($check_path);
    if ( !_path_under( $real, $DOCROOT ) ) {
        log_event( "WARN", $ENV{REDIRECT_URL} // "-", "cache path outside docroot", path => $html_path );
        return;
    }

    my $dir = dirname($html_path);
    unless ( -d $dir ) {
        make_path($dir);
        # Set group to match docroot and apply setgid bit so new files
        # and subdirectories inherit the group automatically.
        my $gid = ( stat($DOCROOT) )[5];
        chown -1, $gid, $dir;
        chmod 0o775 | 0o2000, $dir;    # L-8: explicit octal; 0o2000 = setgid
    }

    # P-5: atomic write via tempfile + rename so readers never see a torn
    # file. $html_path.tmp.$$ is pid-scoped to avoid concurrent writers
    # collapsing on the same temp name.
    #
    # Mixed identities: refreshes go through rename (a DIRECTORY write, so a
    # 0644 file from the other identity never blocks them - no stale-cache
    # risk), but keep the files group-writable anyway (_cache_umask) so both
    # the site user's tooling and the www-data CGI can manage each other's
    # cache entries in place on a group-shared docroot.
    my $old_umask = _cache_umask();
    my $tmp       = "$html_path.tmp.$$";
    open( my $fh, '>:utf8', $tmp ) or do {
        umask $old_umask;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot write cache tempfile', path => $tmp, error => $! );
        return;
    };
    # SM020 checked-write pattern (review D5): a failed print surfaces as a
    # failed close (buffer flush). Without this check, a disk-full mid-write
    # renamed a TRUNCATED tempfile into place and the torn page was then
    # served from cache. Fail closed: drop the tempfile, keep the old cache.
    my $wrote = print {$fh} $page;
    umask $old_umask;    # tempfile minted; restore before the exit paths
    unless ( close($fh) && $wrote ) {
        my $err = $!;
        unlink $tmp;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cache write failed, tempfile dropped', path => $tmp, error => $err );
        return;
    }
    unless ( rename $tmp, $html_path ) {
        my $err = $!;
        unlink $tmp;
        log_event( 'WARN', $ENV{REDIRECT_URL} // '-', 'cannot rename cache tempfile', path => $html_path, error => $err );
        return;
    }
}

# --- Output ---

sub output_page {
    my ( $content, $content_type, $ttl, $auth_protected ) = @_;
    $content_type  //= 'text/html; charset=utf-8';
    $ACCESS_REC{s} //= 200;                          # SM140
    $ACCESS_REC{b} = length( $content // '' );       # SM140
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\n";
    print "Content-type: $content_type\n";
    # L-1: baseline security headers. CSP and HSTS are deliberately NOT
    # emitted here - CSP is site-specific (depends on what external
    # resources pages load) and HSTS depends on whether TLS is in use;
    # both belong in the Apache vhost config.
    print "X-Content-Type-Options: nosniff\n";
    print "X-Frame-Options: SAMEORIGIN\n";
    print "Referrer-Policy: strict-origin-when-cross-origin\n";
    print "Content-Language: $RESPONSE_LANG\n" if $RESPONSE_LANG;    # SM179 (P1)
    if ($auth_protected) {
        print "Cache-Control: no-store, private\n";
    }
    elsif ( defined $ttl && $ttl > 0 ) {
        print "Cache-Control: public, max-age=$ttl\n";
    }
    else {
        print "Cache-Control: no-cache, must-revalidate\n";
    }
    print "Vary: Cookie\n";
    print "\n";
    print $content;
}

sub forbidden {
    $ACCESS_REC{s} //= 403;    # SM140
    binmode( STDOUT, ':utf8' );
    print "Status: 403 Forbidden\n";
    print "Content-type: text/plain; charset=utf-8\n\n";
    print "403 Forbidden\n";
}

# SM190: is a lazysite.conf service flag enabled? A tiny standalone reader - the
# processor loads no Lazysite modules - mirroring Lazysite::Util::service_enabled:
# default OFF; enabled / true / yes / on / 1 = on.
sub _conf_flag_enabled {
    my ($key) = @_;
    open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" or return 0;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\Q$key\E\s*:\s*(\S+)/;
        close $fh;
        my $v = lc $1;
        return ( $v eq 'enabled' || $v eq 'true' || $v eq 'yes' || $v eq 'on' || $v eq '1' )
            ? 1
            : 0;
    }
    close $fh;
    return 0;
}

sub not_found {
    my ($uri) = @_;
    $ACCESS_REC{s} //= 404;    # SM140

    my $md_path   = _system_page_md('404') // "$DOCROOT/404.md";    # SM201 fallback
    my $html_path = "$DOCROOT/404.html";

    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $page = is_fresh( $html_path, $md_path )
            ? read_file($html_path)
            : process_md( $md_path, $html_path );
        print "Status: 404 Not Found\n";
        print "Content-type: text/html; charset=utf-8\n\n";
        print $page;
        return;
    }

    # Bare fallback if no 404.md exists yet. chrome_string HTML-escapes $uri (it
    # was interpolated raw before - a reflected-markup vector on the 404 path).
    print "Status: 404 Not Found\n";
    print "Content-type: text/html; charset=utf-8\n\n";
    print '<p>' . _chrome( 'notfound.body', $uri ) . "</p>\n";
}

# --- Utilities ---

sub read_file {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts     = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

# --- SM140: first-party access log -------------------------------------------
# The processor records its own traffic - one JSON line per request under
# lazysite/logs/access-YYYYMMDD.jsonl - so visitor analytics need no access to
# the web server's logs (which are root-owned on panel hosts and undercount
# behind an nginx front). ALWAYS anonymised at write: the visitor key is a
# daily-salted keyed hash, never the IP. Emitters fill %ACCESS_REC; the main
# wrapper records once per request. Module-free per ADR 0001; stats.pl
# aggregates the files.

# stats.conf knobs the recorder honours (shared with the stats plugin).
sub _access_conf {
    my %c = ( first_party => 1, retention_days => 90 );
    if ( open my $fh, '<', "$LAZYSITE_DIR/stats.conf" ) {
        while ( my $l = <$fh> ) {
            $c{first_party}    = 0      if $l =~ /^first_party\s*:\s*(?:off|false|0)\b/i;
            $c{retention_days} = $1 + 0 if $l =~ /^retention_days\s*:\s*(\d+)/;
        }
        close $fh;
    }
    $c{retention_days} = 90 if $c{retention_days} < 1;
    return \%c;
}

# Daily-salted visitor key: same visitor+day -> same key (distinct daily
# visitors), never reversible to the IP (keyed on the site secret). On an
# auth-less site there is no .secret, and an unkeyed hash of ymd|ip would be
# IPv4-brute-forceable (2026-07-10 review, D6) - mint a dedicated salt once
# and key on that instead.
sub _visitor_key {
    my ($ymd) = @_;
    my $ip = $ENV{REMOTE_ADDR} // '';
    return '' unless length $ip;
    my $secret = '';
    if ( open my $sf, '<', "$LAZYSITE_DIR/auth/.secret" ) {
        local $/;
        $secret = <$sf> // '';
        close $sf;
    }
    $secret = _access_salt() unless length $secret;
    return substr( hmac_sha256_hex( "$ymd|$ip", $secret ), 0, 16 );
}

# Persistent random salt for the visitor key on secret-less sites. Minted
# once under logs/ (the recorder's own directory); losing it only re-keys
# the visitor tokens - it can never identify anyone.
sub _access_salt {
    my $path = "$LAZYSITE_DIR/logs/.access-salt";
    if ( open my $fh, '<', $path ) {
        local $/;
        my $s = <$fh> // '';
        close $fh;
        return $s if length $s;
    }
    my $salt = hmac_sha256_hex( join( '|', time, $$, rand, rand ), $LAZYSITE_DIR );
    if ( sysopen( my $fh, $path, O_WRONLY | O_CREAT, 0660 ) ) {
        # sysopen's mode is umask-filtered - re-assert 0660 so BOTH identities
        # (site-user CLI/dev-server and the www-data CGI) can rewrite it.
        chmod 0660, $path;
        syswrite( $fh, $salt );
        close $fh;
    }
    return $salt;
}

# Attacker-controlled field -> safe JSON string content (control chars
# stripped against log injection, length-capped, JSON-escaped).
sub _access_field {
    my ( $s, $cap ) = @_;
    $s //= '';
    $s =~ s/[\x00-\x1f\x7f]//g;
    $s = substr( $s, 0, $cap ) if length($s) > $cap;
    return _json_str($s);
}

# Record the request outcome. No-op when no emitter ran (redirects), when
# first_party: off, or on any internal failure - recording must never break
# serving. One O_APPEND write; lines are far below PIPE_BUF, so concurrent
# CGI appends cannot interleave.
sub _access_record {
    return unless defined $ACCESS_REC{s};
    my $ok = eval {
        my $conf = _access_conf();
        return 1 unless $conf->{first_party};
        my @t   = gmtime;
        my $ymd = sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3];
        my $dir = "$LAZYSITE_DIR/logs";
        eval { make_path($dir) } unless -d $dir;
        my $file   = "$dir/access-$ymd.jsonl";
        my $is_new = !-e $file;
        ( my $path = $ENV{REDIRECT_URL} || $ENV{REQUEST_URI} || '' ) =~ s/\?.*//s;
        my $line = '{"t":' . time()
            . ',"p":"' . _access_field( $path, 200 ) . '"'
            . ',"s":' .   ( $ACCESS_REC{s} + 0 )
            . ',"ch":"' . ( $ACCESS_REC{ch} // 'page' ) . '"'
            . ',"v":"' . _visitor_key($ymd) . '"'
            . ',"ua":"' . _access_field( $ENV{HTTP_USER_AGENT}, 160 ) . '"';
        my $ref = $ENV{HTTP_REFERER} // '';
        $line .= ',"r":"' . _access_field( $ref, 200 ) . '"' if length $ref;
        $line .= ',"c":1'                                    if $ACCESS_REC{c};
        $line .= ',"b":' . ( $ACCESS_REC{b} + 0 )            if defined $ACCESS_REC{b};
        # SM151: the sanitised request Host, so multi-site (many domains under
        # one docroot) can split visitor stats per domain later. DNS-shaped and
        # capped; empty (primary / malformed Host) is simply omitted.
        my $host = _request_host();
        $line .= ',"h":"' . _access_field( $host, 253 ) . '"' if length $host;
        $line .= "}\n";
        sysopen( my $fh, $file, O_WRONLY | O_APPEND | O_CREAT, 0664 )
            or return 1;    # silent: lazysite-check owns the writability story
        binmode $fh;
        syswrite( $fh, $line );
        close $fh;
        _access_prune( $dir, $conf->{retention_days} ) if $is_new;
        return 1;
    };
    log_event( 'WARN', '-', 'access record failed', error => "$@" )
        if !$ok && $@;
    return;
}

# Retention: on the first request of a new day, drop day-files older than the
# window. Filename-dated, so no stat storm; runs once per day per site.
sub _access_prune {
    my ( $dir, $days ) = @_;
    my @c      = gmtime( time() - $days * 86400 );
    my $cutoff = sprintf '%04d%02d%02d', $c[5] + 1900, $c[4] + 1, $c[3];
    opendir my $dh, $dir or return;
    for my $e ( readdir $dh ) {
        next unless $e =~ /^access-(\d{8})\.jsonl$/;
        unlink "$dir/$e" if $1 lt $cutoff;
    }
    closedir $dh;
    return;
}
