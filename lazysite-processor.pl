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
use JSON::PP     qw(encode_json decode_json);
use Digest::SHA  qw(hmac_sha256_hex sha256 sha256_hex);
use MIME::Base64 qw(encode_base64);                           # SM352: CSP script hashes
use POSIX        qw(strftime);
use Fcntl        qw(O_WRONLY O_APPEND O_CREAT LOCK_EX LOCK_NB LOCK_UN);
use Socket       qw(inet_pton inet_ntop AF_INET AF_INET6);    # SM929: the request address
# SM140: first-party access log
# SM389: one registry regenerator

# SM944: the processor's areas, one part each in lazysite-processor/ beside this
# script. Required by ABSOLUTE PATH from where this file really is, never through
# @INC, so the render path stays as ADR 0001 keeps it: no Lazysite:: module and no
# lib tree. A part is package main and loads nothing; a missing one fails here.
BEGIN {
    my $parts = dirname( realpath(__FILE__) ) . '/lazysite-processor';
    for my $part (qw(front-matter.pm oembed.pm remap.pm components.pm ct-cache.pm gates.pm access-log.pm front-door.pm include.pm forms.pm output.pm request.pm sources.pm registries.pm render.pm layout.pm)) {
        my $file = "$parts/$part";
        require $file;
    }
}

my $LOG_COMPONENT = 'processor';

# SM252: what stands in for the form timing token inside the CACHED html, until
# output_page mints a real pair on each response.
#
# These MUST be compile-time constants, not `our $X = '...'` further down the
# file. This script runs its main flow BEFORE the sub definitions below it, so a
# runtime assignment at the point of use has not executed yet and the variable is
# still empty when output_page reads it - and an empty pattern in s///g reuses
# the last successful match and fires at every position, which turned one page
# into 600KB of repeated HMAC. Found by probing the rendered page rather than by
# a test, because every assertion was reading an empty string and simply failing.
# (BEGIN rather than `use constant`, which the perlcritic profile rejects.)
our ( $FORM_TS_PLACEHOLDER, $FORM_TK_PLACEHOLDER );

BEGIN {
    $FORM_TS_PLACEHOLDER = '__LAZYSITE_FORM_TS__';
    $FORM_TK_PLACEHOLDER = '__LAZYSITE_FORM_TK__';
}

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

# SM944: `our` marks file-scope state a part in lazysite-processor/ reads; `my`
# is state only this script reads. A part is a separate file and cannot see a
# `my` here, and an `our` it declared for one would be a different, empty
# variable - t/lint/215 holds that line. Each is still initialised here, above
# the request dispatch, which runs before execution reaches anything below it.
our $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

# SM293: ASK where the engine tree is, do not compute one answer.
#
# A site migrates by MOVING the directory beside its docroot and nothing else -
# no config key, no flag day, no version gate - so both layouts work on the same
# code and an upgrade cannot half-migrate a site into an unbootable state.
#
# OUTSIDE WINS when both exist: a tree left inside the docroot is reachable by a
# front end that has not been told otherwise, which is the exposure being
# removed, so the engine governs the copy that is safe and `lazysite check`
# reports the one that is not.
#
# Module-free (ADR 0001 - the render path loads no Lazysite modules), mirroring
# Lazysite::Paths::lazysite_dir; t/lint/37 pins the pair, because a copy that
# drifts is how one directory comes to mean two things depending on who asks.
sub _lazysite_dir_for {
    my ($d) = @_;
    return '' unless defined $d && length $d;
    $d =~ s{/+\z}{};
    return '' unless length $d;
    my $leaf = $d;
    $leaf =~ s{\A.*/}{};         # basename, without File::Basename
    my $parent = $d;
    $parent =~ s{/[^/]*\z}{};    # dirname, likewise
    my $ext = "$parent/$leaf-lazysite";
    return -d $ext ? $ext : "$d/lazysite";
}
our $LAZYSITE_DIR = _lazysite_dir_for($DOCROOT);

# SM270: can THIS process write here? Ownership and mode arithmetic, never -w.
#
# -w answers for the real uid when the process is running as one identity and
# asking about another's reach, and under a no-suexec CGI those differ - which
# is the whole subject of the question. lazysite-check evaluates effective
# access the same way and for the same reason.
#
# Cheap on purpose: two stats, no fork, and only ever called on a manager page.
sub _cgi_can_write {
    my ($path) = @_;
    return 1 unless defined $path && length $path;
    my @st = stat $path or return 1;    # cannot stat: not our finding to report
    my ( $mode, $uid, $gid ) = @st[ 2, 4, 5 ];
    return 1 if $mode & 0002;                      # world-writable
    return 1 if $uid == $> && ( $mode & 0200 );    # owner
    return 1 if ( $mode & 0020 )                   # group, including supplementary
        && grep { $_ == $gid } ( $) =~ /(\d+)/g );
    return 0;
}
my $LAZYSITE_URI = "/lazysite";

# SM294: the front-door settings are DEPLOYMENT properties - they describe how
# the site is fronted, and are set once when the pool is spawned.
#
# They must be captured HERE, at file scope, for a reason that is easy to miss
# and impossible to see from a passing CGI test: under FastCGI, FCGI.pm REPLACES
# %ENV on every Accept() with that request's parameters. Anything the web server
# did not send is gone. So an $ENV{...} read inside the request loop sees the
# request, never the pool's environment, and a setting read there is silently
# always-off in exactly the deployment it exists for. $DOCROOT above is captured
# for the same reason. t/lint/43 pins it.
my $FRONT_DOOR     = $ENV{LAZYSITE_FRONT_DOOR} ? 1 : 0;
our $FRONT_CGIBIN   = $ENV{LAZYSITE_CGIBIN} // '';
our $RELAY_TIMEOUT  = ( $ENV{LAZYSITE_RELAY_TIMEOUT} || 120 ) + 0;
our $PREVIEW_COOKIE = 'lzs_preview';    # SM071: theme/layout preview cookie

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

our $CONF_FILE = $CONF_OVERRIDE
    ? $CONF_OVERRIDE
    : "$LAZYSITE_DIR/lazysite.conf";
# D013: layouts/ is the new structural root. A local layout lives at
# $LAYOUT_DIR/NAME/layout.tt with optional $LAYOUT_DIR/NAME/layout.json
# metadata. Themes nest under layouts/NAME/themes/THEME/. No flat-template
# fallback ($LAZYSITE_DIR/templates/*.tt) and no default view.tt path —
# if no layout is installed, the embedded $FALLBACK_LAYOUT is the sole
# fallback.
our $LAYOUT_DIR     = "$LAZYSITE_DIR/layouts";
our $REGISTRY_DIR   = "$LAZYSITE_DIR/templates/registries";
our $MANAGER_LAYOUT = "$LAZYSITE_DIR/manager/layout.tt";
our $REMOTE_TTL     = 3600;  # seconds before remote content is refetched (default 1 hour)
our $REGISTRY_TTL   = 14400; # seconds before registries are regenerated (default 4 hours)
# SM091: the cache base normally lives under the docroot, but a read-only
# browse (the dev server's --auto-index) can relocate it off the docroot via
# LAZYSITE_CACHE_DIR so pointing the processor at an arbitrary tree writes
# nothing into it. Unset (production / tests) keeps the original location.
my $CACHE_BASE       = $ENV{LAZYSITE_CACHE_DIR} || "$LAZYSITE_DIR/cache";
our $LAYOUT_CACHE_DIR = "$CACHE_BASE/layouts";
our $CT_CACHE_DIR     = "$CACHE_BASE/ct";
our $TT_COMPILE_DIR   = "$CACHE_BASE/tt";        # P-4 TT on-disk compile cache
my $HOST_CACHE_DIR   = "$CACHE_BASE/hosts";    # SM110 phase 2: per-alias-host page cache

# SM311's dependency record: what this render READ, beyond its own source, so
# the page cache can tell when it has gone stale. Declared here with the other
# request-lifetime state (t/lint/39) because process_md resets it at the start
# of a render and the recorders are scattered down the file - the full
# reasoning is beside _tt_dep and write_deps.
our @TT_DEPS;        # absolute paths this render read
our $TT_DEP_LIVE;    # a source with no local mtime (url:) was used

# SM293 step 3: the generated registries (sitemap.xml, llms.txt, the feeds) are
# CACHED here and served by the engine, instead of being written as files at the
# content root.
#
# They were written into the served tree, which is how SM248 happened: a file at
# the docroot root is resolved by the front end before the engine is consulted,
# so a secondary domain was handed the primary's sitemap. Generating on request
# and caching keeps a high-demand artefact out of the document root while still
# costing one render per TTL rather than one per request.
#
# Under $CACHE_BASE, so on a migrated site (SM293 step 2) it is outside the
# document root along with everything else the engine owns.
our $REGISTRY_CACHE_DIR = "$CACHE_BASE/registries";
our %AUTH_CONTEXT;            # populated by main() auth check, read by render_content()
our %ACCESS_REC;              # SM140: per-request outcome for the first-party access log
our $RESPONSE_LANG = 'en';    # SM179 (P1): the rendered page's language, set per
                              # request from page_lang; emitted as Content-Language.
our $REQUEST_CROOT;    # SM151: the request's confined content root (undef => docroot),
                       # set by main(), read by resolve_scan() so per-domain search is
                       # boxed to the requesting domain's subtree without re-entering
    # resolve_site_vars (which calls resolve_scan for conf directives)
our $ACL_MAP_CACHE;    # SM268 H13: acls.json parsed at most once per request -
                      # a scan asks the read decision up to 200 times. undef =
                      # not loaded, 0 = load failed (fail closed), hashref = the
                      # store.

