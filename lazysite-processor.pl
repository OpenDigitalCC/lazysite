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
    for my $part (qw(front-matter.pm oembed.pm remap.pm components.pm ct-cache.pm gates.pm access-log.pm front-door.pm include.pm forms.pm output.pm request.pm)) {
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

# --- Scan and registries ---
#
# The reserved front-matter keys, the scan: source, the registry regenerator and
# its serving path, scan_pages, and the TT helpers they share.

# SM459: the front-matter keys the ENGINE owns.
#
# Shared by the page scan and the page's own stash, deliberately. They used to
# disagree: a custom key was visible to a SCAN of the page and invisible to the
# page's own template, so an author wanting one fact in both places wrote it
# twice - once top-level for the index, once inside tt_page_var for their own
# layout - and the two copies drifted with nothing comparing them. That is the
# duplication the metadata exists to remove.
#
# One list, one place. Two copies of a reserved list is the same defect one
# level up, and this programme has met it twice already (SM435, SM457).
#
# SM522: a SUB, not a file-scoped hash. `our %FRONT_MATTER_RESERVED = ...`
# sat here, below the dispatch, and was still EMPTY when a CGI or FastCGI
# request was served - the SM293 shape with `our` in place of `my` - so a
# page's `auth:` and `layout:` reached the stash as page_auth / page_layout
# and the scan carried them as custom keys. A sub is initialised at call
# time and cannot be too early (t/lint/39).
sub _front_matter_reserved {
    return { map { $_ => 1 } qw(
            url title subtitle date tags excerpt searchable path
            layout theme auth register search meta_title meta_desc ) };
}

# The scan modifiers, parsed off the front of the pattern (PR-6). Lifted out
# of resolve_scan verbatim; it still STRIPS what it parses, which is why it
# takes the pattern by reference - the remaining text is the glob.
sub _scan_parse_modifiers {
    my ($pattern_ref) = @_;

    # Parse filter modifiers: "filter=FIELD:VALUE" (may repeat)
    my @filters;
    while ( $$pattern_ref =~ s/\s+filter=(\w+):([^\s]+)// ) {
        push @filters, { field => $1, value => $2 };
    }

    # Parse sort modifier: "sort=FIELD DIRECTION"
    my $sort_field = 'filename';
    my $sort_dir   = 'asc';
    if ( $$pattern_ref =~ s/\s+sort=(\w+)(?:\s+(asc|desc))?//i ) {
        $sort_field = lc($1);
        $sort_dir   = lc($2) if defined $2;
        # date/title/filename are the built-ins; any other identifier sorts on the
        # matching (passed-through) custom front-matter key, e.g. sort=order.
        $sort_field = 'filename' unless $sort_field =~ /^\w+$/;
    }

    return ( \@filters, $sort_field, $sort_dir );
}

# The files a scan pattern reaches, capped and deduplicated (PR-6). Lifted out
# of resolve_scan verbatim: same roots, same walk, same private-wins dedupe,
# same 200-file cap in the same order, and the same _tt_dep calls on the way -
# so the caller receives the identical list it used to build inline.
sub _scan_collect_files {
    my ( $pattern, $scan_root, $excl ) = @_;

    # SM460: SEARCH THE PRIVATE STORE TOO.
    #
    # Gating MOVES content out of the docroot (SM286), so a scan rooted at the
    # docroot found nothing inside a protected section - and rendered a page
    # that listed nothing, successfully. Not an error, not a warning: an author
    # sees an empty list and reasonably concludes their content is missing or
    # their pattern is wrong. It removed scan-driven indexes - how blog
    # listings, feature indexes and library pages are built - from protected
    # areas entirely.
    #
    # SAFE BECAUSE THE FILTER ALREADY EXPECTED THIS. _scan_should_skip keys
    # each entry through _content_rel precisely "so a page resolved from the
    # private store is keyed and checked rather than skipping the branch and
    # being listed" - the ACL gate was written for private entries and never
    # received any. Finding them was the missing half, not the gating.
    #
    # PRIVATE WINS on a collision, the same rule Private::resolve documents: if
    # a stray public copy survives a move, listing the governed copy keeps the
    # ACL applying while stray_public() can still report the leak.
    my @roots     = ($scan_root);
    my $priv_root = _private_twin($scan_root);
    push @roots, $priv_root
        if defined $priv_root && $priv_root ne $scan_root && -d $priv_root;

    my @files;
    for my $root (@roots) {
        my $fs_pattern = $root . $pattern;
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
                    # SM311: the directory itself. A file ADDED or DELETED leaves no
                    # file to stat, but moves its directory's mtime - so the walked
                    # directories are what makes add and delete visible, and the
                    # matched files below are what makes an EDIT visible. Both are
                    # needed; neither is sufficient.
                    _tt_dep($dir);
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
            push @files, glob($fs_pattern);
            # SM311: same reasoning, one level - the directory the glob names.
            _tt_dep( dirname($fs_pattern) );
        }
    }

    # SM460: private wins when a path exists in both trees. Keyed on the
    # docroot-relative name so the two spellings of one page collapse to one
    # entry rather than listing it twice.
    {
        my %by_key;
        for my $f (@files) {
            my $key = _content_rel($f);
            $key = $f unless defined $key;
            # A later root (the private one) replaces an earlier public twin.
            $by_key{$key} = $f;
        }
        # SORTED, because the 200-file cap below takes a prefix and hash
        # order is randomised per process - an uncapped list would come out
        # right and a capped one would hold a different 200 pages each render.
        @files = sort values %by_key;
    }

    # Limit to 200 files
    @files = @files[ 0 .. 199 ] if @files > 200;

    return @files;
}

