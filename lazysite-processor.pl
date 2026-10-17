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
    for my $part (qw(front-matter.pm oembed.pm remap.pm components.pm ct-cache.pm gates.pm access-log.pm front-door.pm include.pm forms.pm output.pm request.pm sources.pm registries.pm render.pm layout.pm pipeline.pm acl.pm auth.pm)) {
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
#
# SM1048 (P-8): and the rest of the sign-in flow. A domain whose content root
# had no forgot.md answered /forgot - the login page's own "forgotten your
# password" link - with a 404, and /logout, where signing out lands, the same.
# Both stay seeded at the primary's root (SM939 keeps them on a bare install);
# their protected defaults are copies of those (t/integration/207 holds them
# equal).
#
# SM1043 (SM1034 phase 1a): `account` - the member's own account page - joins
# the set, so it renders in each domain's own layout and theme and restores
# itself if deleted. `account_page: disabled` in lazysite.conf withdraws the
# engine default (the page answers 404 unless a site wrote its own) and turns
# its me-* actions off with it.
my %SYSTEM_PAGES = map { $_ => 1 } qw(login claim forgot logout account 402 403 404);

sub _system_page_md {
    my ( $base, $croot ) = @_;
    return undef unless defined $base && $SYSTEM_PAGES{$base};
    return undef if $base eq 'account' && !_account_page_enabled();
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

# SM1043: the account_page switch, for the account system page above.
# The switch is read here by the processor's own copy of
# Lazysite::Util::account_page_enabled - ADR 0001: the render path loads no
# modules - and t/unit/account/01 holds the two to one answer for every value.
sub _account_page_enabled {
    open my $fh, '<', $CONF_FILE or return 1;
    my $on = 1;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\s*account_page\s*:\s*(\S+)\s*$/;
        $on = ( $1 =~ /\A(?:disabled|off|no|false|0)\z/i ) ? 0 : 1;
        last;
    }
    close $fh;
    return $on;
}

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
our $DRAFT_BYTES;      # SM1030: a draft's source, read from STDIN (request.pm)
our $DRAFT_MD;         # SM1030: the page path that draft stands in for
our $ACL_MAP_CACHE;    # SM268 H13: acls.json parsed at most once per request -
                      # a scan asks the read decision up to 200 times. undef =
                      # not loaded, 0 = load failed (fail closed), hashref = the
                       # store. reset_request_state clears it (SM973).

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
    lang lang_group      # SM179: per-host language + language-set membership
    # P16: per-domain CSP allow-lists
    csp_script_src csp_connect_src csp_img_src csp_frame_src);

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
    # SM1112: media and its captions. Reported 2026-10-16: "`.mp4` / `.webm`
    # are served as `application/octet-stream`" beside nosniff, which a strict
    # client takes at its word - a download, not a video. The same set is in
    # every content-type map the engine has (t/lint/264 holds them together).
    mp4  => 'video/mp4',
    m4v  => 'video/mp4',
    webm => 'video/webm',
    ogv  => 'video/ogg',
    mp3  => 'audio/mpeg',
    ogg  => 'audio/ogg',
    oga  => 'audio/ogg',
    # opus is Ogg Opus, as Apache's mime.types has it.
    opus => 'audio/ogg',
    wav  => 'audio/wav',
    m4a  => 'audio/mp4',
    flac => 'audio/flac',
    vtt  => 'text/vtt; charset=utf-8',
);

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
        $key                = eval { decode( 'UTF-8', $key, 1 ) } // $key;
        $val                = eval { decode( 'UTF-8', $val, 1 ) } // $val;
        $query_params{$key} = $val;
    }
    return \%query_params;
}