# Built-in fallback template - used when no layout.tt is found
our $FALLBACK_LAYOUT = <<'END_FALLBACK';
<!DOCTYPE html>
<html lang="[% page_lang || 'en' %]">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    [% IF page_meta_desc %]<meta name="description" content="[% page_meta_desc %]">[% END %]
    <title>[% page_meta_title %][% IF site_name %]  -  [% site_name %][% END %]</title>
    [%# SM179 P2: hreflang alternates for a language set, plus x-default on the source (first) language %]
    [% FOREACH l IN languages %][% IF l.exists %]<link rel="alternate" hreflang="[% l.lang %]" href="[% l.url %]">
    [% END %][% END %][% IF languages.size %]<link rel="alternate" hreflang="x-default" href="[% languages.0.url %]">
    [% END %]
    <link rel="stylesheet" href="/assets/lazysite-chrome.css?v=[% lazysite_version %]">
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
<script src="/assets/lazysite-chrome.js?v=[% lazysite_version %]" defer></script>
[% IF nav.size %]
<nav style="margin-bottom:1.5rem;padding-bottom:0.75rem;border-bottom:1px solid #eee;font-size:0.9rem;">
  [% FOREACH item IN nav %]
    [%# Three cases, distinguished by whether item.url is set and
        whether children exist:
          - url present                : leaf link or clickable parent
          - url empty/absent           : group heading (not a link) %]
    [% IF item.url %]
    <a href="[% item.url | url_safe %]" class="nav-link"[% IF request_uri == item.url %] aria-current="page"[% END %]>[% item.label %]</a>
    [% ELSE %]
    <span class="nav-group">[% item.label %]</span>
    [% END %]
    [% IF item.children %]
      [% FOREACH child IN item.children %]
      <a href="[% child.url | url_safe %]" class="nav-link nav-child"[% IF request_uri == child.url %] aria-current="page"[% END %]>[% child.label %]</a>
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
our %LANG_MAP = (
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
our %ENV_ALLOWLIST = map { $_ => 1 } qw(
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
our %ALIAS_OVERRIDE_KEYS = map { $_ => 1 }
    qw(site_name theme layout nav_file search_default content_root site_url
    lang lang_group);    # SM179: per-host language + language-set membership

# SM151 P6: content-type by extension for per-domain static files served by the
# processor (_serve_content_static). Kept small - the SEO artefacts
# (xml/rss/atom/txt) plus common web assets; anything unlisted falls back to
# octet-stream (a safe download). Declared here in the config block so it is
# initialised before the request is dispatched.
our %STATIC_CT = (
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
    # request. Before it, every caller opened the .md file for
    # itself - peek_auth, peek_payment, peek_query_params, peek_ttl
    # and peek_content_type, plus the tt_deps and nocache reads in
    # the cache path, seven sites today; now the first peek reads
    # the file, the rest hit this cache. Cache key is (path, mtime) so
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
            # SM656: the page says what KIND of page it is. The admin bar is
            # injected for anyone holding `ui`, which is a property of the
            # PERSON - and on an application page the bar's Edit link opens the
            # Markdown of a page whose body is a script, which is the fastest
            # way to break the application and the most prominent action
            # offered to the person most likely to click it.
            elsif ( $line =~ /^admin_bar\s*:\s*(\w+)/i ) { $m{admin_bar} = lc $1 }
            # SM812: a section's index names the theme its pages inherit. Only a
            # name the page key would accept is recorded, so an unusable value
            # reads as absent and the walk carries on upwards.
            elsif ( $line =~ /^theme\s*:\s*["']?([A-Za-z0-9_-]+)["']?\s*$/ ) { $m{theme} = $1 }
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

            # SM311: does this page read anything OTHER than itself?
            #
            # Only the presence of the block is recorded, not its contents. The
            # record itself is written at render time by the code that actually
            # resolved the sources, which is the only place that knows what a
            # `scan:` glob matched. Parsing the sources here would mean two
            # implementations of that question, and the second one would drift.
            #
            # SM888 A2: THIS ANSWERS FOR TWO OF THE THREE SOURCE KINDS. An
            # `::: include` is in the BODY, and this peek stops at the front
            # matter on purpose - a scan puts 200 pages through it. So the
            # cache-hit path asks this AND whether a record already exists,
            # and the two together cover all three. See try_serve_cache.
            $m{tt_deps} = 1 if $line =~ /^tt_page_var\s*:\s*$/;

            # SM857: a `db:...(mine)` binding renders per viewer, so the page
            # takes the gated page's cache treatment (see `$per_viewer` in
            # main). DELIBERATELY WIDER THAN THE GRAMMAR: any front-matter line
            # with `db:` and the word `mine` on it. This is a trigger, not a
            # second parser - a false positive costs a cached render, and a
            # binding this misses is refused by resolve_db, never cached.
            $m{db_mine} = 1 if $line =~ /\bdb:/i && $line =~ /\bmine\b/;

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

# SM743: the display name for an account, or '' when it has none.
#
# DELIBERATE local copy of Lazysite::Auth::Settings::display_name_for, for the
# same reason _groups_grant_cap below is one: the processor's render path is
# module-free by design (ADR 0001), so it cannot import the shared helper. Keep
# the two in sync - raw-octets read, decode_json, and the same '' on every
# failure.
#
# A FIRST DRAFT CALLED THE SHARED HELPER INSIDE AN eval AND WOULD HAVE BEEN
# INERT. The module is not loaded here, so the call would have died, the eval
# would have swallowed it, and every display name would silently have been ''
# - a feature that ships, appears to work, and does nothing. That is the exact
# shape of SM732's unreachable render and SM743's own dead field, which is a
# poor way to fix a dead field.
#
# MEMOISED ON THE FILE'S IDENTITY, not on a clock, following SM334's settings
# cache and the descriptor cache: a rewrite changes mtime or size, so the key
# misses and the value is re-read. Under the FastCGI pool (SM142) this process
# serves many requests, and reading and decoding user-settings.json on every
# authenticated render is exactly the per-request cost SM663 and SM685 were
# about. A stat is not.
{
    my %_dn_cache;

    sub _display_name_for {
        my ($user) = @_;
        return '' unless defined $user && length $user;

        my $f  = "$LAZYSITE_DIR/auth/user-settings.json";
        my @st = stat $f;
        return '' unless @st;

        my $key = "$f:$st[9]:$st[7]";
        my $all = $_dn_cache{$key};

        unless ($all) {
            # THE SLURP IS SCOPED TO THE READ, for the reason spelled out
            # below in _groups_grant_cap: a `local $/;` left in effect at a
            # sub's top level silently changed how a LATER function read a
            # different file, and cost every nested group its capabilities.
            {
                open my $fh, '<:raw', $f or return '';
                local $/;
                my $raw = <$fh>;
                close $fh;
                $all = eval { decode_json($raw) };
            }
            return '' unless ref $all eq 'HASH';
            %_dn_cache = () if keys %_dn_cache > 4;
            $_dn_cache{$key} = $all;
        }

        return '' unless ref $all->{$user} eq 'HASH';
        my $n = $all->{$user}{display_name};
        return defined $n ? $n : '';
    }
}

# SM095: does any of these groups carry capability $cap (from groups-settings.json)?
# DELIBERATE local copy of Lazysite::Auth::Settings::groups_grant_cap - the
# processor's render path is module-free by design, so it cannot import the
# shared helper. Recorded in docs/adr/0001-capability-resolution.md; keep this
# in sync with the shared implementation (raw-octets read + decode_json).
sub _groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return 0 unless -f $f;

    # THE SLURP IS SCOPED TO THE READ. `local $/;` at this sub's top level
    # stayed in effect for everything after it - including _group_closure
    # below, whose _group_membership_map reads the groups file with
    # `while (<$fh>)`. In slurp mode that loop takes the WHOLE file as one
    # line, so the map collapsed from 21 groups to 1, the parent table came
    # out empty, and NO nested group ever resolved.
    #
    # What that cost: a capability held by a group through nesting - which is
    # how the shipped groups are arranged, ch-ui containing site-admins and
    # the rest - was never granted. An account in site-admins was told
    # "Manager access not permitted". It fails CLOSED, so it is a lockout
    # rather than a leak, and it is invisible to any test whose user is in a
    # group that holds the capability DIRECTLY.
    my $gs;
    {
        open my $fh, '<:raw', $f or return 0;
        local $/;
        $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
        close $fh;
    }
    for my $g ( _group_closure(@groups) ) {    # SM121: compound-expanded
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{$cap};
    }
    return 0;
}

# SM223: which ACL entry governs $rel? Exact path first, then the LONGEST
# matching folder prefix, so a tighter rule on a sub-folder beats a broader one
# above it. Folder scope is an entry in the same store rather than a separate
# prefix rule in lazysite.conf - one place to look, and one place to be wrong.
sub _acl_entry_for {
    my ( $map, $rel, $mode ) = @_;
    $mode //= '';
    $rel =~ s{\A/+}{};

    # SM268 H10: an entry with no list for the mode we are deciding is NOT a
    # tighter rule - it is NO rule, and it must not win the longest match.
    #
    # "Longest match wins" is documented as "a tighter rule on a sub-folder beats
    # a broader one above it". An owner-only entry says nothing about reading, so
    # letting it beat an enclosing folder's `read` list turned the folder gate
    # off for that one file. The operator action that produced it is DUPLICATE in
    # the file manager: action_copy writes `{ owner => $user }` for the new file,
    # so copying a file inside a protected section republished it to the world -
    # no warning, no log line, and performed by someone who need not hold any
    # permission-changing capability.
    #
    # So for a mode decision, only entries carrying a non-empty list for that
    # mode are candidates. With no mode ("does anything govern this path?") every
    # entry counts, which is what the cache and draft checks want.
    my $governs = sub {
        my ($e) = @_;
        return 0 unless ref $e eq 'HASH';
        return 1 unless length $mode;
        return ( ref $e->{$mode} eq 'ARRAY' && @{ $e->{$mode} } ) ? 1 : 0;
    };

    return $map->{$rel} if $governs->( $map->{$rel} );

    # SM268 H14: a folder entry covers the section's OWN landing page.
    #
    # `private.md` renders at /private and `private/index.md` at /private/, so a
    # gate on the folder `private` left its front door open: /private served its
    # body while /private/ bounced to login. The page that introduces a held-back
    # section is the last one that should be public.
    if ( $rel =~ m{\A(.+)\.(?:md|url|html)\z} ) {
        my $stem = $1;
        return $map->{$stem} if $governs->( $map->{$stem} );
    }

    my $best;
    my $best_len = -1;
    for my $k ( keys %$map ) {
        next unless $governs->( $map->{$k} );
        ( my $p = $k ) =~ s{\A/+}{};
        $p =~ s{/+\z}{};
        next unless length $p;
        next unless index( $rel, "$p/" ) == 0;
        next unless length($p) > $best_len;
        $best     = $map->{$k};
        $best_len = length $p;
    }
    return $best if $best;

    # SM287: the SITE-WIDE rule, and it is the WEAKEST - checked only when
    # nothing more specific governs, so a public carve-out inside a private site
    # stays expressible (which is the common shape: everything private except
    # the landing page).
    #
    # Before this, a root entry did nothing under any spelling. Not by an
    # oversight in one branch: the loop above skips a zero-length prefix, and
    # even without that guard `index($rel, "$p/")` can never match an empty
    # prefix because the leading slash has already been stripped from $rel. So
    # there was NO way to say "this whole site is private" - auth_default governs
    # pages and deliberately does not reach statics, and enumerating top-level
    # folders fails OPEN as content grows, since a file added at the root next
    # month is public with nothing to say so.
    #
    # '/' is what the writer stores. '' and '.' are accepted too: a hand-edited
    # store is a real interface here and all three plainly mean the same thing.
    # Glob spellings are NOT accepted - the store has no matching language, and
    # audit_site's acl_keys_matching_nothing surfaces a key that governs nothing.
    for my $rk ( '/', '', '.' ) {
        return $map->{$rk} if $governs->( $map->{$rk} );
    }
    return;
}

# SM223: may this identity READ $rel on the anonymous/public path?
#
# DELIBERATE local copy of Lazysite::Auth::Acl::_acl_allows - the render path is
# module-free by design (ADR 0001), and Auth::Acl pulls in JSON::PP, File::Path
# and Auth::Settings. Keep the semantics in sync with the shared implementation;
# t/lint/31 pins them.
#
# The semantics are deliberately UNCHANGED from the authoring channels, because
# this is the same question asked by a different caller:
#
#   * no entry            -> allowed. A static file nobody has said anything
#                            about is served, exactly as before. auth_default
#                            does NOT reach static files; protecting one is an
#                            explicit act.
#   * owner matches       -> allowed.
#   * no read list        -> allowed. An entry carrying only an owner does not
#                            restrict reading, here or in the manager.
#   * read list           -> the user or one of their groups must appear.
#
# An anonymous request has no user and no groups, so a read list refuses it -
# which is the point.
#
# NOTE the caller must use THIS, never Auth::Acl::_acl_denied: that routes
# through _is_operator, which returns 1 on a site where no group grants manager
# access. On an anonymous request that would treat the public as an operator and
# bypass the ACL entirely, on exactly the sites least equipped to notice.
# SM286: the private content store, resolved module-free.
#
# DELIBERATE local copy of Lazysite::Private - the render path loads no Lazysite
# modules (ADR 0001), exactly as _acl_allows_read copies Auth::Acl. t/lint/36
# pins the pair.
#
# Nothing moves content here yet, and before this the private tree was simply
# never consulted - a path there was not found, so it 404'd and nothing leaked.
#
# THE TRAP, MEASURED. Resolution and key derivation must change TOGETHER. Every
# ACL predicate below derives its docroot-relative key with `s{^$DOCROOT/}{}`,
# which FAILS for a path in the private tree, and each returns 0 on failure -
# meaning "not governed", "not draft", "not refused". Add _content_abs alone,
# leaving those three as they were, and a gated file in the private store is
# served to anonymous visitors, to the wrong user, and out of a draft section.
# Verified by doing exactly that and watching the test go red.
#
# So this is not preparation that could be split further. Anyone continuing the
# wiring on the other surfaces should assume the same shape: wherever a surface
# turns an absolute path back into a key, resolving the new tree without fixing
# the derivation opens a hole rather than leaving one closed.
our $PRIVATE_ROOT_CACHE;

sub _private_root {
    return $PRIVATE_ROOT_CACHE if defined $PRIVATE_ROOT_CACHE;
    my $d = $DOCROOT // '';
    $d =~ s{/+\z}{};
    return $PRIVATE_ROOT_CACHE = '' unless length $d;

    # Named for the docroot, not a fixed name in the parent - or two docroots
    # sharing a parent share one store and each resolves the other's protected
    # content by path. Mirrors Lazysite::Private::private_root; t/lint pins the
    # pair (ADR 0001 keeps this copy module-free, which makes drift the risk).
    my $leaf = $d;
    $leaf =~ s{\A.*/}{};         # basename, without File::Basename
    my $parent = $d;
    $parent =~ s{/[^/]*\z}{};    # dirname, likewise
    return $PRIVATE_ROOT_CACHE = "$parent/$leaf-lazysite-private";
}

# The docroot-relative ACL key for an absolute path in EITHER tree. undef when
# the path is in neither, which every caller must treat as "not content".
sub _content_rel {
    my ($abs) = @_;
    return undef unless defined $abs && length $abs;
    my $rel = $abs;
    return $rel if $rel =~ s{\A\Q$DOCROOT\E/}{};
    my $priv = _private_root();
    return $rel if length $priv && $rel =~ s{\A\Q$priv\E/}{};
    return undef;
}

# Where a docroot-anchored path actually lives. PRIVATE WINS when both exist -
# the same fail-safe direction Lazysite::Private takes, because a stray public
# copy is already reachable by the front end and serving it from here too would
# hide the fault.
sub _content_abs {
    my ($abs) = @_;
    return $abs unless defined $abs;
    my $rel = $abs;
    if ( $rel =~ s{\A\Q$DOCROOT\E/}{} ) {
        my $priv = _private_root();
        return "$priv/$rel" if length $priv && -e "$priv/$rel";
    }
    return $abs;
}

# The private twin of a docroot path, whether or not it exists. Used for files
# that must FOLLOW their source into the store rather than be looked up - the
# page cache above all: a gated page whose .html render lands in the docroot has
# republished the very content the gate was protecting, in a file the front end
# serves without asking anything.
sub _private_twin {
    my ($abs) = @_;
    return $abs unless defined $abs;
    my $priv = _private_root();
    return $abs unless length $priv;
    return $priv if $abs eq $DOCROOT;    # the store mirrors the docroot itself
    my $rel = $abs;
    return $abs unless $rel =~ s{\A\Q$DOCROOT\E/}{};
    return "$priv/$rel";
}

# Confinement for a resolved content path: inside the domain's content root, OR
# inside that root's twin in the private store.
#
# NOT "anywhere in the private store". The check this widens exists so a symlink
# in one domain's tree cannot serve a sibling domain's files (SM151 spec S1), and
# the store mirrors the docroot's shape - so the twin of $croot is the exactly
# equivalent boundary. Accepting the whole store would hand every domain access
# to every other domain's private content, which is a bigger hole than the one
# the private store closes.
sub _path_under_content {
    my ( $real, $croot ) = @_;
    return 1 if _path_under( $real, $croot );
    my $twin = _private_twin($croot);
    return 0 if !defined $twin || $twin eq $croot;
    return _path_under( $real, $twin ) ? 1 : 0;
}

sub _acl_allows_read {
    my ( $rel, $user, @groups ) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 1 unless -f $f;

    # SM268 H12: a store that EXISTS but cannot be read or parsed fails CLOSED.
    #
    # It used to fail open, silently: no WARN, no access-log flag, and every
    # protected file served to anyone. Hand-written JSON is the only interface
    # for a folder rule (SM181), so a stray comma is a realistic way to reach
    # this - and the failure was indistinguishable from having no rules at all.
    #
    # Closed is the right direction and it is recoverable: the site refuses,
    # which is loud, and the manager is unaffected (it reads through Auth::Acl),
    # so an operator can still get in and fix the file. Open is not recoverable -
    # the disclosure has already happened by the time anyone notices.
    # Parsed at most once per request. SM268 H13 made this a hot path: a scan
    # filters up to 200 pages through it, and re-reading and re-decoding the
    # store per page would turn one render into 200 opens. A failed load is
    # cached as a failure, so it still fails closed and still logs once.
    my $map;
    if ( defined $ACL_MAP_CACHE ) {
        return 0 unless ref $ACL_MAP_CACHE eq 'HASH';
        $map = $ACL_MAP_CACHE;
    }
    else {
        my $raw = do {
            if ( open my $fh, '<:raw', $f ) {
                local $/;
                my $c = <$fh>;
                close $fh;
                $c;
            }
            else { undef }
        };
        unless ( defined $raw ) {
            $ACL_MAP_CACHE = 0;
            log_event( 'ERROR', $rel, 'ACL store unreadable - refusing (fail closed)' );
            return 0;
        }
        $map = eval { JSON::PP::decode_json($raw) };
        unless ( ref $map eq 'HASH' ) {
            $ACL_MAP_CACHE = 0;
            log_event( 'ERROR', $rel,
                'ACL store unparseable - refusing (fail closed). Fix '
                    . 'lazysite/auth/acls.json; every protected path is denied until you do.' );
            return 0;
        }
        $ACL_MAP_CACHE = $map;
    }
    return 1 unless keys %$map;

    my $a = _acl_entry_for( $map, $rel, 'read' );
    return 1 unless ref $a eq 'HASH';
    return 1 if defined $a->{owner} && length $user && $a->{owner} eq $user;

    my $list = $a->{read};
    return 1 unless ref $list eq 'ARRAY' && @$list;

    # SM268 01-L1: one group semantics, not three. This compared the raw
    # X-Remote-Groups list exactly, while check_auth's `groups:` comparison
    # lowercases both sides and _groups_grant_cap expands compound groups
    # through the closure - so `Editors` was refused where `editors` was
    # allowed, and membership of a group NESTED in the granted one did not
    # count. It failed closed, so it was a correctness defect rather than an
    # exposure, but a sysop meeting it reads it as "the ACL is broken" and
    # the obvious repair is to widen the rule.
    my %grp = map { lc($_) => 1 } _group_closure(@groups);
    for my $e (@$list) {
        next unless defined $e && length $e;
        if ( $e =~ /\A\@(.+)\z/ ) {
            my $g = lc $1;    # capture immediately - any later match clobbers $1
            return 1 if $grp{$g};
        }
        elsif ( length $user && $e eq $user ) {
            return 1;
        }
    }
    return 0;
}

# SM223: is an ACL entry governing this file at all?
#
# Separate from the allow decision because the ALLOWED case still matters: if the
# answer depended on who asked, the response must not be stored by a shared
# cache, the same rule protected pages already follow. A file with no entry is
# ordinary public content and stays cacheable.
# SM181: is this path inside a DRAFT section?
#
# Draft is an attribute of a protected entry, not a separate mechanism:
#
#   { "upcoming": { "read": ["@editors"], "draft": true } }
#
# It changes two things and nothing else:
#
#   * the refusal becomes a 404 rather than a bounce to login. A section held
#     back before launch should not answer at guessable URLs - a 403 or a login
#     form confirms that /upcoming/pricing exists, which is the thing being held
#     back. This filing's own words: "don't even reveal the URLs".
#   * it is absent from the registries and from search, always - for everyone,
#     regardless of who triggered the generation. A sitemap is written once and
#     served to the public, so a draft page listed in it is published no matter
#     what the page itself answers.
#
# An ANONYMOUS request is never allowed into a draft section, even when the entry
# carries no read list. That differs from the ordinary rule (no list = allowed)
# and it has to: a draft with no list would otherwise be public, which is the
# opposite of what the word means. With no list, any signed-in user may preview;
# with one, the list decides.
sub _acl_is_draft {
    my ($abs) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;
    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;
    open my $fh, '<:raw', $f or return 0;
    my $map = eval {
        local $/;
        JSON::PP::decode_json(<$fh>);
    } || {};
    close $fh;
    return 0 unless ref $map eq 'HASH';
    my $a = _acl_entry_for( $map, $rel );
    return ( ref $a eq 'HASH' && $a->{draft} ) ? 1 : 0;
}

sub _acl_governed {
    my ($abs) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;
    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;

    # Shares _acl_allows_read's per-request parse (SM268 H13). A store that
    # failed to load counts as governing everything: _acl_allows_read is
    # refusing every path, and both callers want that answer - no-store on the
    # response, and out of the registries.
    my $map;
    if ( defined $ACL_MAP_CACHE ) {
        return 1 unless ref $ACL_MAP_CACHE eq 'HASH';
        $map = $ACL_MAP_CACHE;
    }
    else {
        open my $fh, '<:raw', $f or return 1;
        $map = eval {
            local $/;
            JSON::PP::decode_json(<$fh>);
        } || {};
        close $fh;
        return 0 unless ref $map eq 'HASH';
        $ACL_MAP_CACHE = $map;
    }
    return ref( _acl_entry_for( $map, $rel ) ) eq 'HASH' ? 1 : 0;
}

# SM898: WHICH entry governs a path - its key - or undef when none does.
#
# `::: include` needs to know not whether the partial is governed but whether
# the including page is governed BY THE SAME RULE, and _acl_entry_for returns
# the entry without its key. The key is recovered by identity against the map
# rather than by repeating the longest-match logic here: two copies of "which
# rule wins" is how the two halves of a rule come to disagree (SM268 H10 was
# one such copy). Same store, same per-request parse, same failed-load answer
# as _acl_governed: a store that will not load governs everything, and here
# that means every path reports the same sentinel key and no include of
# governed content is refused for being outside its section - the failed load
# has already refused every page, which is the louder answer.
sub _acl_governing_key {
    my ($abs) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return undef unless -f $f;
    my $real = realpath($abs);
    return undef unless defined $real;
    my $rel = _content_rel($real);
    return undef unless defined $rel;

    my $map;
    if ( defined $ACL_MAP_CACHE ) {
        return '*' unless ref $ACL_MAP_CACHE eq 'HASH';
        $map = $ACL_MAP_CACHE;
    }
    else {
        open my $fh, '<:raw', $f or return '*';
        $map = eval {
            local $/;
            JSON::PP::decode_json(<$fh>);
        } || {};
        close $fh;
        return undef unless ref $map eq 'HASH';
        $ACL_MAP_CACHE = $map;
    }
    my $entry = _acl_entry_for( $map, $rel );
    return undef unless ref $entry eq 'HASH';
    for my $k ( keys %$map ) {
        return $k if ref $map->{$k} eq 'HASH' && $map->{$k} == $entry;
    }
    return undef;
}

# SM223: gate a SOURCE-LESS static file (no .md/.url behind it) on the ACL.
#
# Returns true when it has already written a response and the caller must stop.
# A page with a Markdown source is gated by check_auth as before and never
# reaches here.
#
# Anonymous and refused bounces to the login page, the way a protected page
# does, so a person following a link to a private PDF gets somewhere useful.
# Authenticated and refused gets 403, because logging in again will not help.
sub _acl_refused {
    my ( $abs, $uri ) = @_;

    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;    # no store, no cost

    # SM651: THE WAY IN IS NEVER GATED BY THE THING IT IS THE WAY IN TO.
    #
    # A rule at `/` governs every path, including the login page. An anonymous
    # visitor is redirected to /login; /login is anonymous; it is refused and
    # redirected to itself. Measured: four redirects deep and still 302. The
    # chrome stylesheet went with it, so even a reachable login page would have
    # rendered unstyled.
    #
    # WORSE THAN AN ORDINARY MISCONFIGURATION, because signing in is the only
    # way to get an interactive session to undo it: a site protected this way
    # FROM THE MANAGER UI takes its operator's own access with it. The test
    # instance recovered only because the rule was set over a partner token,
    # which still reaches acl-remove - a route a browser user does not have.
    #
    # check_auth has carried exactly this carve-out for auth_default since it
    # was written; the ACL path never had it. The same question asked by a
    # different caller should not get a different answer, so it is asked once
    # here, ahead of the store, and covers all four callers of this sub.
    #
    # NOT a rule about the path `/` specifically: a rule at any depth that
    # governs the login page has the same effect, and a sysop who names
    # /login explicitly has still not asked to be locked out.
    # SM651: is_auth_surface() already answers "is this the way in", follows
    # auth_redirect and covers logout; it has been the cache-protection
    # predicate since SM071. Reusing it rather than writing a second one is the
    # point - two predicates for one question is how the two halves of a rule
    # start disagreeing, which is the defect SM654 filed against a hand-kept
    # copy of the same fact. The engine's own chrome is added because a login
    # page that renders unstyled is not a usable way in.
    return 0 if is_auth_surface($uri) || _is_engine_asset($uri);

    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;

    my %sv = resolve_site_vars();
    # auth => 'none' asks check_auth for the IDENTITY without enforcement, so
    # auth_default is not consulted - static files are governed by the ACL alone.
    my $id     = check_auth( $uri, { auth => 'none' }, \%sv );
    my @groups = @{ $id->{auth_groups} // [] };
    my $user   = $id->{auth_user} // '';

    # SM181: a draft section is not published, so an anonymous request is refused
    # even when the entry carries no read list - and refused as a 404, which
    # reveals nothing about what is being held back.
    my $draft = _acl_is_draft($abs);
    if ( $draft && !$id->{authenticated} ) {
        log_event( 'INFO', $uri, 'draft section hidden from the public' );
        not_found($uri);
        return 1;
    }

    return 0 if _acl_allows_read( $rel, $user, @groups );

    # A signed-in user outside a DRAFT section's list also gets 404, not 403:
    # the section's existence is the thing being withheld, and a 403 to an
    # authenticated non-editor discloses it just as effectively as one to the
    # public.
    if ($draft) {
        log_event( 'WARN', $uri, 'draft section refused', user => $user );
        not_found($uri);
        return 1;
    }

    if ( $id->{authenticated} ) {
        log_event( 'WARN', $uri, 'static refused by ACL', user => $user );
        $ACCESS_REC{s} //= 403;
        $ACCESS_REC{ar} = 1;
        # SM381: through output_page. This is an ACCESS REFUSAL on a static,
        # which makes it one of the responses most worth carrying the header
        # set rather than least.
        return output_page(
            "<!DOCTYPE html><html><body><h1>Forbidden</h1>"
                . "<p>You do not have access to this file.</p></body></html>\n",
            'text/html; charset=utf-8', undef, 1, '403 Forbidden' );
    }

    log_event( 'WARN', $uri, 'static refused by ACL', user => '-' );
    $ACCESS_REC{s} //= 302;
    $ACCESS_REC{ar} = 1;
    my $redirect_path = $sv{auth_redirect} || '/login';
    my $next          = uri_encode($uri);
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "$_\r\n" for _security_headers();    # SM381
    print "Cache-Control: no-store\r\n";
    # SM353: state the type. With none, the response carried the CGI's own
    # (text/x-perl) - wrong on every gated request on every site, and it
    # advertised the implementation language on a security boundary for nothing.
    print "Content-Type: text/html; charset=utf-8\r\n";
    print "Location: $redirect_path?next=$next\r\n\r\n";
    return 1;
}

# SM138: does ANY group grant manager access (ui / manage_users / the manager
# flag)? When none does, the site is unsecured/dev and any authenticated user is
# a manager. Local copy of the same decision Auth::Settings::site_grants_manager
# makes - the render path stays module-free (ADR 0001).
sub _site_grants_manager {
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return 0 unless -f $f;
    # SM906 T3 follow-up: A STORE THAT EXISTS AND CANNOT BE READ IS SECURED.
    # "0" here means "unsecured site - every signed-in user is a manager", so an
    # unreadable or undecodable groups-settings.json made every session render as
    # an operator. Absent stays unsecured (a site with no groups yet); present but
    # unreadable fails closed, as Auth::Settings::site_grants_manager now does.
    open my $fh, '<:raw', $f or do {
        log_event( 'WARN', '-', 'cannot read groups-settings.json - treating the site as secured',
            error => "$!" );
        return 1;
    };
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) };
    close $fh;
    if ( ref $gs ne 'HASH' ) {
        log_event( 'WARN', '-', 'groups-settings.json does not decode - treating the site as secured' );
        return 1;
    }
    for my $g ( keys %{$gs} ) {
        my $cfg = $gs->{$g};
        next unless ref $cfg eq 'HASH';
        return 1 if $cfg->{ui} || $cfg->{manage_users} || $cfg->{manager};
    }
    return 0;
}

# Module-free raw-octets read of groups-settings.json, keeping the render path
# free of Lazysite modules (ADR 0001). The store carries each group's
# capabilities and its nesting, which _group_closure and _groups_grant_cap
# resolve.
#
# SM279: it also USED to carry a `dav_scope` confinement, read here by
# _group_scopes / _group_home_domain. Those were removed - SM165 moved
# confinement to the domain-owned model in 0.7.26 and the two copies here were
# dead code from that day, so the file browser roots from _domain_scopes /
# _domain_home instead.
sub _group_settings {
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return {} unless -f $f;
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
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my $f = "$LAZYSITE_DIR/auth/groups";
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

# login-loop fix: an authenticated account without the `ui` capability that
# reaches /manager/ gets this terminal 403 - a clear explanation instead of a
# redirect back to /login (which, seeing the valid session, would loop). Names
# the likely cause (an API/MCP-only account) and the remedy (the connector, or an
# sysop granting `ui`). Self-contained so it renders even if a layout/theme is
# broken.
sub _serve_manager_forbidden {
    my ( $sv, $auth_user ) = @_;
    my $manager_path = $sv->{manager_path} || '/manager';
    my $site         = _esc_html( $sv->{site_name} // 'this site' );
    my $who          = _esc_html($auth_user);
    $ACCESS_REC{s} //= 403;    # SM140
                               # SM381: through output_page, like every other refusal.
    my $body = <<"HTML";
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Manager access not permitted</title></head>
<body style="font-family:system-ui,sans-serif;max-width:520px;margin:3em auto;padding:0 1em;line-height:1.5;">
<h1 style="font-size:1.3rem;">Manager access not permitted</h1>
<p>You are signed in to $site as <strong>$who</strong>, but this account is not
permitted to use the manager interface.</p>
<p>This is normal for an API / MCP account: connect your AI assistant through the
<em>connector</em> rather than the browser manager.</p>
<p>If you should have manager access, ask a sysop to grant your group the
<strong>ui</strong> capability on the Groups page. You can
<a href="/logout">sign out</a> in the meantime.</p>
</body></html>
HTML
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '403 Forbidden' );
}

sub serve_403 {
    my ($auth_result) = @_;

    # SM381: THE DOMAIN'S CONTENT ROOT, and through output_page.
    #
    # Two defects, both of which SM253 already fixed for the 404 and neither of
    # which was carried across:
    #
    #   the ROOT   _system_page_md was called with no content root and the cache
    #              slot was hard-coded to $DOCROOT, so on a multi-domain
    #              instance domain B's 403 was RENDERED INTO domain A's docroot
    #              and then served to both. One site's branding and navigation
    #              shown to a visitor refused on another.
    #   the HEADERS this printed its own status line and content type, so the
    #              two responses a scanner is most likely to reach carried no
    #              nosniff, no frame options, no HSTS and no CSP. The comment on
    #              _security_headers claimed every response path called it; it
    #              was not true of these two.
    my $croot   = _request_croot();
    my $md_path = _system_page_md( '403', $croot ) // "$DOCROOT/403.md";    # SM201

    $ACCESS_REC{s} //= 403;    # SM140
    $ACCESS_REC{ar} = 1;       # SM223: an ACCESS refusal, not a missing page
    binmode( STDOUT, ':utf8' );

    if ( -f $md_path ) {
        my $html_path = "$croot/403.html";
        my $page      = process_md( $md_path, $html_path, ( stat($md_path) )[9], {} );

        # SM371: an error page is not the canonical version of anything, and the
        # cached file the front end serves at 403.html must not say otherwise.
        $page = _sanitise_not_found($page);
        _rewrite_if_changed( $html_path, $page ) if -f $html_path;

        # SM381: through output_page, which carries the baseline header set and
        # records the byte count for analytics. no-store/private is what
        # output_page already emits for an auth-protected response, which this
        # is by definition.
        return output_page( $page, 'text/html; charset=utf-8', undef, 1,
            '403 Forbidden' );
    }
    # SM381: the bare fallback goes through output_page too. It is the path a
    # site reaches before 403.md exists - a fresh install - so leaving it
    # printing its own headers would mean the responses least likely to be
    # noticed are the ones without the header set.
    my $lang = _chrome_lang();
    my $body
        = qq{<!DOCTYPE html><html lang="$lang"><head><meta charset="utf-8">}
        . '<title>403 Forbidden</title></head><body>'
        . '<h1>' . _chrome('forbidden.title') . '</h1>'
        . '<p>'
        . (
        ( ( $auth_result->{auth_denied_reason} // '' ) eq 'insufficient_groups' )
        ? _chrome('forbidden.insufficient')
        : _chrome('auth.required')
        )
        . '</p></body></html>';
    return output_page( $body, 'text/html; charset=utf-8', undef, 1,
        '403 Forbidden' );
}

# --- Payment ---

our %PAYMENT_CONTEXT;    # populated by main(), read by render_content()
our %PREVIEW_CONTEXT;    # SM071: preview layout/theme override, set by main()

# --- Main ---

# One request, end to end: per-request state reset, main(), the SM140 access
# record, and the die-guard that turns an unhandled error into a proper 500
# (previously a headerless crash). Shared verbatim by the single-shot CGI
# path and every FastCGI loop iteration (SM142) - state hygiene lives HERE,
# not at file scope, so a persistent worker cannot leak between requests.
sub handle_one_request {
    reset_request_state();
    # SM222 L0: an FCGI worker must re-read the registry per request.
    _reset_units();
    %ACCESS_REC   = ();
    %AUTH_CONTEXT = ();

    # SM294: when this worker is the site's front door, it routes before it
    # renders. Inside the same eval as main() so a fault in dispatch becomes the
    # same 500 rather than an unhandled die out of the accept loop.
    my $main_ok = eval {
        if ( $FRONT_DOOR && _front_door() ) {
            1;    # answered at the door; main() must not also run
        }
        else {
            main();
            1;
        }
    };
    if ( !$main_ok ) {
        log_event( 'ERROR', $ENV{REDIRECT_URL} // '-', 'unhandled error',
            error => "$@" );
        if ( !defined $ACCESS_REC{s} ) {    # nothing emitted yet - answer 500
            $ACCESS_REC{s} = 500;
            print "Status: 500 Internal Server Error\n";
            print "$_\n" for _security_headers();    # SM381
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
#
# SM890: WHICH OF THE TWO THIS IS, kept where the branch is taken. Nothing a
# request carries named the backend it came from, so an outside reader asking
# "is this a pooled worker still holding the old engine?" - the decisive
# question in two releases running - had to infer it. Set here rather than
# derived later because this is the only place that KNOWS: a conf file's
# existence would say what the host intended, and a header set by the front
# proxy answers about the proxy (SM283).
my $RUNTIME = 'cgi';

my $_fcgi = eval { require FCGI; FCGI::Request() };
if ( $_fcgi && $_fcgi->IsFastCGI() ) {
    $RUNTIME = 'pool';
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

# The accessor exists because the request handlers are compiled ABOVE this
# point and so cannot see the lexical - the same shape _lazysite_version() has
# for $LAZYSITE_VERSION. Only ever 'pool' or 'cgi'; a value that has not been
# through here is a bug, not a third state.
sub _runtime { return $RUNTIME }

# Parse the request's query string into a hash of name => value.
# Values are URL-decoded and UTF-8 decoded, and returned RAW - exactly what
# the visitor sent. Returns a hashref.
#
# SM869: RAW HERE, AND ESCAPED AT EACH PLACE A VALUE IS EMITTED. This hash used
# to be HTML-escaped here, because it was also the template stash - which made
# it the wrong input for every other consumer. The form prefill sink had to know
# its input arrived pre-escaped and skip its own escape (SM868), a safety held
# by this function, two thousand lines from the sink. Now:
#
#   - the stash escapes ITS copy where query/params enter it (render_content,
#     via _esc_query_stash) - SM709's single point, as for auth_* and page_*;
#   - %RENDER_QUERY carries these raw values, for the engine, never for output;
#   - every sink that emits a value escapes it for its own context.
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
    return if $proxy_trusted eq 'true';

    # SM960: THE HEADERS check_auth ACTUALLY READS. auth_header_user and its three
    # siblings rename the identity headers for a proxy (the docs' example is
    # Remote-User), and this gate stripped only the fixed X-Remote-* names - so
    # with a custom name configured and no auth_proxy_trusted, a header any
    # visitor sends passed a page gate. The built-in auth wrapper vouches for
    # X-Remote-* alone, so a custom name is stripped behind it too: only a
    # trusted proxy (auth_proxy_trusted: true) may supply one.
    my @custom;
    # SM972: and the two PAYMENT header names (payment_header_verified/_payer) -
    # the same shape: a custom name for a header the paid-content gate believes.
    for my $k (
        qw(auth_header_user auth_header_name auth_header_email auth_header_groups
        payment_header_verified payment_header_payer)
        )
    {
        my $h = $sv{$k};
        next unless defined $h && length $h;
        ( my $e = 'HTTP_' . uc $h ) =~ s/-/_/g;
        push @custom, $e
            unless $e =~ /\AHTTP_X_(?:REMOTE_(?:USER|NAME|EMAIL|GROUPS)|PAYMENT_(?:VERIFIED|PAYER))\z/x;
    }
    for my $e (@custom) {
        next unless defined $ENV{$e};
        log_event( 'WARN', $uri,
            'untrusted header ignored - a custom auth_header_*/payment_header_* name needs auth_proxy_trusted: true',
            header => $e );
        delete $ENV{$e};
    }
    return if $auth_trusted eq '1';

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
        # An AUTHENTICATED account that lacks the `ui` capability (an MCP/API-only
        # account, or one whose groups were changed to drop manager access) must
        # NOT be redirected to /login: /login sees the still-valid session and
        # bounces straight back here - the login LOOP the field hit after an
        # account was moved into the mcp group. Serve a clear terminal message
        # naming the cause instead of looping. (SM127 separation is working; this
        # is the missing UX for it.)
        if ( $auth_user ne '' ) {
            _serve_manager_forbidden( \%sv, $auth_user );
            return 1;
        }
        # UNAUTHENTICATED (a stale/invalid session - e.g. the cookie-signing secret
        # changed, or the session was revoked): clear the JS lzs_session marker so
        # /login shows the sign-in form instead of a marker-driven "you are already
        # signed in" screen that would itself trap a loop (SM188), then send them
        # to the login form.
        my $redirect = $sv{auth_redirect} || '/login';
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        print "$_\r\n" for _security_headers();                # SM381
        print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
        print "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0"
            . ( $ENV{HTTPS} ? "; Secure" : "" ) . "\r\n";
        print "Location: $redirect?next=" . uri_encode($uri) . "\r\n\r\n";
        return 1;
    }

    # /manager -> /manager/ for directory index
    if ( $uri eq $manager_path ) {
        binmode( STDOUT, ':utf8' );
        print "Status: 302 Found\r\n";
        print "$_\r\n" for _security_headers();                # SM381
        print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
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

    # SM536: and on the nav file. Navigation is baked into every render, and
    # nothing above sees a nav write: the manager's sweep drops the .html
    # files but a DAV PUT does not (its per-page invalidation is a no-op for
    # a non-.md path), and a per-domain nav-<site>.conf (SM443) reached no
    # sweep at all. Keyed on the file's mtime, like the conf, so every writer
    # is covered at once - DAV, manager, a shell - and the check guards the
    # file THIS host's render actually used (resolve_site_vars is memoised per
    # host, so this is a lookup, not a second parse).
    my $nav_mtime = ( stat _nav_file_for( { resolve_site_vars() } ) )[9] // 0;
    $conf_mtime = $nav_mtime if $nav_mtime > $conf_mtime;

    # SM812: and on the section index pages above it. A theme set on a section's
    # index dresses every page beneath it, and each of those caches as its own
    # .html with the resolved stylesheet baked in - so a section index changing
    # must stale them, as the nav file does for every page. EVERY ancestor
    # counts, not only one that names a theme today: the edit that REMOVES the
    # key leaves nothing to find. (Deleting the index outright leaves no mtime
    # at all; the pages beneath keep their render until their own next change or
    # a cache clear.)
    for my $idx ( _section_indexes($md_path) ) {
        my $m = ( stat $idx )[9] // 0;
        $conf_mtime = $m if $m > $conf_mtime;
    }

    # SM886: and on the ENGINE. See _engine_mtime for why the install state is
    # the file to watch. This is the fourth dependency of a render and the only
    # one that was never here, which is why an upgrade could leave a homepage
    # serving a build two releases old. It belongs in this running max because
    # BOTH cache slots are judged here - the primary host's sibling .html and
    # the alias hosts' entries under cache/hosts - so one line covers the slot
    # install.pl's sweep reaches and the slot it does not.
    my $engine_mtime = _engine_mtime();
    $conf_mtime = $engine_mtime if $engine_mtime > $conf_mtime;

    # SM311: a page may also depend on files it READS - `tt_page_var` json: and
    # scan: sources. Those are neither the .md nor the conf, so editing one used
    # to leave the cache "fresh" and serve the previous render indefinitely.
    #
    # Only pages that declare the block pay for this: the peek is already done
    # for the TTL and is cached per (path, mtime), so a page without sources
    # costs one hash lookup. A page with them costs one small sequential read
    # plus a stat per recorded path, short-circuiting on the first one that is
    # newer.
    # SM888 A2: OR A RECORD ALREADY EXISTS.
    #
    # The front-matter peek answers for the two source kinds SM311 built - a
    # `tt_page_var:` block declares them - and cannot answer for a third: an
    # `::: include` is in the BODY, and the peek deliberately stops at the
    # front matter because 200 pages a scan later that read is not free. So a
    # page whose only external read was a partial declared nothing here, its
    # record was written and never consulted, and an edited partial updated
    # nothing.
    #
    # BOTH, not either alone. The declaration keeps the safe direction for a
    # declaring page whose record is MISSING - no record means unproven, which
    # re-renders and rewrites it - and the record's existence covers the
    # include case, where nothing in the front matter could have said so.
    #
    # What this still cannot see: an include-only page whose .deps was deleted
    # while its .html was left in place. There is no such operation - clearing
    # the cache removes the render, which re-renders and rewrites the record -
    # so the gap needs somebody deleting one cache file and not its sibling by
    # hand. Named rather than papered over.
    my $deps_ok = 1;
    if ( _peek_md($md_path)->{tt_deps} || -f deps_cache_path($base) ) {
        $deps_ok = deps_fresh( $base, $html_stat->[9] );
    }

    if ( $deps_ok
        && $html_stat->[9] >= $md_stat->[9]
        && $html_stat->[9] >= $conf_mtime )
    {
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
    #
    # SM311: this branch deliberately does NOT consult the dependency record, and
    # the omission is a decision rather than an oversight.
    #
    # A `ttl:` is an explicit statement by the author that this page may be up to
    # N seconds out of date. It already lets an edit to the page's OWN source
    # wait out the window, so making a data-file edit jump the queue would be
    # inconsistent in the author's favour on one input and against it on another.
    #
    # It also matters for `url:` sources, which have no local mtime and so can
    # never be proven fresh. Gating this branch on the record would re-render a
    # url-backed page on EVERY request and hammer the remote - so the TTL is not
    # merely compatible with a live source, it is the only freshness mechanism
    # such a page has. That is why `deps_fresh` reports a live source as unproven
    # rather than as an error: the answer belongs here, not there.
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

    # SM268 01-L2: REQUEST_URI is percent-ENCODED; REDIRECT_URL is not.
    #
    # Apache does not set REDIRECT_* for a rewrite in server context, which is
    # exactly where the SM223 rules live - so on a site with an ACL store EVERY
    # existing static takes the REQUEST_URI branch, and the raw encoded path was
    # never decoded. Turning on the first ACL entry therefore 404'd every asset
    # whose filename contains a space, `+`, `&` or a non-ASCII character,
    # site-wide, and it reads as "SM223 broke my site" rather than as an
    # encoding bug.
    #
    # Decoded BEFORE sanitise_uri and the \0 / .. / ^/ rejections below, never
    # after: decoding afterwards would let `%2e%2e%2f` slip past a check that
    # ran on the encoded form. The query string is split off first, so a `?` in
    # a filename cannot be manufactured by decoding.
    my $uri = $ENV{REDIRECT_URL} || '';
    unless ( length $uri ) {
        $uri = $ENV{REQUEST_URI} // '';
        my $q = ( $uri =~ s/\?(.*)\z//s ) ? $1 : undef;
        $uri =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        $uri .= "?$q" if defined $q;
    }

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
        # SM381: the header set here too. A cross-origin-readable endpoint is a
        # strange one to leave without nosniff.
        print "Status: 200 OK\r\n";
        print "Content-Type: application/json; charset=utf-8\r\n";
        print "$_\r\n" for _security_headers();
        print "Access-Control-Allow-Origin: *\r\n";
        print "Cache-Control: no-store\r\n\r\n";

        # SM434: WHAT IS RUNNING, from the thing that is running.
        #
        # Nothing served reported this, and two agents in a row reached for
        # the <meta name="generator"> version instead - which answers a
        # different question and answers it correctly. That meta is baked in
        # AT RENDER TIME and cached with the page, so it reports the build
        # that PRODUCED the artefact. A page rendered under 0.10.18 and still
        # cached on a 0.10.19 instance is not stale; it is accurately
        # describing itself.
        #
        # The misreading was durable because an upgrade re-renders every
        # SHIPPED page while PRESERVING the sysop's own index.md - so the
        # one page keeping an old render is the homepage, which is also the
        # first page anyone checks after an upgrade.
        #
        # This endpoint is read live and never cached (no-store above), so it
        # can answer honestly. Read from the install state, which is what the
        # installer writes and therefore what is actually deployed - not from
        # the VERSION file in a source tree that may not be the one serving.
        my $ver = _lazysite_version();
        $ver = '' unless defined $ver && $ver =~ /\A[0-9A-Za-z._-]{0,32}\z/;

        # SM890: AND WHAT IS SERVING IT. Ruled 2026-09-15 that a site's hosting
        # shape may be public: the site most likely to need diagnosing remotely
        # is the one nobody holds a credential for, so a partner-only answer
        # would have been readable exactly where it is least needed.
        #
        # MEASURED, NOT CONFIGURED - this is the process answering for itself,
        # which is the one reading that cannot drift from what is true.
        #
        # TWO VALUES, NOT THE THREE THE FILING PROPOSED. `lazysited@`, the
        # persistent runtime, binds no socket and serves no request; it is the
        # background job supervisor. A field that says what answered this
        # request can never return it, and pretending otherwise would put a
        # value in the enum that nothing can ever produce. Whether the daemon
        # is armed is a separate fact with a separate reader - `lazysite check`
        # reports it (SM893 P3).
        my $runtime = _runtime();
        print qq({"ok":1,"instance":"$inst","host":"$rhost",)
            . qq("version":"$ver","runtime":"$runtime"});
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

    # SM190: the AI-partner bootstrap (.well-known/ai-partner) is CODE-SERVED from
    # the live config so it advertises ONLY the endpoints whose service killswitch
    # is on - it cannot drift the way a static page can (which named endpoints that
    # 404 and got render-cached). Served BEFORE the render/cache path (so it also
    # shadows any legacy static ai-partner.md) and no-store, so an operator's later
    # service toggle is reflected immediately. CORS-open like the instance marker,
    # for a browser-side onboarding probe. Body is JSON::PP-encoded, always valid.
    if ( $uri =~ m{^ /\.well-known/ai-partner (?:\.\w+)? \z}x ) {
        my %sv  = resolve_site_vars();
        my $doc = _ai_partner_doc( $sv{site_url} // '' );
        binmode( STDOUT, ':utf8' );
        print "Status: 200 OK\r\n";
        print "Content-Type: application/json; charset=utf-8\r\n";
        print "$_\r\n" for _security_headers();    # SM381
        print "Access-Control-Allow-Origin: *\r\n";
        print "Cache-Control: no-store\r\n\r\n";
        print JSON::PP->new->canonical->pretty->encode($doc);
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
        # docs/feature-requests/archive/SM110-domain-aliases.md.
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

    my $md_path = "$croot/$base.md";
    # SM201: a system page (login / claim / error) whose content-root copy is
    # absent falls back to the docroot root, then the protected engine default -
    # so a deleted or never-seeded copy self-heals instead of 404ing.
    if ( !-f $md_path && ( my $sys = _system_page_md( $base, $croot ) ) ) {
        $md_path = $sys;
    }
    my $url_path  = "$croot/$base.url";
    my $html_path = "$croot/$base.html";

    # SM286: a page whose source lives in the private store renders from there,
    # and its cache goes there WITH it.
    #
    # The cache is the dangerous half. A gated page that renders its .html
    # sibling into the docroot has republished exactly what the gate was
    # protecting, in a file the front end serves without asking anything - the
    # SM283 shape, arriving by a different route. So the cache follows the
    # SOURCE's tree rather than being resolved on its own existence, which it
    # does not have on a first render.
    for my $p ( \$md_path, \$url_path ) {
        my $resolved = _content_abs($$p);
        next if $resolved eq $$p;
        $$p        = $resolved;
        $html_path = _private_twin("$croot/$base.html");
    }

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
    # SM268 H11: the section gate runs for the RESOLVED TARGET, whatever its
    # source, and outside the @md_stat block.
    #
    # It used to sit inside `if (@md_stat)`, so a `.url` page - which has no .md -
    # was never gated, and neither was its render cache. SM181's claim is "every
    # page under /upcoming/ requires an editor"; a .url page under that prefix was
    # public. `.url` pages have never been coverable by `auth:` either, for the
    # same structural reason, so a sysop had no way at all to protect one.
    #
    # Gate on the source that actually exists, so the decision is made once for
    # whatever the request resolves to.
    {
        my $gate_src =
            @md_stat       ? $md_path
            : -f $url_path ? $url_path
            :                undef;
        if ( defined $gate_src ) {
            return if _acl_refused( $gate_src, $uri );
            # Governed => per-identity => never written to or served from the
            # shared render cache.
            $auth_protected = 1 if _acl_governed($gate_src);
        }
    }

    if (@md_stat) {
        # SM181: a folder ACL entry gates the whole section, PAGES included.
        #
        # Access control was per-page or whole-site with nothing in between: to
        # hold back an unfinished section a sysop had to stamp `auth:` on
        # every page in it, and to release it, unstamp every page. There was no
        # atomic "publish the section now".
        #
        # A folder entry in acls.json is that missing middle, and it is the same
        # entry SM223 already uses for static files - so one rule covers the
        # section's pages AND the images and PDFs inside it, which is exactly the
        # static-asset caveat SM181 left open. Deleting the entry publishes the
        # whole subtree in one act.
        #
        # It runs BEFORE check_auth deliberately: a section gate must not be
        # overridable by a page inside the section declaring `auth: none`. The
        # narrower rule wins on PATH depth (longest match), not on which
        # mechanism declared it.
        return if _acl_refused( $md_path, $uri );
        # A page under a governed prefix is per-identity, so it must never be
        # written to or served from the shared HTML cache.
        $auth_protected = 1 if _acl_governed($md_path);

        $auth_peek      = peek_auth($md_path);
        %site_vars_peek = resolve_site_vars();
        $auth_result    = check_auth( $uri, $auth_peek, \%site_vars_peek );

        if ( $auth_result->{redirect} ) {
            # SM223: an access refusal, not an ordinary redirect. Flagged so the
            # visitor report can separate "turned away" from every other 302.
            $ACCESS_REC{ar} = 1;
            binmode( STDOUT, ':utf8' );
            print "Status: 302 Found\r\n";
            print "$_\r\n" for _security_headers();                # SM381
            print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
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
        #
        # SM743: auth_name gets its FIRST producer on the native auth path.
        #
        # It had exactly one before - the X-Remote-Name header, set by an
        # upstream proxy doing external authentication - and nothing anywhere
        # set $auth_result->{auth_name}, so on a site using lazysite's own auth
        # this was permanently ''. Meanwhile the admin bar is written to prefer
        # a display name over the login, and `display_name` was a stored,
        # editable setting whose only reader in the whole tree was the users
        # tool that wrote it. An operator could set it, watch it save, and never
        # see it anywhere.
        #
        # The header still WINS where one is present: a deployment behind
        # header auth has an upstream that knows who this is, and its answer
        # should not be second-guessed by a local record.
        #
        # RAW, not escaped. Both sinks escape - SM709 at the point the TT stash
        # is built, and again at the admin bar, which reads %AUTH_CONTEXT
        # directly - so escaping here would double-escape and put `O&#39;Brien`
        # on the page. This is also what finally makes SM709's escaping
        # reachable: it has guarded a value nothing on our fleet could populate.
        my $native_name = $auth_result->{auth_name};
        if ( !defined $native_name || !length $native_name ) {
            $native_name = _display_name_for( $auth_result->{auth_user} );
        }

        %AUTH_CONTEXT = (
            authenticated => $auth_result->{authenticated} // 0,
            auth_user     => $auth_result->{auth_user}     // '',
            auth_name     => $native_name                  // '',
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

    # SM825: THE SOURCE ALTERNATE, answered HERE and nowhere else.
    #
    # After every gate - the section ACL, the page's `auth:`, and payment - so
    # the alternate is refused on exactly the terms the rendering is refused on,
    # with no second copy of the decision to keep in step.
    #
    # And BEFORE try_serve_cache, which is load-bearing rather than tidy:
    # that cache is keyed on $base, and sanitise_uri has already collapsed
    # `/page` and `/page.md` to the SAME $base. A markdown body written into
    # that slot would afterwards be served as the page to every visitor until
    # it expired, and a markdown body read out of it would be served as the
    # alternate. One slot cannot hold two representations, so the alternate
    # neither reads nor writes it.
    if ( @md_stat && _wants_source_alternate($uri) ) {
        my $src = _source_alternate($md_path);
        if ( defined $src ) {
            $ACCESS_REC{s} = 200;
            binmode( STDOUT, ':utf8' );
            print "Status: 200 OK\r\n";
            print "Content-Type: text/markdown; charset=utf-8\r\n";
            print "$_\r\n" for _security_headers();    # SM381

            # The rendering is the thing to index; the alternate is the same
            # words for a reader that wants them without markup, so it must not
            # compete with the page in a search index.
            print "X-Robots-Tag: noindex\r\n";
            # Never cached at the edge either, for the same reason the engine
            # cache is bypassed above: one URL family, two representations.
            print "Cache-Control: no-store\r\n\r\n";
            print $src;
            return;
        }
        # Unreadable: fall through and let the render path answer, which will
        # say what it says about a page it also cannot read. An empty 200 would
        # be the alternate claiming the page has no prose.
        log_event( 'WARN', $uri,
            'source alternate requested but the page could not be read',
            page => $md_path );
    }

    # Combined protection flag. auth_protected / payment_protected come
    # from front-matter; is_auth_surface() covers login/logout, which
    # ship with `auth: none` but must never be cached because they
    # embed per-request TT variables (query.next etc.).
    #
    # SM857: and a page binding `db:<table>(mine)`, which renders the signed-in
    # viewer's own rows. A shared cache would serve one person's rows to the
    # next, so it takes exactly the gated page's treatment: never read from or
    # written to the page cache, no-store on output. `_protected` reaching
    # process_md is also what resolve_db checks before it will apply (mine).
    my $per_viewer = ( @md_stat && _peek_md($md_path)->{db_mine} ) ? 1 : 0;
    my $protected  = $auth_protected || $payment_protected || $per_viewer
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

    # SM969: A FORM OUTCOME IS THIS REQUEST'S, NEVER THE PAGE'S. The banner reads
    # `form=` and `outcome=` from the query string itself (convert_fenced_form),
    # and neither is a declared query_params name - so the request counted as
    # query-free: it was answered from the cache (the visitor did not see their
    # outcome), and when the cache was cold the render WAS the cache. One
    # visitor's link text then stood on the page, in the alert style, for every
    # later visitor. The same treatment as `nocache: true`, for this request only.
    if ( exists $query_params{form} && exists $query_params{outcome} ) {
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
        if ( !_path_under_content( $real, $croot ) ) {
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
        # SM311: record what this render read, beside the render itself. Written
        # AFTER process_md, because that is what resolved the sources - a `scan:`
        # glob's matches are not knowable from the front matter alone.
        write_deps($base) unless $protected;
        log_event( 'INFO', $uri, 'page rendered' );
        # Admin bar added here (post-cache, per-viewer), not inside the cached page.
        output_page( _inject_admin_bar_live( $page, $md_path ), $ct, $ttl, $protected );
        return;
    }

    # Found .url - fetch remote content
    if ( -f $url_path ) {
        my $real = realpath($url_path);
        if ( !_path_under_content( $real, $croot ) ) {
            not_found($uri);
            return;
        }
        # SM837: a failed fetch answers with its own status, never a 200.
        my ( $page, $status ) = process_url( $url_path, $html_path, ( stat($url_path) )[9] );
        my $ct = peek_content_type($url_path);
        write_ct( $base, $ct );
        output_page( _inject_admin_bar_live( $page, $url_path ), $ct, undef, undef, $status );
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
            # SM223: a source-less static is reachable by anyone who knows its
            # path, so the ACL is the only thing that can protect it. No entry
            # means served, exactly as before.
            return if _acl_refused( $static_html_path, $uri );
            my $ct = read_ct($base) || 'text/html; charset=utf-8';
            log_event( 'INFO', $uri, 'static-html fallback (no .md source)' );
            # A file that carries an ACL entry is per-identity, so it must not be
            # stored by a cache that does not know who asked.
            output_page( read_file($static_html_path), $ct, undef,
                _acl_governed($static_html_path) );
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
    #
    # SM223: on a site that HAS an ACL store the front end now routes existing
    # statics here, because a file the web server hands over directly cannot be
    # gated by anything the engine does. So the primary docroot has to be
    # servable from here too. A site with no acls.json keeps the previous
    # condition exactly, and its statics are still served directly by the front
    # end - the cost of the indirection falls only on sites that asked for it.
    if ( ( $croot ne $DOCROOT || -f "$LAZYSITE_DIR/auth/acls.json" )
        && _serve_content_static( $croot, $base, $uri ) )
    {
        return;
    }

    # SM382: THE ENGINE'S OWN ASSETS ARE NOT SITE CONTENT, so they resolve from
    # the DOCROOT even for a domain with its own content root.
    #
    # SM352 moved the engine's chrome out of inline blocks and into
    # /assets/lazysite-chrome.{css,js}, which ship into the docroot. Static
    # resolution is content-root scoped and refuses anything outside it, so on a
    # content-rooted secondary domain the bundle 404s - and the frame
    # suppression, the SM099 auth-control sync and the form submit and
    # multi-step handling all stop, silently, because the script never loads.
    # Measured on a two-root fixture: 200 on the primary, 404 on the secondary.
    #
    # NARROW ON PURPOSE. This is an explicit list of engine-owned paths, not a
    # general fallback to the docroot - a general one would be a way out of the
    # content-root confinement that SM151 exists to enforce, which is the
    # opposite of what this file spends its effort on.
    if ( $croot ne $DOCROOT && _is_engine_asset($uri) ) {
        return if _serve_content_static( $DOCROOT, $base, $uri );
    }

    # SM293 step 3: a generated registry (sitemap.xml, llms.txt, the feeds) is
    # served from here rather than written into the document root. Before the
    # alias lookup and the 404, because these are real URLs the site publishes -
    # and after the static handler, so a hand-authored sitemap.xml an operator
    # put in their content still wins.
    return if _serve_registry($uri);

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

        # SM482: THE QUERY STRING TRAVELS WITH THE REDIRECT.
        #
        # It was dropped, and on a live hosting site that discarded the only
        # thing the URL was carrying: a customer whose service is down lands on
        # `/forms/service-report.shtml?https://their-site/`, and the page reads
        # the query string to say WHICH service. The alias resolved the path
        # and threw the payload away, so the form no longer knew what it was
        # reporting on.
        #
        # A redirect that keeps the path and discards the parameters is not the
        # same URL: `?page=3`, `?utm_source=...`, a search term and a session
        # marker all vanish, and every one of them is somebody's link. This is
        # what a 301 is expected to preserve, and every other redirect in this
        # file already does.
        #
        # THE ALIAS TARGET MAY CARRY ITS OWN QUERY, since it is an author's
        # front-matter string. When it does, the request's parameters are
        # APPENDED to it rather than replacing it - the author's are part of
        # where they are sending people, and the visitor's are what they
        # brought with them.
        if ( defined $ENV{QUERY_STRING} && length $ENV{QUERY_STRING} ) {
            ( my $qs = $ENV{QUERY_STRING} ) =~ s/[\r\n]//g;
            $loc .= ( $loc =~ /\?/ ? '&' : '?' ) . $qs;
        }

        my $canon_h = _esc_html($loc);
        print "Status: $code $phrase\r\n";
        print "$_\r\n" for _security_headers();    # SM381
        print "Location: $loc\r\n";
        print "Content-Type: text/html; charset=utf-8\r\n\r\n";
        print qq(<!DOCTYPE html><html><body>Moved to )
            . qq(<a href="$canon_h">$canon_h</a></body></html>\n);
        return;
    }

    # SM802: the URL remapper. LAST before the 404, and after the site's own
    # aliases, so a real page and an alias both win - a migration rule can cover
    # a link nobody else answers and can never shadow site content.
    return if _remap_redirect();

    # No source found - serve 404 page
    not_found($uri);
}

# SM151 §7: the directories declared as content roots in lazysite.conf (the base
# `content_root:` and every `alias.<host>.content_root:`), as absolute paths
# under the docroot. A page scan skips any directory in this set that is not its
# own scan root, so a bare-docroot host's sitemap/search never enumerates a
# client subtree, and no domain lists a nested sub-domain's pages. Paths are the
# plain "$DOCROOT/<rel>" string form (not realpath) to match the scan walk,
# which builds "$dir/$entry" from the docroot down; symlinked dirs are already
# skipped separately, so no symlink normalisation is needed here.
{
    # PO-3: memoised on the conf mtime. Every scan and every registry walk asked
    # for this set, and each ask re-read and re-parsed lazysite.conf.
    #
    # EQUIVALENCE. The answer is a pure function of the conf file's text and
    # $DOCROOT, neither of which this process changes, so within one request the
    # memo returns exactly the hash a re-read would have built. The bare block is
    # the file's existing idiom for a lexical shared with one sub, and the key is
    # the SAME signature resolve_site_vars memoises on a few thousand lines down
    # (P-2): the conf's mtime, so an edit between requests re-reads even in a
    # persistent worker that never calls reset_request_state, and a second edit
    # inside the same clock second is stale to exactly the degree the site vars
    # already are. A missing conf keys as -1 and still answers with the empty set.
    my %_droots_cache;
    my $_droots_sig    = '';
    my $_droots_loaded = 0;

    sub _declared_content_roots {
        my $sig = -f $CONF_FILE ? ( ( stat $CONF_FILE )[9] // 0 ) : -1;
        return {%_droots_cache} if $_droots_loaded && $sig eq $_droots_sig;

        my %roots;
        if ( -f $CONF_FILE ) {
            my $text = read_file($CONF_FILE);
            if ( defined $text ) {
                while ( $text =~ /^(?:alias\.\S+\.)?content_root\s*:\s*(.+?)\s*$/mg ) {
                    ( my $rel = $1 ) =~ s{^/+|/+$}{}g;
                    next unless length $rel;
                    next if $rel =~ m{(?:^|/)\.\.(?:/|$)};    # ignore traversal shapes
                    $roots{"$DOCROOT/$rel"} = 1;
                }
            }
        }

        # A COPY out, never the memo itself: the old sub handed back a hash no
        # other caller held, and a caller that decided to write to what it got
        # must not reach the next caller's answer.
        %_droots_cache  = %roots;
        $_droots_sig    = $sig;
        $_droots_loaded = 1;
        return {%roots};
    }
}

# The lazy-load bootstrap, once (PR-1). The processor is module-free by design
# (ADR 0001) and carries NO global @INC bootstrap, so every site that requires a
# Lazysite module on a cold path has to locate the module tree for itself first -
# resolve_db's comment records what happened the one time a site forgot.
#
# This is the three verbatim copies (_chrome, fetch_url, resolve_db) as one sub.
# It searches for the tree only when the module is not already loaded, exactly as
# the copies did; the require then runs unconditionally, which is what resolve_db
# already did and what the other two amounted to - a require of a loaded file is
# the same %INC lookup their `unless` performed.
sub _lazy_lib {
    my ($module) = @_;
    ( my $file = $module ) =~ s{::}{/}g;
    $file .= '.pm';
    unless ( $INC{$file} ) {
        require Cwd;
        require File::Basename;
        my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
        for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
            if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
        }
    }
    require $file;
    return 1;
}

# --- Site vars and their memo ---
#
# SM944 S14: THIS BLOCK STAYS IN THE SCRIPT while the sources around it are a
# part (lazysite-processor/sources.pm), because its `my` statements carry
# initialisers and where they run is behaviour. Here they run after the main
# flow, so the processor loaded as the tests load it (`do`, which serves one
# request) has the memo cleared once the load is done. In a part they would run
# inside the loader's BEGIN, before that request, and leave the load request's
# vars cached: rewrite the conf under the same mtime and ask again, and the part
# answers the old conf where the script answers the new. Moving it is a change
# of behaviour, not a move.
{
    # P-2: per-process memoization of resolve_site_vars(). The file now calls it
    # from twenty-odd sites - main() alone reaches it five times, and
    # render_content, update_registries, scan_pages and the layout and chrome
    # helpers each ask again - so a single request would otherwise re-read and
    # re-parse the conf many times over. Under CGI, one process = one request,
    # so the cache is request-scoped automatically.
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
            # SM436: say so when a Host matches NOTHING and the default
            # answers. This is the silent half of the defect that cost an
            # afternoon: a domain configured under a name no request carries
            # never matches, so every request falls through here and the
            # visitor is served the PRIMARY's site under someone else's name.
            # The engine cannot know it is disappointing anyone - a
            # non-matching Host is indistinguishable from a genuinely unknown
            # one, which is the correct and documented behaviour for traffic
            # arriving from outside.
            #
            # So it is logged rather than refused, and only when aliases are
            # CONFIGURED at all: on an instance declaring alias_hosts, a Host
            # that matches none of them is worth one greppable line. A
            # single-site instance never reaches this branch.
            if ( length $req_host && !$declared{$req_host} ) {
                log_event( 'INFO', $ENV{REDIRECT_URL} // '-',
                    'host matched no configured domain - serving the default site',
                    host => $req_host );
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

        $vars{nav} = parse_nav( _nav_file_for( \%vars ) );

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

# --- Utilities ---

sub read_file {
    my ($path) = @_;
    open( my $fh, '<:utf8', $path ) or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# SM917: the processor's own copy of Lazysite::Util::cannot_read.
#
# WHY A COPY. ADR 0001: the render path loads no modules, so every decision the
# processor shares with the rest of the engine it carries itself, and a lint holds
# the two in step (t/lint/160). Calling Util here would put a module load on the
# hot path for one four-line sub, which is the trade ADR 0001 already ruled on.
#
# THE CONTRACT, identical to Util's so a reader can move between them: returns
# undef always, so it can be the whole failure branch of an open. Absent is NOT a
# fault and is silent - ENOENT returns before anything is logged, because a file
# a site has never had is a real answer and warning about it teaches an operator
# to ignore warnings. Anything else is logged with the path, the errno and the
# unix user, which are the three facts a sysop needs and which SM766's version of
# this bug threw away.
#
# $! IS READ BEFORE getpwuid, which is free to reset it - SM768 logged a blank
# error field for exactly that reason, and it is the one field the rule exists to
# carry.
sub _cannot_read {
    my ( $what, $path ) = @_;
    return undef if $!{ENOENT};
    my $err = "$!";
    my ($who) = getpwuid($>);
    log_event( 'WARN', 'store', "cannot read $what - it exists and this process cannot open it",
        file => $path, error => $err, unix_user => ( $who // $> ) );
    return undef;
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