# A page's date: the front matter's, else the file's mtime as YYYY-MM-DD
# (PR-5). resolve_scan and scan_pages carried identical copies of this.
sub _page_date {
    my ( $meta, $path ) = @_;
    my $date = $meta->{date} || '';
    unless ($date) {
        my @st = stat($path);
        if (@st) {
            my @t = localtime( $st[9] );
            $date = sprintf( "%04d-%02d-%02d", $t[5] + 1900, $t[4] + 1, $t[3] );
        }
    }
    return $date;
}

# A page's URL: the path with the scanned root, the .md suffix and a trailing
# /index stripped, in that order (PR-5). The other half of the same pair -
# resolve_scan feeds it a path already mapped back to its PUBLIC spelling
# (SM460/SM463), scan_pages feeds it the path it walked; the strip is the same.
sub _page_url {
    my ( $path, $root ) = @_;
    ( my $url = $path ) =~ s{^\Q$root\E}{};
    $url                =~ s/\.md$//;
    $url                =~ s{/index$}{/};
    return $url;
}

sub resolve_scan {
    my ($pattern) = @_;

    my ( $filters, $sort_field, $sort_dir ) = _scan_parse_modifiers( \$pattern );
    my @filters = @$filters;

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

    my @files = _scan_collect_files( $pattern, $scan_root, $excl );

    # Read site search default once if any filter references searchable
    my $search_default;

    # PO-1: two loop invariants, hoisted.
    #
    # EQUIVALENCE. Both were recomputed once per scanned file and neither can
    # change while the loop runs: _private_twin is a pure function of
    # $scan_root, the private root and $DOCROOT, and the loop body writes none
    # of them; _front_matter_reserved returns a fresh hash built from a literal
    # qw list, and the loop only ever READS $reserved{$k}. So each call returned
    # what the one before it returned, 200 times at the cap.
    my $priv_scan = _private_twin($scan_root);
    my %reserved  = %{ _front_matter_reserved() };

    my @pages;
    # @files is already sorted (the private-wins dedupe above sorts it) and the
    # only thing between here and there is the 200-file cap, which takes a
    # prefix - so a second sort would return the same list in the same order.
    for my $path (@files) {
        # Realpath check - confined to the scan root (the domain's content root,
        # or the docroot), so a symlinked file cannot escape the domain (SM151).
        my $real = realpath($path);
        # SM460: _path_under_content, not _path_under - it accepts the scan
        # root OR its private twin, each boundary-safe, which is the same
        # two-strict-checks shape SM458 used rather than one loosened test.
        next unless _path_under_content( $real, $scan_root );
        next unless -f $real;

        # SM311: recorded BEFORE the visibility filter, deliberately. A page that
        # becomes visible - a draft published, an ACL lifted - is an edit to a
        # file that already existed, so no directory mtime moves and the page
        # would never appear in a cached listing. Recording only what was SHOWN
        # would make the listing stale in exactly the case the author is watching
        # for. The path is already public knowledge to the render; this records
        # what was READ, not what was displayed.
        _tt_dep($real);

        # SM268 H13: never list what this requester may not read.
        next if _scan_hidden($real);

        # Read front matter
        my $raw = read_file($path);
        my ( $meta, undef ) = parse_yaml_front_matter($raw);

        # Derive URL relative to the scan root, so a boxed domain's results
        # carry that domain's own '/'-relative paths (SM151).
        #
        # SM460/SM463: map a private-store path back to its PUBLIC spelling
        # first. This strip is a bare prefix, and the private root begins with
        # the scan root - so a page found in the private tree came out as
        # "-lazysite-private/intranet/a", which is both a broken link and a
        # disclosure of the store's naming. Widening the search without fixing
        # the derivation would have introduced that fault rather than found it;
        # SM286's own header warns that resolution and key derivation must
        # change together, and this is the derivation half.
        #
        # Boundary-safe (eq or "$root/"), so a sibling directory whose name
        # merely starts with the private root's is untouched.
        my $url_src = $path;
        if ( defined $priv_scan
            && length $priv_scan
            && ( $url_src eq $priv_scan
                || index( $url_src, "$priv_scan/" ) == 0 ) )
        {
            $url_src = $scan_root . substr( $url_src, length($priv_scan) );
        }
        my $url = _page_url( $url_src, $scan_root );

        # Date from front matter or mtime
        my $date = _page_date( $meta, $path );

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
        my %custom;
        for my $k ( keys %$meta ) {
            next if $reserved{$k} || $k =~ /^(?:tt_|_)/;
            my $v = $meta->{$k};
            if    ( ref $v eq 'ARRAY' ) { $custom{$k} = [ map { _scan_scalar($_) } @$v ] }
            elsif ( !ref $v )           { $custom{$k} = _scan_scalar($v) }
        }

        push @pages, {
            %custom,
            url      => $url,
            title    => $meta->{title}    || '',
            subtitle => $meta->{subtitle} || '',

            # SM300: the description a registry should publish - the explicit
            # meta_desc when the author set one, the subtitle otherwise. Resolved
            # here so every registry template gets the same answer rather than
            # each re-deriving it.
            meta_desc  => ( $meta->{meta_desc}  // $meta->{subtitle} // '' ),
            meta_title => ( $meta->{meta_title} // $meta->{title}    // '' ),
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

# A registry output is stale when it is missing, or older than $REGISTRY_TTL
# (PR-12). update_registries wrote the same test out twice - once as "does
# anything here need regenerating", once as the per-template skip, spelled as
# its negation. Same stat, same comparison, same order.
#
# The two further copies on the serve path (_serve_registry and the re-check
# under the lock in _regenerate_registries_once) are LEFT INLINE deliberately:
# t/unit/plugins/16 and t/unit/processor/46 lift those two subs out of this file
# by regex and run them standalone against stubs, so a call to a helper defined
# elsewhere in the file would be an undefined subroutine in their harnesses.
sub _registry_stale {
    my ($path) = @_;
    return 1 if !-f $path;
    return ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL ? 1 : 0;
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
            my $output_path = _registry_cache_path( $root, $output_name );
            if ( _registry_stale($output_path) ) {
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
            FILTERS     => { url_safe => \&_url_safe_filter },    # SM970
            COMPILE_DIR => $TT_COMPILE_DIR,    # P-4
            COMPILE_EXT => '.ttc',             # P-4
        ) or do { umask $old_umask; return };

        for my $tmpl (@templates) {
            ( my $output_name = $tmpl ) =~ s/\.tt$//;
            my $output_path = _registry_cache_path( $root, $output_name );
            my $tmpl_path   = "$REGISTRY_DIR/$tmpl";

            # Check this specific registry needs updating
            next unless _registry_stale($output_path);

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

            # SM888 A1: A FEED DATE IS FORMATTED FOR THE FEED IT GOES INTO.
            #
            # `date: 2026-08-14` went into RSS's <pubDate> and Atom's <updated>
            # unchanged, and neither accepts it: pubDate wants RFC 822, updated
            # wants RFC 3339. A reader given a date it cannot parse shows the
            # item undated, or dates it "now" and re-sorts the feed on every
            # fetch. Not a crash, which is why every feed this project has
            # published has been wrong and looked fine.
            #
            # DONE HERE RATHER THAN IN THE TEMPLATE, and that is the whole
            # reach of the fix: the registry templates install under bucket
            # `seed`, so an upgrade never replaces them. A site installed a year
            # ago keeps the template it was given. Fixing starter/ alone would
            # fix new sites and leave every feed that has a subscriber wrong.
            #
            # The raw value stays available as `date_raw` for a site that has
            # written its own template around it.
            my $feed_updated = '';
            if ( $registry_name eq 'feed.rss' || $registry_name eq 'feed.atom' ) {
                my $rss = $registry_name eq 'feed.rss';

                # SM942 FO1: NEWEST FIRST, and the sort happens HERE for the same
                # reason the date formatting does - the registry templates install
                # under bucket `seed`, so an upgrade never replaces them and a
                # template-side sort would fix new sites while leaving every feed
                # that HAS a subscriber in filename order.
                #
                # SORTED BEFORE THE MAP, which is the whole trick. The map replaces
                # `date` with the RFC 822 / RFC 3339 string, and sorting THAT orders
                # by weekday name - wrong in a way that still looks sorted, which
                # would be worse than the fault being fixed because it would look
                # deliberate. An ISO date sorts chronologically as text, so the raw
                # value is the right key.
                #
                # AND ONLY AN ISO-LOOKING VALUE IS A SORT KEY. A `date:` the engine
                # cannot parse is passed through to the feed verbatim rather than
                # invented (t/integration/102), so prose like "last Tuesday" reaches
                # here - and as a bare string it sorts ABOVE every real date, which
                # would put the one page nobody dated properly at the top of every
                # reader. Caught by 102 when this sort was first written without the
                # guard. Unparseable sorts last, with no date of its own to argue
                # about.
                my $key = sub {
                    my $d = $_[0]->{date};
                    return '' unless defined $d;
                    return $d =~ /\A\d{4}-\d{2}-\d{2}/ ? $d : '';
                };
                @registered =
                    sort { $key->($b) cmp $key->($a) } @registered;

                @registered = map {
                    my ( $r822, $r3339 ) = _feed_dates( $_->{date} );
                    my $fmt = $rss ? $r822 : $r3339;
                    +{ %$_,
                        date_raw => $_->{date},
                        ( defined $fmt ? ( date => $fmt ) : () ),
                    };
                } @registered;

                # SM942 FO3 (ruled 2026-10-02): cap the item count. A site with a
                # few hundred dated pages otherwise emits all of them on every
                # poll. 50 is the conventional ceiling and costs no current site
                # anything: the pages the cap drops stay in the sitemap, the search
                # index and every link to them - only the FEED is bounded.
                # `feed_items: 0` asks for all of them.
                my $cap = _conf_value('feed_items');
                $cap = 50 unless defined $cap && $cap =~ /\A\d+\z/;
                splice @registered, $cap if $cap && @registered > $cap;

                # The channel's own timestamp, for a template that carries
                # <lastBuildDate> or <updated>. The feed is sorted, so the newest
                # item IS the first one. Kept in a local rather than written into
                # %site_vars, which is shared with sitemap.xml and llms.txt and has
                # no business gaining a feed-only key.
                $feed_updated = @registered ? ( $registered[0]{date} // '' ) : '';
            }

            my $vars = {
                %site_vars,
                pages        => \@registered,
                feed_updated => $feed_updated,    # SM942: '' for every non-feed registry
            };

            my $output = '';
            $tt->process( $tmpl_path, $vars, \$output ) or do {
                log_event( "ERROR", "-", "registry template error", tmpl => $tmpl, error => $tt->error() );
                next;
            };

            make_path( dirname($output_path) ) unless -d dirname($output_path);
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

# SM888 A1: one front-matter date, the two spellings the feed specifications
# require. Returns ( RFC 822, RFC 3339 ), or the empty list when the value is
# not a date this can read.
#
# THE MONTH AND DAY NAMES ARE OURS, not strftime's. %a and %b are LOCALE
# DEPENDENT, and a host with a non-English locale would publish "jeu., 14 août"
# into a feed whose specification names the English abbreviations - a fault
# that appears on some hosts and not others, which is the worst kind to chase.
#
# AN UNPARSEABLE DATE IS PASSED THROUGH, not replaced. Substituting "now" would
# make the feed re-sort itself on every fetch and tell the sysop nothing; the
# page's front matter is where it is wrong and where it should be fixed.
# THE TABLES LIVE INSIDE THE SUB, and that is not a style choice. Written as
# file-scope `my @DOW = (...)` in an enclosing block, they are EMPTY here: this
# is a CGI whose execution reaches the request handler thousands of lines
# above, so a runtime assignment down here never runs before the sub is called.
# The first cut published "<pubDate>, 14  2026 00:00:00 +0000</pubDate>" - a
# date with no day and no month, which is worse than the raw value it replaced.
# Twelve strings on a path that runs when a feed regenerates cost nothing.
{

    sub _feed_dates {
        my ($raw) = @_;
        my @DOW   = qw(Sun Mon Tue Wed Thu Fri Sat);
        my @MON   = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        return () unless defined $raw && length $raw;
        my ( $y, $m, $d, $H, $M, $S ) = $raw =~ m{
            \A \s* (\d{4}) - (\d{2}) - (\d{2})
            (?: [T ] (\d{2}) : (\d{2}) (?: : (\d{2}) )? )?
        }x or return ();
        $H //= 0;
        $M //= 0;
        $S //= 0;
        return () if $m < 1 || $m > 12 || $d < 1 || $d > 31;

        require Time::Local;
        my $epoch = eval {
            Time::Local->can('timegm_modern')
                ? Time::Local::timegm_modern( $S, $M, $H, $d, $m - 1, $y )
                : Time::Local::timegm( $S, $M, $H, $d, $m - 1, $y - 1900 );
        };
        return () unless defined $epoch;

        my @g = gmtime($epoch);
        return (
            sprintf(
                '%s, %02d %s %04d %02d:%02d:%02d +0000',
                $DOW[ $g[6] ], $g[3], $MON[ $g[4] ], $g[5] + 1900,
                $g[2],         $g[1], $g[0]
            ),
            sprintf(
                '%04d-%02d-%02dT%02d:%02d:%02dZ',
                $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]
            ),
        );
    }
}

# SM293 step 3: where a generated registry is cached, per content root.
#
# Keyed on the content root's path RELATIVE to the docroot, so a multi-domain
# instance keeps each domain's sitemap separate. That separation is the whole of
# SM248: one shared file at the docroot root meant a secondary domain was served
# the primary's sitemap, because the front end resolved the file before the
# engine was asked which domain had been requested.
sub _registry_cache_path {
    my ( $root, $name ) = @_;
    my $key = $root;
    $key = '' unless defined $key;
    $key =~ s{\A\Q$DOCROOT\E/?}{};
    $key =~ s{[^A-Za-z0-9._-]+}{_}g;
    $key = '_root' unless length $key;
    return "$REGISTRY_CACHE_DIR/$key/$name";
}

# The content types the generated registries are served as. Named explicitly:
# guessing from the extension would serve feed.atom as application/octet-stream,
# and get llms.txt right only by accident.
#
# A SUB, not a file-scoped `my` hash. This file runs its main body near the TOP,
# so a `my %REGISTRY_CT = (...)` declared down here is still EMPTY when the
# request is served - every registry name looked unknown and every fetch 404'd.
# SM285 shipped exactly this bug with `my @PROBE_EXT`, where it made a security
# probe pass by testing nothing; the comment there says so, and I wrote this one
# the same way anyway. The sub is initialised at call time and cannot be early.
sub _registry_ct {
    my ($name) = @_;
    my %ct = (
        'sitemap.xml' => 'application/xml; charset=utf-8',
        'llms.txt'    => 'text/plain; charset=utf-8',
        'feed.rss'    => 'application/rss+xml; charset=utf-8',
        'feed.atom'   => 'application/atom+xml; charset=utf-8',
    );
    return $ct{$name} if $ct{$name};

    # A registry is any template an operator drops in - `search-index` is the
    # documented example - so the four shipped names cannot be the whole list.
    # The first version of this served only those four, which quietly removed
    # the ability to define your own: the custom template still rendered, and
    # the result was no longer written anywhere nor reachable.
    return 'application/xml; charset=utf-8'      if $name =~ /\.xml\z/;
    return 'application/json; charset=utf-8'     if $name =~ /\.json\z/;
    return 'application/rss+xml; charset=utf-8'  if $name =~ /\.rss\z/;
    return 'application/atom+xml; charset=utf-8' if $name =~ /\.atom\z/;
    return 'text/plain; charset=utf-8';
}

# Serve a generated registry, if this URI names one. Returns 1 when handled.
#
# Generated on request and cached for $REGISTRY_TTL, which the operator chose
# knowing a registry may be a little stale: a sitemap that lags a few hours is
# not a defect, and it buys a high-demand file that never sits in the document
# root at all.
sub _serve_registry {
    my ($uri) = @_;
    return 0 unless defined $uri;
    ( my $name = $uri ) =~ s{\A.*/}{};
    my $ct = _registry_ct($name);
    return 0 unless length $name && $ct;

    # Only if this site actually ships that registry's template - otherwise a
    # request for /sitemap.xml on a site with no registries should 404 as it
    # always did, not answer with an empty document.
    return 0 unless -f "$REGISTRY_DIR/$name.tt";

    my %sv   = resolve_site_vars();
    my $root = $DOCROOT;
    if ( defined $sv{content_root} && length $sv{content_root} ) {
        my $c = confine_content_root( $DOCROOT, $sv{content_root} );
        $root = $c if defined $c;
    }

    # A sysop who wrote their OWN sitemap.xml as content keeps it. In
    # production the front end serves that file and the engine never sees the
    # request, but the guarantee must not depend on which route the request
    # took - the dev server and any ACL-store site come through here.
    return 0 if -f "$root/$name";

    my $path = _registry_cache_path( $root, $name );
    _regenerate_registries_once( $path, $uri )
        if !-f $path || ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL;

    open my $fh, '<:utf8', $path or return 0;
    my $body = do { local $/; <$fh> };
    close $fh;

    # SM389: and it is a served request, so it goes in the access log. Registry
    # hits were the one served path that recorded nothing at all - a crawler
    # fetching sitemap.xml every few hours was invisible, which is exactly the
    # traffic a sysop would want to see. Its own channel rather than 'page':
    # a sitemap fetch is not a page view and must not inflate one.
    $ACCESS_REC{s}  = 200;
    $ACCESS_REC{ch} = 'registry';

    # An explicit Status line, like every other served path here. CGI defaults
    # to 200 without one, so omitting it works and then reads as a missing
    # status to anything asserting on the response.
    print "Status: 200 OK\r\n";
    print "Content-Type: $ct\r\n";
    print "$_\r\n" for _security_headers();    # SM381
    print "Cache-Control: public, max-age=$REGISTRY_TTL\r\n\r\n";
    print $body;
    return 1;
}

# SM389: one regenerator, not N.
#
# TTL expiry is a stampede. The cached file goes stale at an INSTANT, and every
# request arriving after that instant saw the same old mtime and ran
# update_registries() - a full site scan each - concurrently. The cost scales
# with traffic precisely when traffic is what made it stale, and a site big
# enough for the scan to be slow is a site with enough requests to pile up.
#
# A non-blocking lock picks ONE. The losers do not wait and do not regenerate:
# they serve the stale file, which is the entire premise of a TTL cache and is
# what the sysop accepted by setting a TTL at all. A few more seconds of
# staleness on a sitemap is not a defect; N concurrent site scans is.
#
# The one case a loser cannot serve through is no file at all - a cold start, or
# the first request after a cache clear. There it waits for the winner, because
# there is nothing to be stale WITH.
sub _regenerate_registries_once {
    my ( $path, $uri ) = @_;

    my $regen = sub {
        eval { update_registries() };
        log_event( 'WARN', $uri, 'registry generation failed', error => $@ ) if $@;
    };

    # No lock file, no lock - fall back to the old behaviour rather than
    # declining to serve. A herd is a cost; not answering is a fault.
    open my $lh, '>>', "$path.lock" or return $regen->();

    if ( flock $lh, LOCK_EX | LOCK_NB ) {

        # Re-check UNDER the lock. A winner may have finished between the stat
        # that sent us here and the lock we just took, and regenerating again on
        # its fresh output is the same herd in slow motion.
        $regen->()
            if !-f $path || ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL;
        flock $lh, LOCK_UN;
        close $lh;
        return;
    }

    # Somebody else is regenerating.
    if ( -f $path ) { close $lh; return }    # serve it stale

    # Nothing to serve. Wait for the winner rather than joining it - a blocking
    # lock here is one process waiting, where the alternative is N scans.
    flock $lh, LOCK_EX;
    flock $lh, LOCK_UN;
    close $lh;
    return;
}

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

                # SM181 + SM268 H13: a registry (sitemap.xml, llms.txt, the
                # feeds) is a STATIC artefact written to disk and served to
                # anyone, so the question is not "may this requester read it"
                # but "is it public at all". Draft and gated are two answers to
                # that one question and both live in _registry_hidden.
                next if _registry_hidden($path);

                # Get date from front matter or file mtime
                my $date = _page_date( $meta, $path );

                # Derive URL from path, relative to the scanned root (SM151)
                my $url = _page_url( $path, $root );

                push @pages, {
                    url      => $url,
                    title    => $meta->{title}    || '',
                    subtitle => $meta->{subtitle} || '',
                    date     => $date,
                    register => $meta->{register} || [],

                    # SM300: the description a registry publishes - the explicit
                    # meta_desc when the author set one, the subtitle otherwise.
                    # Resolved once here so every registry template gets the same
                    # answer instead of each re-deriving the fallback.
                    meta_desc =>
                        ( $meta->{meta_desc} // $meta->{subtitle} // '' ),
                    meta_title =>
                        ( $meta->{meta_title} // $meta->{title} // '' ),
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
    my ( $meta, $html_body, $query, $before_render ) = @_;
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
        FILTERS     => { url_safe => \&_url_safe_filter },    # SM970
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

    my $query_esc = _esc_query_stash($query);    # SM869: see query => below

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
        # Scalars only. An array or hash has no single escaped form, and the
        # scan already serves the cases that want structure.
        ( map { ( "page_$_" => _esc_html( $meta->{$_} ) ) }
            grep {
                !$reserved->{$_}
                    && !/^(?:tt_|_)/
                    && defined $meta->{$_}
                    && !ref $meta->{$_}
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
        page_meta_title   => _esc_html( $meta->{meta_title} // $meta->{title} ),
        page_author       => _esc_html( $meta->{author} ),

        # SM824 I1: the raw twins, under the contract documented above. The
        # fallbacks mirror the escaped pairs exactly - meta_desc falls back to
        # subtitle, meta_title to title - so a layout reading the raw name gets
        # the same VALUE it would have got escaped, never a different one.
        page_meta_desc_raw  => ( $meta->{meta_desc}  // $meta->{subtitle} // '' ),
        page_meta_title_raw => ( $meta->{meta_title} // $meta->{title}    // '' ),
        page_author_raw     => ( $meta->{author}     // '' ),
        page_modified     => $meta->{page_modified}     || '',
        page_modified_iso => $meta->{page_modified_iso} || '',
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
        manager_caps    => \%manager_caps,             # SM154: gate the Domains nav
        scope_root      => $scope_root,                # SM154: a bound editor's root
        home_domain     => $home_domain,               # SM154: a bound editor's domain
        dav_scopes      => join( ',', @my_scopes ),    # SM157: multi-domain switcher list
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

    # Protect <pre><code> blocks and inline <code> elements from TT processing
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

    return ( $processed_body, $vars );
}

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
        ABSOLUTE     => 1,                                 # needed to read cache path
        ENCODING     => 'utf8',
        EVAL_PERL    => 0,                                 # L-2: no embedded Perl
        INCLUDE_PATH => $component_dir,                    # D035: layout-local components
        FILTERS      => {
            markdown => \&_markdown_filter,
            json     => \&_json_filter,
            url_safe => \&_url_safe_filter,    # SM970
        },
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