# C-1 trust gate. Strip HTTP_X_REMOTE_* and HTTP_X_PAYMENT_*
# headers from %ENV unless one of the trusted-source signals is
# present: LAZYSITE_AUTH_TRUSTED=1 (set by lazysite-auth.pl after
# cookie validation) or auth_proxy_trusted: true in lazysite.conf, from a peer in auth_proxy_trusted_from (SM1129)
# (operator opt-in for upstream auth proxies). Logs a WARN if a
# client attempted to set these directly.
sub apply_trust_gate {
    my ($uri)        = @_;
    my %sv           = resolve_site_vars();
    my $auth_trusted = $ENV{LAZYSITE_AUTH_TRUSTED} // '';

    # SM1129: the flag alone no longer vouches for a request. This is the ONE
    # reader of auth_proxy_trusted on the render path (t/lint/267): the headers
    # are believed only from a peer in auth_proxy_trusted_from, and from any other
    # peer fall through to the strip below exactly as when the flag is off. With
    # the flag on and no list, nobody is believed (the list fails closed).
    my $pid = _proxy_identity();
    return if $pid->{trusted};

    # SM960: THE HEADERS check_auth ACTUALLY READS. auth_header_user and its three
    # siblings rename the identity headers for a proxy (the docs' example is
    # Remote-User), and this gate stripped only the fixed X-Remote-* names - so
    # with a custom name configured and no auth_proxy_trusted, a header any
    # visitor sends passed a page gate. The built-in auth wrapper vouches for
    # X-Remote-* alone, so a custom name is stripped behind it too: only a
    # trusted proxy (auth_proxy_trusted: true, from a listed peer) may supply one.
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

    # SM1129: with the flag on and the peer not believed, ONE line per request
    # names the address and what the operator must change; the per-header lines
    # below say "set auth_proxy_trusted: true", which would be wrong advice here.
    my $named = 0;
    if ( $pid->{flag} ) {
        my @sent = grep { defined $ENV{$_} && length $ENV{$_} } @custom,
            ( $auth_trusted eq '1' ? () : qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS) );
        if (@sent) {
            log_event( 'WARN', $uri,
                $pid->{state} eq 'no-list'
                ? 'untrusted auth header ignored - auth_proxy_trusted is on but auth_proxy_trusted_from lists no address'
                : 'untrusted auth header ignored - the peer is not in auth_proxy_trusted_from',
                peer => $pid->{peer} );
            $named = 1;
        }
    }
    for my $e (@custom) {
        next unless defined $ENV{$e};
        log_event( 'WARN', $uri,
            'untrusted header ignored - a custom auth_header_*/payment_header_* name needs auth_proxy_trusted: true',
            header => $e )
            unless $named;
        delete $ENV{$e};
    }
    return if $auth_trusted eq '1';

    if ( $ENV{HTTP_X_REMOTE_USER} && !$named ) {
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

    # SM1030: a draft render takes the whole of its STDIN before anything is
    # printed, so the caller writing it can never wait on a reader that waits on
    # it (request.pm).
    return unless _draft_read();

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
    # SM1030: a draft renders at exactly the page its caller was allowed to
    # name, or not at all - and in place of whatever source is there.
    return unless _draft_bind($md_path);
    # SM201: a system page (login / claim / error) whose content-root copy is
    # absent falls back to the docroot root, then the protected engine default -
    # so a deleted or never-seeded copy self-heals instead of 404ing.
    if ( !defined $DRAFT_BYTES && !-f $md_path && ( my $sys = _system_page_md( $base, $croot ) ) ) {
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
    $DRAFT_MD = $md_path if defined $DRAFT_BYTES;    # SM1030: after the store resolves

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
    my @md_stat   = _draft_is($md_path) ? _draft_stat() : stat($md_path);    # SM1030

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
        # written to or served from the shared HTML cache. SM1068: governed by a
        # read list or a draft flag; a write-only rule leaves it cacheable.
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
    if ( @md_stat && !defined $DRAFT_MD && _wants_source_alternate($uri) ) {
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
    my $per_viewer = ( @md_stat && do { my $pk = _peek_md($md_path); $pk->{db_mine} || $pk->{odoo_me} } ) ? 1 : 0;
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

    # SM1030: a draft is the gated page's case and the preview cookie's: never
    # read from or written to any cache. The sinks refuse a draft request on
    # their own as well (request.pm); this keeps the render on the path that
    # writes nothing to begin with.
    if ( defined $DRAFT_MD ) {
        $protected = 1;
        $ENV{LAZYSITE_NOCACHE} = '1';
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
        my $real = _draft_is($md_path) ? _draft_real($md_path) : realpath($md_path); # SM1030
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
        # SM1069: the protected flag reaches the .url branch, as it reaches the
        # .md one. It never did, so a .url page under a read rule was answered
        # cacheable and its render read and written beside its source.
        my ( $page, $status ) = process_url( $url_path, $html_path, ( stat($url_path) )[9], $protected );
        my $ct = peek_content_type($url_path);
        write_ct( $base, $ct ) unless $protected;
        output_page( _inject_admin_bar_live( $page, $url_path ), $ct, undef, $protected, $status );
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

# --- Declared content roots and the lazy-load bootstrap ---
#
# SM944 S18: THESE TWO STAY IN THE SCRIPT while the page pipeline they sat in is
# a part (lazysite-processor/pipeline.pm), because moving either changes
# behaviour. _declared_content_roots' memo statements carry initialisers, which
# run here after the main flow and in a part would run inside the loader's
# BEGIN: the processor loaded as the tests load it (`do`, which serves one
# request) clears the memo that request filled, and a part would keep it (the
# S14 shape; tmp/sm944-s18-memo-probe.pl). _lazy_lib finds the Lazysite tree
# from __FILE__, which in a part names a file one directory lower, so the three
# directories it searches would each move up one level.

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
        # SM1078: then the docroot's ../lib, where install.pl puts it whatever
        # --cgibin was (one rule in every script a cgi-bin runs, t/lint/263).
        # $DOCROOT is that same docroot read at file scope: under the pool a
        # sub sees the request's %ENV, not the pool's (t/lint/43).
        my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
        my $doc = $DOCROOT // '';
        for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib", ( length $doc ? "$doc/../lib" : () ) ) {
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

        # P14 (ruled 2026-10-12, "Render from the canonical"): the address of
        # the domain this host is an alias of - its own site_url when it is the
        # canonical one. The canonical link and the registries render from it;
        # the host keeps serving under its own name and its own site_url.
        # Authoritative, never conf-overridable, like alias_host above.
        {
            my ( $canon_host, $canon_url ) = _canonical_of( $text, $alias_host );
            $vars{canonical_url}
                = $canon_host eq $alias_host
                ? ( $vars{site_url} // '' )
                : ( do { my %r = resolve_tt_vars( { site_url => $canon_url } ); $r{site_url} } // $canon_url );
        }

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
        undef $ACL_MAP_CACHE;    # SM973: a pooled worker re-reads acls.json
        undef $DRAFT_BYTES;      # SM1030
        undef $DRAFT_MD;
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
