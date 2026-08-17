#!/usr/bin/perl
# stats.pl - SM083: on-site visitor statistics. SM140: the FIRST-PARTY access
# log (lazysite/logs/access-*.jsonl, written by the processor itself,
# anonymised at write) is the default source - zero web-server setup. The
# web-server access log (combined/common format) survives as the fallback
# when no first-party data exists, and its error log as the tier-2
# diagnostics surface.
#
# Read-only and out of band: it parses logs and returns aggregated stats; it
# never writes content. This complements the audit trail, which records
# material actions (auth, edits, deletes) - NOT browsing. Browsing analytics
# live here.
#
# Because lazysite uses no cookies or JS for analytics, every classification is a
# LOG-ONLY heuristic (UA + path + status), attributed at request granularity -
# it is an honest estimate, not authenticated identity.
#
# Invoked by the manager plugin API: `--describe` returns the contract;
# `--scan --docroot DIR` parses the log and prints the stats JSON;
# `--resolve-log --docroot DIR` prints the resolved log path to the CLI for an
# operator debugging log auto-detection - the path is never sent to any page,
# and there is no raw-log download (removed 0.5.29).
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX    ();

my %arg;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--describe' )    { $arg{describe}    = 1 }
    elsif ( $a eq '--scan' )        { $arg{scan}        = 1 }
    elsif ( $a eq '--export' )      { $arg{export}      = 1 }
    elsif ( $a eq '--window' )      { $arg{window}      = shift @ARGV }
    elsif ( $a eq '--day' )         { $arg{day}         = shift @ARGV }    # SM213
    elsif ( $a eq '--month' )       { $arg{month}       = shift @ARGV }    # SM213
    elsif ( $a eq '--index' )       { $arg{index}       = 1 }              # SM213
    elsif ( $a eq '--recount' )     { $arg{recount}     = 1 }              # SM339
    elsif ( $a eq '--apply' )       { $arg{apply}       = 1 }              # SM339
    elsif ( $a eq '--resolve-log' ) { $arg{resolve_log} = 1 }
    elsif ( $a eq '--docroot' )     { $arg{docroot}     = shift @ARGV }
}
my $DOCROOT = $arg{docroot} || $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '.';

# --- classification patterns (log-only heuristics) -----------------------
# Declared before the dispatch below so they are assigned before scan_stats()
# (and classify()) ever run. Probe/scanner noise: paths that only come from
# automated abuse - and a lazysite site serves no PHP, so any *.php is a probe.
my $NOISE_RE = qr{
    (?: ^|/ )
    (?: wp-login\.php | wp-admin | wp-includes | wp-content | xmlrpc\.php
      | phpmyadmin | \bpma\b | \.env | \.git | \.aws | \.ssh
      | vendor/ | boaform | eval-stdin | HNAP1 | setup\.cgi
      | owa/ | autodiscover | actuator | console/ )
}xi;

# SM330: the canonical class list, in one place.
#
# It was written out by hand in five places and `scanner` was missing from the
# one that mattered most - the index. Every view that reports a breakdown now
# derives it from here, so a class added later cannot be silently omitted from
# some of them.
our @CLASSES = qw(human ai bot noise scanner);

# SM338: the COUNTING BASIS. A day's numbers are only comparable with another
# day's if both were counted the same way, and this release changes the way:
# until 0.10.12 a request for an image counted as a page view (SM329).
#
# A closed day file is written once and never rewritten, so every day already
# rolled up keeps its old numbers for ever. The series therefore carries a step
# at whatever date each instance upgrades - a metric change wearing the clothes
# of a traffic change, and per-site, so no changelog date identifies it.
#
# This exists because that confusion has already happened once on a live
# instance and could not be settled: an operator asked why traffic dropped on 27
# July, and the answer needed data from before `data_from` that no longer
# existed. The cost of recording the basis is one small integer per day. The
# cost of not recording it is a question nobody can answer, arriving weeks later
# when the person who changed the counting has moved on.
#
#   1 - assets counted as page views (up to and including 0.10.11)
#   2 - assets counted separately, as asset_hits (SM329, from 0.10.12)
#
# A day-bucket carrying no basis at all predates the field, which is basis 1.
our $COUNTING_BASIS = 2;

# SM342: WHAT THE OPERATION ACTUALLY DID, counted rather than timed.
#
# Every performance figure this project holds is a duration measured on a
# development host with a fast uncontended disk; real sites are on shared
# hosting where I/O costs many times more. Measured: the same export cost
# ~630 ms here and ~3.0 s of engine time on the instrument, and the gap is
# mostly storage. So a change that adds file reads or writes - a normal thing
# for this engine to do - is nearly free here and expensive in the field, and a
# gate on elapsed time cannot see it coming.
#
# Work is HOST-INDEPENDENT. "It re-read every retained log on every call" was
# true on any disk, and is exactly what SM340 turned out to be: a counter would
# have read the same on this machine as on the instrument, and would have moved
# the moment the defect appeared.
#
# Declared with the other package state so it is assigned before the dispatch
# reaches anything that increments it - the trap t/lint/39 exists for.
our %WORK = ( log_files_read => 0, log_bytes_read => 0, day_files_written => 0 );

# SM336: A SESSION HAS A BOUNDARY.
#
# Visitor tokens are day-scoped, not session-scoped, so without one every
# depth, trail and dwell figure is wrong in the same direction: too deep, too
# long, too connected. The brief that raised this found a token showing /login
# followed by /contact 47,458 seconds apart - thirteen hours, counted as a
# two-page journey when it is two visits on the same network a day apart.
#
# Thirty minutes of inactivity is the conventional rule and is enough. It costs
# one timestamp comparison per event.
our $SESSION_GAP = 30 * 60;

# The depth histogram's buckets. A single number saying "60% bounced" tells a
# site owner nothing they can act on; a distribution that says most single-page
# visits land on ONE page tells them what to fix.
sub _depth_bucket {
    my ($n) = @_;
    return '1'   if $n <= 1;
    return '2'   if $n == 2;
    return '3'   if $n == 3;
    return '4-6' if $n <= 6;
    return '7+';
}

# Dwell, from timestamps that already exist. The LAST page of a session has no
# successor and therefore no dwell - that is correct, not missing, and the
# output says so rather than guessing at it.
sub _dwell_bucket {
    my ($s) = @_;
    return 'under_10s' if $s < 10;
    return '10_30s'    if $s < 30;
    return '30_120s'   if $s < 120;
    return 'over_120s';
}

# The bases that contributed to a bucket, oldest form first. An empty or absent
# set means the bucket was built before this was recorded, which is basis 1 -
# never "unknown", because a bucket that exists was definitely counted somehow
# and treating it as unknown would lose the one fact this is here to keep.
sub _basis_of {
    my ($bucket) = @_;
    my @b = sort { $a <=> $b } keys %{ $bucket->{basis} || {} };
    return @b ? @b : (1);
}

# SM329: an image is not a page.
#
# `top_pages` and `pageviews` counted every 2xx request, so two images were the
# second and third most popular "pages" on edge at 124 hits each, and 524 of
# 5,000 sampled events were assets. That is not a cosmetic miscount:
#
#   - top_pages keeps a FIXED number of entries, so every asset in it is a real
#     page the owner cannot see. An article with four images generates four asset
#     hits per human page view, so assets crowd out content by construction.
#   - every derived metric inherits it. Measured against this data, "visitors who
#     saw more than one page" fell from 41% to 5% once an image stopped being a
#     page and a session had a boundary.
#
# RECORDING IS SEPARATED FROM COUNTING. An asset request stays in the event
# stream, where it still feeds classification and the browser-versus-bot
# heuristic; it is excluded from the page-facing aggregates and counted on its
# own, so the exclusion is auditable rather than invisible.
# SM336 item 7: how many DIFFERENT visits must use a term before it is written
# down. Below this only a hash of the term is counted, so a one-off never
# reaches disk in a readable form - see _apply_event.
# A checkbox reaches the plugin config as a string. Treated as OFF unless it
# says something affirmative, because this particular setting failing open would
# start recording visitors' own words on a site that never asked for it.
sub _flag_on {
    my ($v) = @_;
    return 0 unless defined $v && length $v;
    return ( lc $v ) =~ /^(?:1|on|yes|true|enabled)$/ ? 1 : 0;
}

our $SEARCH_TERM_FLOOR = 3;
our $SEARCH_TERM_TOPN  = 20;

my $ASSET_RE = qr{
    \.(?: jpe?g | png | gif | webp | avif | svg | ico | bmp     # images
        | css | js | mjs | map                                  # styles, scripts
        | woff2? | ttf | otf | eot                              # fonts
    )\z
}xi;

sub _is_asset {
    my ($path) = @_;
    return 0 unless defined $path && length $path;
    $path =~ s/\?.*\z//;                 # a cache-buster does not change what it is
    return $path =~ $ASSET_RE ? 1 : 0;
}

# Known crawlers + generic automation clients (not AI assistants - those first).
# `headless` catches Chrome's --headless=new (UA token HeadlessChrome); the named
# headless-driver tokens catch tools that do NOT carry it.
my $BOT_RE = qr{
    bot | crawl | spider | slurp | bingpreview | facebookexternalhit
  | headless | uptime | monitor | pingdom | curl | wget | python-requests
  | go-http | libwww | httpclient | scrapy | java/ | okhttp | axios
  | phantomjs | selenium | puppeteer | playwright | cypress | lighthouse | node-fetch
  | nuclei | nikto | masscan | zgrab | censys | nmap
}xi;

# Self-identifying lazysite tooling: an operator's / partner's own agent doing
# screenshots, QA sweeps or previews - NOT a visitor. The documented opt-out
# convention: set the browser/fetch UA to include `lazysite-agent/<partner-id>`
# (or the legacy `claude-code-agent`) and this traffic is kept out of `human`.
my $AGENT_RE = qr{ lazysite-agent | claude-code-agent }xi;

# Infrastructure / crawler fetches that are not a person browsing pages. Counting
# these as `human` inflates the audience (favicon rides along with every real
# visit; robots/sitemap/feed are readers and crawlers). Classified as noise.
my $INFRA_RE = qr{
    ^/(?: favicon\.ico | robots\.txt | sitemap(?:_index)?\.xml | llms\.txt
        | \.well-known/ | feed(?:\.xml|/|$) | rss(?:\.xml|/|$) | atom\.xml )
}xi;

# SM192: SPA / build-tool manifest probes. A lazysite site serves no SPA build, so
# a request for a framework build-manifest is a scanner probe - but only when it
# 404s (a site that genuinely serves a PWA /manifest.json at 200 is legitimate, so
# classify() applies this gated on the response status, unlike the always-noise
# INFRA_RE). These names inflated the `human` count in the field.
my $SPA_MANIFEST_RE = qr{
    (?: ^|/ )
    (?: asset-manifest\.json | build-manifest\.json | manifest\.json | config\.json )
    (?: $|\? )
  | /_next/ | /\.vite/
}xi;

# SM192: credential / secret fishing. These never exist on a lazysite site, so a
# request is a probe REGARDLESS of the client's user-agent - path noise must win
# over the AI-UA classification (a scanner spoofing an assistant UA to fish for
# /secrets.json is noise, not an AI reader; it inflated the `ai` count in the
# field). Not status-gated: there is no legitimate 200 for these.
my $SECRET_RE = qr{
    (?: ^|/ )
    (?: secrets?\.json | credentials?\.json | secrets?\.ya?ml
      | \.npmrc | \.dockercfg | \.pem | id_rsa )
    (?: $|[?/] )
}xi;

# SM192: referrer-spam hosts - a faked Referer header pointed at a site so the
# spammer's host shows up in the site's public stats/logs (SEO spam). Dropped from
# the external-referrers report. Small, well-known built-in denylist (the twin of
# the noise_paths escape hatch, kept minimal). Matches a host that equals or ends
# with one of these domains.
my @REF_SPAM = qw(
    binance.com buttons-for-website.com semalt.com darodar.com
    ilovevitaly.com econom.co success-seo.com 4webmasters.org
    free-social-buttons.com social-buttons.com trafficmonetizer.org
);
my $REF_SPAM_RE = do {
    my $alt = join '|', map { ( my $d = $_ ) =~ s/\./\\./g; $d } @REF_SPAM;
    qr{ (?: ^|\. ) (?: $alt ) $ }xi;
};
sub _ref_is_spam { my ($host) = @_; return ( defined $host && $host =~ $REF_SPAM_RE ) ? 1 : 0; }

# SM213: a probe/secret-fishing path (UA-independent) - a request for something
# that never exists on a lazysite site. Used to flag a visitor token as a scanner
# for the window (visitor-level classification). Deliberately excludes INFRA_RE
# (favicon/robots/feeds), which legitimate clients also fetch.
sub _is_probe {
    my ( $path, $status ) = @_;
    return 1 if $path                                      =~ $NOISE_RE;
    return 1 if $path                                      =~ m{\.php(?:[?/]|$)}i;
    return 1 if $path                                      =~ $SECRET_RE;
    return 1 if defined $status && $status == 404 && $path =~ $SPA_MANIFEST_RE;
    return 0;
}

# SM332: the behavioural sweep thresholds. Settings rather than constants,
# because the false-positive case is a real person - somebody working through a
# set of stale bookmarks, or a broken navigation menu - and how many 404s that
# produces depends on the site. `noise_paths` is the precedent for an operator
# escape hatch on this classification.
#
# Five distinct missing paths inside five minutes. Distinct is what separates a
# sweep from a stuck client, and five is high enough that a reader who mistypes
# a URL twice is untouched. The window is short because a day's browsing is not
# a sweep however many dead links it accumulates.
sub _sweep_thresholds {
    my ($cfg) = @_;
    my $n     = ( $cfg->{scanner_404_paths}   || 5 ) + 0;
    my $w     = ( $cfg->{scanner_404_minutes} || 5 ) + 0;
    $n = 5 if $n < 2;    # a threshold of 1 is "any 404 is a scan"
    $w = 5 if $w < 1;
    return ( $n, $w * 60 );
}

# AI assistants / model fetchers + the lazysite automation surface.
my $AI_RE = qr{
    GPTBot | ChatGPT | OAI-SearchBot | ClaudeBot | Claude-User | anthropic
  | PerplexityBot | Google-Extended | CCBot | Bytespider | Amazonbot
  | cohere-ai | Diffbot | Applebot-Extended | YouBot | meta-externalagent
}xi;

# Month-name map for log-date parsing. Declared up here (like the regexes above)
# so it is assigned BEFORE the dispatch below ever calls export_stats().
my @MONTHS_X = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %MON_X    = map { $MONTHS_X[$_] => $_ } 0 .. 11;

# Known Apache error codes -> a friendly, data-free category label (used by
# _classify_error). Declared up here so it is assigned before the dispatch below
# ever calls export_stats(). Anything not listed falls back to "Server error
# (<code|module>)"; the raw message is NEVER surfaced (it carries client IPs,
# referer URLs and file paths).
my %ERR_LABELS = (
    AH01071 => 'Probe for a non-existent script (scanner noise)',
    AH01630 => 'Request denied by server configuration',
    AH00574 => 'CGI script produced no headers (script error)',
    AH01276 => 'Directory listing forbidden',
);

if ( $arg{describe} ) {
    print encode_json( {
            id          => 'stats',
            name        => 'Visitor Stats',
            description => 'On-site visitor statistics from the first-party access log '
                . '(recorded by lazysite itself, anonymised at write - no '
                . 'web-server log access needed; the server log is the fallback). '
                . 'Classifies traffic into people, AI assistants, bots and noise '
                . '- all log-only heuristics, not authenticated. Complements the '
                . 'audit trail, which records material actions.',
            version       => '2.2',
            config_file   => 'lazysite/stats.conf',
            config_schema => [
                # NOTE: the access/error log PATHS are deliberately NOT configurable
                # here. They are auto-detected, or set by the server owner at install
                # time via the LAZYSITE_ACCESS_LOG / LAZYSITE_ERROR_LOG environment
                # variables (web-server config). A site manager must never be able to
                # point the reader at an arbitrary file (e.g. /etc/passwd).
                # SM140: the first-party access log (written by the processor
                # itself under lazysite/logs/) is the default analytics source.
                { key => 'first_party', label => 'First-party access log', type => 'boolean', default => 'true',
                    note => 'The processor records its own traffic (anonymised at write) - analytics with no web-server log access needed. Turning this off falls back to reading the web-server log.' },
                { key => 'retention_days', label => 'First-party retention (days)', type => 'text', default => '90' },
                { key => 'window_days', label => 'Window (days)', type => 'text', default => '30' },
                { key => 'top_n', label => 'Top N (pages / referrers)', type => 'text', default => '15' },
                # SM335: `anonymise_ip` was RETIRED here. Both readers now share
                # one tally, and that tally always anonymises - a /24 truncation
                # then a hash, before anything is stored. The export has always
                # worked that way and reports `anonymised: true` unconditionally;
                # the manager page used to key visitors on the raw address when
                # the setting was false.
                #
                # After unification the setting could not do anything, and a
                # setting that cannot do anything is worse than no setting: it
                # tells an operator they have a choice they do not have. Honouring
                # it instead would have meant writing un-anonymised addresses into
                # a durable store deliberately built never to hold them.
                #
                # A conf still carrying the line is inert. lazysite-check says so.
                { key => 'ai_user_agents', label => 'Extra AI user-agents', type => 'text', default => '',
                    note => 'Comma-separated UA substrings to also count as AI assistants, on top of the built-ins (GPTBot, ClaudeBot, anthropic, ...).' },
                { key => 'noise_paths', label => 'Extra noise paths', type => 'text', default => '',
                    note => 'Comma-separated path prefixes to treat as probe/scanner noise, on top of the built-ins (/wp-login.php, /.env, *.php, ...).' },
                # SM332: the behavioural trigger. Exposed because the
                # false-positive case is a real reader following stale
                # bookmarks, and how many of those a site produces is a
                # property of the site rather than of the engine.
                { key => 'scanner_404_paths', label => 'Sweep threshold (distinct missing paths)', type => 'text', default => '5',
                    note => 'A visitor asking for this many DIFFERENT missing pages inside the window below is treated as a scanner, whatever the paths are - this catches probes that no signature list knows about yet. Raise it if readers following old links are being counted as scanners.' },
                { key => 'scanner_404_minutes', label => 'Sweep window (minutes)', type => 'text', default => '5',
                    note => 'How close together those requests must be. Minutes, not hours: a day of browsing is not a sweep however many dead links it turns up.' },
                # SM336 item 7. OFF by default and on its own switch, because it
                # is the one field on that filing's list carrying a real privacy
                # risk: people type surprising things into search boxes, and a
                # search term is the visitor's own words rather than a fact about
                # a page. An operator who wants the rest of SM336 should not get
                # this as a side effect of the release that added sessions.
                { key => 'search_terms', label => 'Record internal search terms', type => 'checkbox', default => '',
                    note => 'Records what visitors typed into the site search, as a top-20 list per day. A term is only stored once ' . $SEARCH_TERM_FLOOR . ' different visits have used it, so a one-off is never kept: below that only a hash is counted, and the words themselves are never written down. Off by default.' },
            ],
            # 'refresh' is called programmatically by the Stats page to pull
            # data - it is not a config-page button (hidden), so the plugin page
            # shows no pointless Refresh.
            actions => [ { id => 'refresh', label => 'Refresh stats', hidden => JSON::PP::true() } ],
    } );
    exit 0;
}

if ( $arg{resolve_log} ) {
    my $log = find_log( read_conf() );
    print encode_json( { ok => ( length $log ? JSON::PP::true : JSON::PP::false ),
            configured => ( length $log ? JSON::PP::true : JSON::PP::false ),
            path       => $log } );    # server-internal only; never shown to the page
    exit 0;
}

# SM339: REBUILD THE DURABLE DAY FILES FROM THE RETAINED RAW LOGS.
#
# Three separate things left the durable store wrong, and one pass repairs all
# three because they share a cause - the day files were written from state that
# was incomplete or computed under a rule that has since changed.
#
#   SM343  a closed day was frozen at the last call made DURING it, so it is
#          short by everything that happened afterwards. Fixed forward by
#          _persist_durable; this is what repairs the days already written.
#   SM329  assets counted as page views. Historical days keep basis 1 and their
#          inflated counts, correctly - that is what SM338's marker preserves -
#          and only a recount can move them to basis 2.
#   SM338  the basis stamp never reached a closed file, because a file written
#          once can never acquire a field added later.
#
# DRY RUN BY DEFAULT. This writes over the only durable record a site has, so
# it reports what it would do and changes nothing unless told `--apply`. An
# upgrade that silently rewrote a site's history would be the wrong shape even
# if the arithmetic were perfect.
#
# BOUNDED BY THE LOGS. It can only rebuild days the retained first-party logs
# still cover - `retention_days`, 90 by default. Days older than that keep the
# figures they have and keep saying which basis produced them, which is exactly
# what the marker is for. A partial repair that says where it stops is worth
# more than one that quietly does less than it claims.
if ( $arg{recount} ) {
    print encode_json( cmd_recount( $arg{apply} ? 1 : 0 ) );
    exit 0;
}

if ( $arg{export} ) {
    # SM213: --export always ingests + refreshes the durable per-day store, then
    # returns either the window view (default) or a specific durable slice:
    #   --index           the days + months index
    #   --day  YYYY-MM-DD  one day's durable rollup
    #   --month YYYY-MM    one month's durable rollup
    my $view = export_stats( $arg{window} );    # ingest + persist durable files
    my $out =
        $arg{index}           ? _read_stats_index()
        : defined $arg{day}   ? _read_daily( $arg{day} )
        : defined $arg{month} ? _read_monthly( $arg{month} )
        :                       $view;
    print encode_json( $out // { ok => JSON::PP::false, error => 'No stats for that day/month yet.' } );
    exit 0;
}

if ( $arg{scan} ) {
    print encode_json( scan_stats() );
    exit 0;
}

print encode_json( { ok => 0, error => 'usage: --describe | --scan --docroot DIR | --resolve-log --docroot DIR' } );
exit 0;

sub read_conf {
    my %c;
    if ( open my $fh, '<', "$DOCROOT/lazysite/stats.conf" ) {
        while ( my $l = <$fh> ) { $c{$1} = $2 if $l =~ /^(\w+)\s*:\s*(.*?)\s*$/; }
        close $fh;
    }
    return \%c;
}

# This site's domain - used to pick a log qualified by THIS site, never another
# site's log in a shared directory, and to split self-referrers from external.
sub _site_domain {
    my $host = '';
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
        while ( my $l = <$fh> ) {
            if ( $l =~ m{^\s*site_url\s*:\s*\S*?://([^/\s]+)} ) { $host = $1; last }
        }
        close $fh;
    }
    $host =~ s/:\d+$//;                                # strip a port
    $host =~ s/^www\.//i;                              # www-agnostic
    if ( $host !~ /^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/ ) { # not a real host (e.g. ${SERVER_NAME})
        require File::Basename;
        my $d = File::Basename::basename( File::Basename::dirname($DOCROOT) );
        $host = ( defined $d && $d =~ /\./ ) ? $d : '';
    }
    return $host;
}

# Resolve the access log: explicit config wins; else auto-detect by checking
# common locations for a log QUALIFIED BY THIS SITE'S DOMAIN. First readable
# match wins; '' means "not found" (the page then asks the operator to set it).
sub find_log {
    my ($cfg) = @_;
    # Server-owner override set at install time in the web-server environment
    # (Apache SetEnv / FastCGI config). NOT manager-editable - the site manager
    # must never be able to point the log reader at an arbitrary file.
    return $ENV{LAZYSITE_ACCESS_LOG}
        if defined $ENV{LAZYSITE_ACCESS_LOG} && length $ENV{LAZYSITE_ACCESS_LOG};

    my $domain = _site_domain();
    return '' unless length $domain;

    # First READABLE candidate wins. A candidate that exists but is not
    # readable is remembered and returned as a last resort, so the caller
    # reports "found but the CGI cannot read it" (the actionable message)
    # instead of "no access log found" - the usual state on a panel host
    # (Hestia), where the domain logs exist but www-data cannot read them
    # until the server owner grants access (field report 2026-07-09).
    my $unreadable = '';
    for my $c (
        "$DOCROOT/../logs/$domain.log",            # Hestia domain log dir
        "$DOCROOT/../logs/$domain.access.log",
        "$DOCROOT/../logs/${domain}-access.log",
        "/var/log/apache2/domains/$domain.log",    # Hestia apache2
        "/var/log/apache2/${domain}-access.log",
        "/var/log/nginx/domains/$domain.log",      # Hestia nginx
        "/var/log/nginx/${domain}.access.log",
        "/var/log/httpd/${domain}-access_log",     # RHEL-ish
        )
    {
        return $c        if -r $c;
        $unreadable = $c if !length $unreadable && -e $c;
    }
    return $unreadable;
}

# Optional error log for this site, mirroring find_log. '' if not found.
sub find_error_log {
    my ($cfg) = @_;
    # Owner-set, install-time only (see find_log) - never manager-editable.
    return $ENV{LAZYSITE_ERROR_LOG}
        if defined $ENV{LAZYSITE_ERROR_LOG} && length $ENV{LAZYSITE_ERROR_LOG};
    my $domain = _site_domain();
    return '' unless length $domain;
    for my $c (
        "$DOCROOT/../logs/$domain.error.log",
        "$DOCROOT/../logs/${domain}-error.log",
        "/var/log/apache2/domains/$domain.error.log",
        "/var/log/nginx/domains/$domain.error.log",
        "/var/log/nginx/${domain}.error.log",
        "/var/log/httpd/${domain}-error_log",
        )
    {
        return $c if -r $c;
    }
    return '';
}

# Read the last $n lines of $path cheaply (only the trailing 64 KB), so a large
# error log doesn't cost a full read. Format-agnostic - no time windowing.
sub _tail_lines {
    my ( $path, $n ) = @_;
    open my $fh, '<', $path or return ();
    my $size  = -s $fh;
    my $chunk = 65536;
    if ( defined $size && $size > $chunk ) {
        seek $fh, $size - $chunk, 0;
        scalar <$fh>;    # drop the partial first line
    }
    my @buf;
    while ( my $l = <$fh> ) {
        chomp $l;
        push @buf, $l;
        shift @buf if @buf > $n;
    }
    close $fh;
    return @buf;
}

# Reduce one raw error-log line to a { key, label } bucket - the AH#### code (or,
# lacking one, the [module:level] tag). No IPs, paths, referers or timestamps.
sub _classify_error {
    my ($line)   = @_;
    my ($code)   = $line =~ /\b(AH\d{4,})\b/;
    my ($module) = $line =~ /\[([a-z_]+):[a-z]+\]/;
    return { key => $code,   label => $ERR_LABELS{$code} } if $code && $ERR_LABELS{$code};
    return { key => $code,   label => "Server error ($code)" }   if $code;
    return { key => $module, label => "Server error ($module)" } if $module;
    return { key => 'other', label => 'Uncategorised server error' };
}

sub _is_browser {
    my ($ua) = @_;
    return $ua =~ /Mozilla|Chrome|Safari|Firefox|Edge|Opera|Gecko/i ? 1 : 0;
}

# Returns one of: noise, ai, bot, logged_in, human. First match wins.
sub classify {
    my ( $path, $ua, $extra_ai, $extra_noise, $status ) = @_;

    return 'noise' if $path =~ $NOISE_RE;
    return 'noise' if $path =~ $INFRA_RE;             # favicon/robots/sitemap/feed
    return 'noise' if $path =~ m{\.php(?:[?/]|$)}i;   # PHP-less site: any .php is a probe
    return 'noise' if $path =~ $SECRET_RE;    # SM192: secret-fishing (UA-independent)
    return 'noise'                            # SM192: 404 SPA/build-manifest probe
        if defined $status && $status == 404 && $path =~ $SPA_MANIFEST_RE;
    if ($extra_noise) {
        for my $p (@$extra_noise) { return 'noise' if length $p && index( $path, $p ) == 0 }
    }

    # Self-identifying lazysite tooling (screenshots/QA/previews) is automation,
    # never a human visitor - honour the opt-out UA convention before anything else.
    return 'bot' if $ua =~ $AGENT_RE;

    my $is_auto_ep = $path =~ m{^/cgi-bin/lazysite-(?:mcp|manager-api|dav)\.pl}i;
    my $is_mgr     = $path =~ m{^/manager(?:/|$)}i
        || $path =~ m{^/cgi-bin/lazysite-auth\.pl}i;
    my $browser = _is_browser($ua);

    # AI by user-agent, by an explicit override, or by the automation surface
    # being hit by a non-browser client (the connector / API / DAV agent).
    return 'ai' if $ua =~ $AI_RE;
    if ($extra_ai) {
        my $l = lc $ua;
        for my $s (@$extra_ai) { return 'ai' if length $s && index( $l, lc $s ) >= 0 }
    }
    return 'ai' if $is_auto_ep && !$browser;

    return 'bot' if $ua =~ $BOT_RE;

    # Operator activity: the manager surface (or the automation endpoints driven
    # from a real browser, i.e. the manager UI's own fetch calls).
    return 'logged_in' if $is_mgr || ( $is_auto_ep && $browser );

    return 'human';
}

sub _split_csv {
    my ($s) = @_;
    return [] unless defined $s && length $s;
    return [ grep { length } map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } split /[,|]/, $s ];
}

# Optional error-log surface (tier-2 diagnostics): a SYNTHESISED summary only
# - error categories + counts from the recent tail, never the raw lines
# (which carry client IPs, referer URLs and file paths). Shared by both scan
# sources.
sub _error_surface {
    my ($cfg)  = @_;
    my $elog   = find_error_log($cfg);
    my %errors = ( available => JSON::PP::false );
    if ( length $elog && -r $elog ) {
        my @recent = _tail_lines( $elog, 1000 );    # bounded to the trailing 64 KB
        my %cat;
        for my $ln (@recent) {
            my $c = _classify_error($ln);
            $cat{ $c->{key} } //= { code => $c->{key}, label => $c->{label}, count => 0 };
            $cat{ $c->{key} }{count}++;
        }
        my @cats = sort { $b->{count} <=> $a->{count} || $a->{code} cmp $b->{code} }
            values %cat;
        %errors = (
            available  => JSON::PP::true,
            sampled    => scalar @recent,
            categories => \@cats,
        );
    }
    return \%errors;
}

# --- SM140: first-party access log (lazysite/logs/access-*.jsonl) -----------
# Written by the processor itself - one JSON line per request, anonymised at
# write - so the default analytics path needs NO web-server log access. The
# server-log parser below survives as the fallback/enrichment path only.

sub first_party_files {
    my @f;
    if ( opendir my $dh, "$DOCROOT/lazysite/logs" ) {
        @f = sort grep { /^access-\d{8}[.]jsonl$/ } readdir $dh;
        closedir $dh;
    }
    return map { "$DOCROOT/lazysite/logs/$_" } @f;
}

# SM335: THE MANAGER STATS PAGE READS THE SHARED TALLY.
#
# This used to be a second counting implementation. It streamed the logs,
# classified each request on its own, and produced a class breakdown from a
# vocabulary of its own: human / logged_in / ai / bot / noise, with no
# `scanner` at all - because `scanner` is a VISITOR-LEVEL promotion computed in
# `_tally_batch`, which only the export path ran.
#
# So the page an operator actually opens could not show the largest class of
# traffic on their site. On the instrument that is 71.7% of events. Its
# arithmetic was never wrong on its own terms - its five classes accounted for
# every request it counted - but a scanner's probes sat in `noise` and the
# requests it made either side of them sat in `human`. The total was right and
# the attribution was not, which is harder to notice than a total that is wrong.
#
# Two implementations of one count is also how SM329 came to be fixed in two
# places and missed in a third. This removes the second one.
#
# WHY A PROJECTION RATHER THAN A SECOND PASS. Visitor-level promotion needs the
# probe tokens known before any counting, so a streaming reader would have to
# read the logs twice - and SM342's work counters would report that, correctly,
# as the code doing more than it did. The buckets are already built,
# incrementally, by the ingest this now calls. Summing them costs no reads at
# all.
#
# `logged_in` stays page-only and that is deliberate: the export reports the
# AUDIENCE, and an operator's own sessions are not audience. The page being a
# superset of the export is coherent. The page being 71.7% wrong about who is
# visiting was not.
sub scan_first_party {
    my ( $cfg, @files ) = @_;

    my $window = ( $cfg->{window_days} || 30 ) + 0;
    $window = 30 if $window < 1;

    my $cache = _load_export_cache() || {};
    _export_ingest_first_party( $cfg, $cache, \@files );
    _persist_durable( $cache, $cfg );
    _save_export_cache($cache);

    my $out = _page_view_from_buckets( $cfg, $cache, $window );
    $out->{source} = 'first-party';
    return $out;
}

# The page's shape, summed from the day buckets. One counting implementation,
# two projections of it: this and _export_assemble.
sub _page_view_from_buckets {
    my ( $cfg, $cache, $window ) = @_;
    my $top_n = ( $cfg->{top_n} || 15 ) + 0;
    $top_n = 15 if $top_n < 1;

    my $from      = _day_str( time() - ( $window - 1 ) * 86400 );
    my $days      = $cache->{days} || {};
    my @in_window = grep { $_ ge $from } sort keys %$days;

    my ( %cls_hits, %cls_vis, %pages, %ref_ext, %status, %byday, %vis );
    my ( $hits, $bytes, $assets, $ref_internal, $ref_direct ) = ( 0, 0, 0, 0, 0 );

    for my $day (@in_window) {
        my $b = $days->{$day};
        $cls_hits{$_} += $b->{cls}{$_} for keys %{ $b->{cls} || {} };
        for my $c ( keys %{ $b->{cls_ips} || {} } ) {
            $cls_vis{$c}{$_} = 1 for keys %{ $b->{cls_ips}{$c} };
        }
        # HUMAN visitors only. The headline tile sits beside `Page views`, which
        # is human-only, and the old reader counted this after its
        # `next unless $class eq 'human'`. Summing $b->{ips} instead would put
        # scanners in the headline - 71.7% of traffic on the instrument - which
        # is the opposite of what this whole filing is about.
        $vis{$_} = 1 for keys %{ $b->{cls_ips}{human} || {} };
        $hits         += ( $b->{hits}         // 0 );
        $bytes        += ( $b->{bytes}        // 0 );
        $assets       += ( $b->{asset_hits}   // 0 );
        $ref_internal += ( $b->{ref_internal} // 0 );
        $ref_direct   += ( $b->{ref_direct}   // 0 );
        $pages{$_}    += $b->{pages}{$_}   for keys %{ $b->{pages}   || {} };
        $ref_ext{$_}  += $b->{ref_ext}{$_} for keys %{ $b->{ref_ext} || {} };
        $status{$_}   += $b->{status}{$_}  for keys %{ $b->{status}  || {} };
        $byday{$day} = ( $b->{hits} // 0 );
    }

    my $top = sub {
        my ($h) = @_;
        my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
        @k = @k[ 0 .. ( $top_n - 1 ) ] if @k > $top_n;
        return [ map { { key => $_, count => $h->{$_} } } @k ];
    };

    # SM330's canonical list, plus the one class that exists only here. Derived
    # rather than written out, so a sixth class cannot be left off this view the
    # way `scanner` was left off the index.
    my %classes;
    for my $c ( @CLASSES, 'logged_in' ) {
        $classes{$c} = {
            hits     => ( $cls_hits{$c} // 0 ),
            visitors => scalar keys %{ $cls_vis{$c} || {} },
        };
    }

    return {
        ok              => 1,
        window_days     => $window,
        anonymised      => JSON::PP::true,
        log_configured  => JSON::PP::true,
        errors          => _error_surface($cfg),
        classes         => \%classes,
        hits            => $hits,                  # human only, as before
        asset_hits      => $assets,                # SM329
        unique_visitors => scalar keys %vis,
        bytes           => $bytes,
        top_pages       => $top->( \%pages ),
        referrers       => {
            external => $top->( \%ref_ext ),
            internal => $ref_internal,
            direct   => $ref_direct,
        },
        status  => {%status},
        per_day => [ map { { day => $_, count => $byday{$_} } } sort keys %byday ],
    };
}

# SM335: the server-log window reader, now the same projection.
#
# The first-party reader above lost its own counting implementation for the
# reasons written there. This is the fallback path - a site with no first-party
# logs, reading the web server's - and leaving it counting separately would have
# meant the page showed `scanner` on some sites and not others, which is worse
# than showing it nowhere.
sub scan_stats {
    my $cfg = read_conf();

    # SM140: first-party data wins. The server log is the fallback.
    my @fp = first_party_files();
    return scan_first_party( $cfg, @fp ) if @fp;

    my $window = ( $cfg->{window_days} || 30 ) + 0;
    $window = 30 if $window < 1;

    my $cache    = _load_export_cache() || {};
    my $ingested = _export_ingest_server_log( $cfg, $cache );
    unless ( ref $ingested eq 'HASH' && $ingested->{ok_to_assemble} ) {
        # The ingest's own refusal - no log configured, or unreadable - passed
        # through unchanged, so the page still explains itself.
        return $ingested;
    }
    _persist_durable( $cache, $cfg );
    _save_export_cache($cache);

    my $out = _page_view_from_buckets( $cfg, $cache, $window );
    $out->{source} = 'server-log';
    return $out;
}

# --- AI export: cached, incremental visitor-log analysis -------------------
# Produces a SANITISED JSON the AI reasons over: aggregates + a capped event
# stream. NEVER the raw log, the log path, any filesystem path, or a visitor IP.
# An incremental cache (per-day buckets + a processed byte-offset) means each call
# parses only the NEW log lines, not the whole file.

# Parse one combined-format log line -> hashref, or undef.
sub _parse_line {
    my ($line) = @_;
    return undef
        unless $line =~ m{
            ^(\S+)\ \S+\ \S+          # remote host (1), ident, authuser
            \ \[([^\]]+)\]            # [date] (2)
            \ "\S+\ (\S+)\ [^"]*"     # "method  path(3)  protocol"
            \ (\d{3})\ (\S+)          # status (4), bytes (5)
            \ "([^"]*)"\ "([^"]*)"    # "referer(6)"  "user-agent(7)"
        }x;
    my ( $ip, $date, $target, $st, $bs, $ref, $ua ) = ( $1, $2, $3, $4, $5, $6, $7 );

    # SM336: the capture is the request TARGET, query string and all. Split once
    # here so the path that gets counted is a path - see _split_query for what
    # that was doing to top_pages.
    my ( $path, $query ) = _split_query($target);
    return undef
        unless $date =~ m{^(\d+)/(\w+)/(\d+):(\d+):(\d+):(\d+)} && exists $MON_X{$2};
    my ( $d, $mo, $y, $H, $Mi, $S ) = ( $1, $2, $3, $4, $5, $6 );
    my $epoch = eval { POSIX::mktime( $S, $Mi, $H, $d, $MON_X{$mo}, $y - 1900 ) };
    return undef unless defined $epoch;
    return {
        ip     => $ip,
        epoch  => $epoch,
        day    => sprintf( '%04d-%02d-%02d', $y, $MON_X{$mo} + 1, $d ),
        path   => $path,
        query  => $query,    # SM336
        status => $st + 0,
        # SM335: bytes were captured by the pattern and thrown away. The window
        # reader counted them itself from its own parse; now that both readers
        # share one tally, the record has to carry what the tally totals.
        bytes => ( $bs =~ /^\d+$/ ? $bs + 0 : 0 ),
        ref   => $ref,
        ua    => $ua,
    };
}

sub _anon_ip {
    my ($ip) = @_;
    $ip =~ s/\.\d+$/.0/;    # zero the last IPv4 octet (no-op for a non-dotted addr)
    return $ip;
}

# A short, non-reversible token for grouping events by visitor at NETWORK level
# (the address is already truncated to its /24 before hashing).
# SM336 item 6: the device class, from the user-agent both ingesters already
# have and both were discarding - classify() consumed it and the record kept
# only its verdict.
#
# Three counters, and the order of the tests is the whole of it. Every Android
# TABLET also says "Android", and most say "Mozilla"; only a PHONE says "Mobile"
# as well. So tablet is tested first and Android-without-Mobile falls to it,
# which is the rule the spec-writers settled on and the reason a naive
# /Android/ = mobile test reports every tablet as a phone.
#
# Deliberately three, not a taxonomy. The question it answers is "does mobile
# matter to me", which decides a great deal of design work; "which of eleven
# form factors" decides nothing anyone here would act on.
sub _device_class {
    my ($ua) = @_;
    return 'unknown' unless defined $ua && length $ua;
    return 'tablet'
        if $ua =~ m{ iPad | Tablet | PlayBook | Kindle | Silk }xi
        || ( $ua =~ m{Android}i && $ua !~ m{Mobile}i );
    return 'mobile'
        if $ua =~ m{ Mobi | iPhone | iPod | Android | Windows\ Phone
                   | IEMobile | BlackBerry | Opera\ Mini }xi;
    return 'desktop';
}

# The query string, split from the path.
#
# SM336: needed for item 7, and it turned up a defect on the way. The server-log
# parser captured the request target with \S+, which INCLUDES the query string,
# and nothing downstream stripped it - _is_asset removed it for its own test and
# put it straight back. So `/search-results?q=widgets` and
# `/search-results?q=prices` were two different entries in top_pages, and every
# distinct search diluted the page counts of the page being searched from. Same
# shape as SM329: something counted as a page that is not a distinct page.
#
# Stripped once, here, so both the counting and the term extraction read the
# same split.
sub _split_query {
    my ($target) = @_;
    return ( '', '' ) unless defined $target;
    my ( $path, $query ) = split /\?/, $target, 2;
    return ( $path, ( defined $query ? $query : '' ) );
}

# The search term a request carries, or undef. `q` is the parameter the shipped
# search form uses.
#
# Normalised hard on purpose: lowercased, whitespace collapsed, trimmed, and
# capped at 80 characters. A top-20 list of near-identical spellings is not a
# report, and an unbounded string from a query parameter is not something to key
# a hash with.
sub _search_term {
    my ($query) = @_;
    return undef unless defined $query && length $query;
    my ($raw) = $query =~ /(?:^|&)q=([^&]*)/ or return undef;
    $raw =~ tr/+/ /;
    $raw =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    $raw = lc $raw;
    $raw =~ s/\s+/ /g;
    $raw =~ s/^ | $//g;
    return undef unless length $raw;
    return substr( $raw, 0, 80 );
}

sub _visitor_token {
    require Digest::SHA;
    return substr( Digest::SHA::sha256_hex( $_[0] ), 0, 12 );
}

sub _day_str { return POSIX::strftime( '%Y-%m-%d', localtime( $_[0] ) ) }

sub _cache_path { return "$DOCROOT/lazysite/cache/stats-export.json" }

# SM340: BOTH shapes are valid caches and each ingester normalises the one it
# gets. This accepted version 1 only, while the first-party ingester writes
# version 2 - so on the default path the load returned undef, `|| {}` supplied
# an empty hash, and the cache was discarded on every single call. The per-file
# byte offsets, which are the entire point of the incremental design, had never
# once been used.
#
# The intent was already written down: the server-log path's own comment says "a
# v2 first-party cache lands here too and resets to the server-log shape", which
# it could not do while the loader refused to hand one over. So this is the gate
# being wrong rather than a policy being changed.
#
# The version is still checked, because an unrecognised shape must not be
# handed to an ingester that will index into it. Anything else is treated as no
# cache at all, which is the safe direction: a rebuild is correct and slow, and
# reading a shape nobody wrote is neither.
#
# A SUB, not a package hash. The first version of this was
# `our %CACHE_SHAPES = ( 1 => ..., 2 => ... )` declared here, and the dispatch
# that reaches the loader runs EARLIER in the file than this line - so the hash
# was still empty when it was consulted and every cache was rejected, exactly
# as before the fix and for a completely different reason. This file already
# carries three comments warning about that trap for its regexes and month map;
# it caught this too. A sub is bound at compile time and cannot be read before
# it is assigned, because it is never assigned.
sub _known_cache_shape {
    my ($v) = @_;
    return 0 unless defined $v;
    return ( $v == 1 || $v == 2 ) ? 1 : 0;    # server-log / first-party
}

sub _load_export_cache {
    open my $fh, '<', _cache_path() or return undef;
    local $/;
    my $j = <$fh>;
    close $fh;
    my $c = eval { JSON::PP::decode_json($j) };
    return undef unless ref $c eq 'HASH';
    return _known_cache_shape( $c->{v} ) ? $c : undef;
}

sub _save_export_cache {
    my ($c) = @_;
    my $dir = "$DOCROOT/lazysite/cache";
    return unless -d $dir;
    my $tmp = _cache_path() . ".$$";
    open my $fh, '>', $tmp or return;
    print {$fh} encode_json($c);
    close $fh;
    rename $tmp, _cache_path();
    return;
}

# --- SM213: durable per-day store ------------------------------------------
# The aggregates live long-term as one small JSON file per day under
# lazysite/stats/ (NOT the clearable cache), plus monthly rollups and an index -
# so the data is durable, per-day addressable and downloadable, with no cap to hit
# and nothing for an operator to configure. The day-buckets in the cache remain the
# working aggregate; this mirrors them to disk. Past days are immutable once closed,
# so a historical file is written once and only today's is refreshed each call.
sub _stats_dir   { return "$DOCROOT/lazysite/stats" }
sub _daily_dir   { return _stats_dir() . '/daily' }
sub _monthly_dir { return _stats_dir() . '/monthly' }

# SM339: CANONICAL, so the durable files are diffable.
#
# `encode_json` orders keys by Perl's hash iteration, which is randomised per
# process - so writing the same content twice produces different bytes. That
# cost nothing while a day file was written once and never rewritten. It costs
# something now: SM343 rewrites a day when it closes and `--recount` rewrites
# it deliberately, so an operator auditing a repair with `diff` would see every
# line move and have no way to tell a reordering from a change.
#
# Canonical ordering makes these files comparable by anybody, with no tooling -
# which is what a repair somebody has to trust actually requires.
sub _write_json_atomic {
    my ( $path, $data ) = @_;
    my $tmp = "$path.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($data);
    close $fh;
    return rename( $tmp, $path ) ? 1 : 0;
}

sub _read_json_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $j = <$fh>;
    close $fh;
    return eval { JSON::PP::decode_json($j) };
}

# Top-N of a { key => count } hash, descending. NB: never name a lexical $a/$b in
# this scope - it would shadow sort's package vars.
sub _topn {
    my ( $h, $n ) = @_;
    my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
    @k = @k[ 0 .. $n - 1 ] if @k > $n;
    return [ map { { key => $_, count => $h->{$_} } } @k ];
}

# A compact, sanitised durable rollup for one day from its raw day-bucket.
sub _day_rollup {
    my ( $day, $bucket, $top_n ) = @_;
    my %cls = %{ $bucket->{cls} || {} };
    return {
        date             => $day,
        pageviews        => ( $bucket->{hits}             // 0 ),
        asset_hits       => ( $bucket->{asset_hits}       // 0 ),    # SM329
        scanner_inferred => ( $bucket->{scanner_inferred} // 0 ),    # SM332

        # SM338: what these numbers mean, carried WITH them. A reader comparing
        # this day to another has to be able to tell whether the comparison is
        # valid, and the answer cannot live in a changelog they would have to
        # know to go and look for.
        # SM341: WHEN this was produced. The index has carried it all along; the
        # day and month payloads carried nothing, so an agent holding a rollup
        # from before an upgrade and one from after could say what changed and
        # not when either was made. That cost a real claim: a partner agent
        # could not establish whether a day file predated their own capture or
        # was created by it, because nothing in the payload said.
        #
        # A timestamp, not provenance. It answers "when was this produced",
        # which is the question being asked, and nothing about authenticity.
        generated            => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        counting_basis       => ( _basis_of($bucket) )[-1],
        counting_basis_mixed => (
            scalar( _basis_of($bucket) ) > 1 ? JSON::PP::true : JSON::PP::false
        ),
        unique_visitors => scalar keys %{ $bucket->{ips} || {} },
        classes         => { map { ( $_ => ( $cls{$_} // 0 ) ) } @CLASSES },
        top_pages       => _topn( $bucket->{pages} || {}, $top_n ),
        status_codes    => { %{ $bucket->{status} || {} } },
        not_found       => {
            plausible  => _topn( $bucket->{nf_plausible} || {}, $top_n ),
            junk_count => ( $bucket->{nf_junk} // 0 ),
        },
        # SM223: turned away, as distinct from missing.
        auth_refused => _topn( $bucket->{auth_refused} || {}, $top_n ),

        # SM336: SEQUENCE. Aggregates only - a counter on an edge and a bucket
        # in a histogram, never anybody's path. `dwell` deliberately has no
        # entry for the last page of a session: it has no successor and
        # therefore no dwell, which is correct rather than missing.
        sessions => ( $bucket->{sessions} // 0 ),
        journeys => {
            transitions    => _topn( $bucket->{transitions} || {}, $top_n ),
            entry          => _topn( $bucket->{entry}       || {}, $top_n ),
            exit           => _topn( $bucket->{exit}        || {}, $top_n ),
            depth          => { %{ $bucket->{depth} || {} } },
            dwell          => { %{ $bucket->{dwell} || {} } },
            landing        => _topn( $bucket->{landing} || {}, $top_n ),
            not_found_from => _topn( $bucket->{nf_from} || {}, $top_n ),
        },
        # SM336 item 6. `unknown` is a real answer - a request with no
        # user-agent is not a desktop - so it is reported rather than folded
        # into the largest bucket.
        devices => { %{ $bucket->{device} || {} } },

        # SM336 item 7. Absent entirely on a site that has not turned it on,
        # rather than present and empty: an empty list reads as "nobody
        # searched", and the truthful answer is "nobody was asked".
        (   ( $bucket->{sq} && %{ $bucket->{sq} } )
            ? ( search_terms => _topn( $bucket->{sq}, $SEARCH_TERM_TOPN ) )
            : ()
        ),

        referrers => {
            direct   => ( $bucket->{ref_direct}   // 0 ),
            internal => ( $bucket->{ref_internal} // 0 ),
            external => _topn( $bucket->{ref_ext} || {}, $top_n ),
        },
        # SM216-2: per-form delivery outcomes - stored vs quarantined vs blocked
        # (by reason). Counts only; form names + reason codes, no submission data.
        forms => ( $bucket->{forms} || {} ),
    };
}

# A month's durable rollup: union the daily visitor sets (accurate within a salt
# period) and sum the rest, across the days that fall in the month.
sub _month_rollup {
    my ( $mon, $days, $top_n ) = @_;
    my ( %cls, %pages, %ips, %status, %nf_pl, %forms );
    my %auth_ref;    # SM223
    my ( $pv, $ndays, $nf_junk, $asset_pv, $inferred ) = ( 0, 0, 0, 0, 0 );
    my %bases;       # SM338
    for my $day ( grep { index( $_, $mon ) == 0 } keys %$days ) {
        my $b = $days->{$day};
        $ndays++;
        $pv       += ( $b->{hits}             // 0 );
        $asset_pv += ( $b->{asset_hits}       // 0 );    # SM329
        $inferred += ( $b->{scanner_inferred} // 0 );    # SM332
        $bases{$_} = 1 for _basis_of($b);                # SM338
        $nf_junk      += ( $b->{nf_junk} // 0 );
        $cls{$_}      += $b->{cls}{$_}          for keys %{ $b->{cls}          || {} };
        $pages{$_}    += $b->{pages}{$_}        for keys %{ $b->{pages}        || {} };
        $status{$_}   += $b->{status}{$_}       for keys %{ $b->{status}       || {} };
        $nf_pl{$_}    += $b->{nf_plausible}{$_} for keys %{ $b->{nf_plausible} || {} };
        $auth_ref{$_} += $b->{auth_refused}{$_} for keys %{ $b->{auth_refused} || {} };
        $ips{$_} = 1 for keys %{ $b->{ips} || {} };
        for my $fn ( keys %{ $b->{forms} || {} } ) {     # SM216-2
            my $fb = $b->{forms}{$fn};
            $forms{$fn}{stored}      += $fb->{stored}      // 0;
            $forms{$fn}{quarantined} += $fb->{quarantined} // 0;
            $forms{$fn}{blocked}{$_} += $fb->{blocked}{$_} for keys %{ $fb->{blocked} || {} };
        }
    }
    return {
        month => $mon,
        days  => $ndays,
        # SM329: pageviews is PAGES. Assets are reported separately rather than
        # folded in, so a reader can see both and the exclusion is checkable.
        pageviews        => $pv,
        asset_hits       => $asset_pv,
        scanner_inferred => $inferred,

        # SM338: a MONTH is where this bites hardest. The current month is
        # refreshed on every call, so in the month an instance upgrades it sums
        # days counted one way and days counted the other into a single total
        # - and that total is not wrong so much as not a measurement of
        # anything. It has to be able to say so.
        generated            => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),   # SM341
        counting_basis       => ( sort { $a <=> $b } keys %bases )[-1] // 1,
        counting_basis_mixed => (
            keys %bases > 1 ? JSON::PP::true : JSON::PP::false
        ),
        unique_visitors => scalar keys %ips,
        classes         => { map { ( $_ => ( $cls{$_} // 0 ) ) } @CLASSES },
        top_pages       => _topn( \%pages, $top_n ),
        status_codes    => \%status,
        not_found    => { plausible => _topn( \%nf_pl, $top_n ), junk_count => $nf_junk },
        auth_refused => _topn( \%auth_ref, $top_n ), # SM223
        forms        => \%forms,                     # SM216-2: per-form delivery outcomes
    };
}

sub _persist_durable {
    my ( $cache, $cfg ) = @_;
    my $days = $cache->{days} || {};
    return unless %$days;
    my $top_n      = ( $cfg->{top_n} || 15 ) + 0;
    my $today      = _day_str( time() );
    my ($this_mon) = $today =~ /^(\d{4}-\d{2})/;

    for my $d ( _stats_dir(), _daily_dir(), _monthly_dir() ) { -d $d or mkdir $d }
    return unless -d _daily_dir() && -d _monthly_dir();

    # SM343: A CLOSED DAY IS WRITTEN ONCE MORE, AFTER IT CLOSES.
    #
    # This was "today refreshed every call; a closed day written once", and both
    # halves are individually reasonable. Together they meant a file created at
    # 14:00 on Tuesday WAS Tuesday's permanent record: by the time anyone called
    # again, Tuesday was no longer today and its file already existed, so
    # Tuesday's evening never reached it.
    #
    # A day file was therefore complete only if nobody looked at the statistics
    # that day. Measured in the field: 2026-08-16 was frozen at 19:23 with 838
    # scanner hits absent, because a field-validation agent read the store during
    # that day. Reading the statistics damaged the statistics.
    #
    # The fix is one extra write per day, ever. A day that has closed is written
    # again the first time it is seen closed - at which point its bucket holds
    # the whole day - and then marked final so it is not rewritten on every
    # subsequent call.
    $cache->{final} ||= {};
    for my $day ( keys %$days ) {
        my $path   = _daily_dir() . "/$day.json";
        my $closed = ( $day lt $today ) ? 1 : 0;

        my $write =
            !-f $path                ? 'absent'
            : !$closed               ? 'today'
            : !$cache->{final}{$day} ? 'closing'
            :                          '';
        next unless $write;

        _write_json_atomic( $path, _day_rollup( $day, $days->{$day}, $top_n ) );
        $WORK{day_files_written}++;    # SM342
        $cache->{final}{$day} = 1 if $closed;
    }

    # The marker is transient working state and follows the retention prune
    # below, so it cannot grow without bound: a day dropped from the buckets
    # loses its marker with it, and would be rewritten once if it ever came back.
    delete @{ $cache->{final} }{ grep { !exists $days->{$_} } keys %{ $cache->{final} } };

    # Months present in the data; current month refreshed, closed months once.
    my %months;
    for my $day ( keys %$days ) {
        my ($m) = $day =~ /^(\d{4}-\d{2})/;
        $months{$m} = 1 if defined $m;
    }
    for my $mon ( keys %months ) {
        my $path = _monthly_dir() . "/$mon.json";
        next unless $mon eq $this_mon || !-f $path;
        _write_json_atomic( $path, _month_rollup( $mon, $days, $top_n ) );
    }

    # Index: the days list + a light month-on-month series (pageviews + deltas),
    # regenerated each call (cheap; no visitor-set union needed here).
    my @dk       = sort keys %$days;
    my @days_idx = map {
        my $b = $days->{$_};
        # SM330: EVERY class, derived from the list rather than hand-written.
        #
        # This enumerated human/ai/bot/noise and omitted `scanner`, which is the
        # LARGEST class on a public site - 71.7% of events on edge, against 17.2%
        # human. So the index, which is what a reader sees first, showed a
        # breakdown whose parts summed to a small fraction of the traffic and
        # gave no hint that anything was missing.
        #
        # The full-day view already reported all five. Two hand-maintained lists
        # of one fact, and the shorter one was the one on the front page.
        #
        # Derived from @CLASSES so a sixth class cannot be added and silently
        # left out of this view again.
        { date => $_,
            pageviews      => ( $b->{hits}       // 0 ),
            asset_hits     => ( $b->{asset_hits} // 0 ),    # SM329
            counting_basis => ( _basis_of($b) )[-1],        # SM338
            map { ( $_ => ( $b->{cls}{$_} // 0 ) ) } @CLASSES
        }
    } @dk;
    my ( %month_pv, %month_basis_set );
    for my $day (@dk) {
        my ($m) = $day =~ /^(\d{4}-\d{2})/;
        $month_pv{$m} += $days->{$day}{hits} // 0;
        $month_basis_set{$m}{$_} = 1 for _basis_of( $days->{$day} );    # SM338
    }
    my @mk = sort keys %month_pv;
    my @months_idx;
    for my $i ( 0 .. $#mk ) {
        my $prev = $i > 0 ? $month_pv{ $mk[ $i - 1 ] } : undef;
        push @months_idx, {
            month           => $mk[$i],
            pageviews       => $month_pv{ $mk[$i] },
            delta_pageviews => ( defined $prev ? ( $month_pv{ $mk[$i] } - $prev ) : undef ),

            # SM338: the DELTA is the number that misleads. In the month an
            # instance upgrades, a fall of a third is the counting changing and
            # reads exactly like an audience leaving - and this series is the
            # first thing anybody looks at.
            counting_basis_mixed =>
                ( keys %{ $month_basis_set{ $mk[$i] } || {} } > 1
                ? JSON::PP::true
                : JSON::PP::false ),
        };
    }
    _write_json_atomic( _stats_dir() . '/index.json', {
            ok        => JSON::PP::true,
            generated => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
            data_from => $dk[0],
            data_to   => $dk[-1],
            days      => \@days_idx,
            months    => \@months_idx,
            notes => 'Durable per-day aggregates; IP-anonymised, no per-visitor records or paths.',
    } );
    return;
}

sub _read_daily {
    my ($day) = @_;
    return { ok => JSON::PP::false, error => 'Bad day (want YYYY-MM-DD).' }
        unless defined $day && $day =~ /^\d{4}-\d{2}-\d{2}$/;
    my $r = _read_json_file( _daily_dir() . "/$day.json" );
    return defined $r ? { ok => JSON::PP::true, day => $r } : undef;
}

sub _read_monthly {
    my ($mon) = @_;
    return { ok => JSON::PP::false, error => 'Bad month (want YYYY-MM).' }
        unless defined $mon && $mon =~ /^\d{4}-\d{2}$/;
    my $r = _read_json_file( _monthly_dir() . "/$mon.json" );
    return defined $r ? { ok => JSON::PP::true, month => $r } : undef;
}

sub _read_stats_index {
    my $r = _read_json_file( _stats_dir() . '/index.json' );
    return $r // { ok => JSON::PP::false, error => 'No stats index yet.' };
}

# SM213: two-pass tally of a parsed batch into the day-buckets, shared by both
# ingesters. Pass 1 flags every visitor token that hit a probe path as a scanner
# FOR THE WINDOW - persisted in the cache (salt-obsoleting; transient working
# state, never written to a durable day file). Pass 2 counts, reclassing ALL of a
# scanner token's events to 'scanner' (so a referrer-spoofer's homepage hit is
# pulled out of the human/referrer buckets, not just its probe). 404s split into
# plausible (a human hit a missing page - kept by path, bounded) vs junk (a
# scanner chorus - counted only). A record: {day,path,status,class,token,ref,t}.
# The day-bucket shape, in one place. It was written out twice - here and in the
# form-event ingester, which creates a bucket for a day with blocks but no page
# traffic - and a field added to one was a field missing from the other. Same
# shape as SM330's class list: one fact, two hand-maintained copies.
sub _new_day_bucket {
    return {
        cls              => {}, ips     => {}, hits         => 0, pages      => {},
        status           => {}, ref_ext => {}, ref_internal => 0, ref_direct => 0,
        nf_plausible     => {}, nf_junk => 0,  auth_refused => {},
        asset_hits       => 0,    # SM329
        scanner_inferred => 0,    # SM332

        # SM335: the manager Stats page reports these two and the durable
        # rollup did not, which is one of the reasons the page carried its own
        # counting implementation. Tracked here so there is one counter, not two.
        bytes   => 0,
        cls_ips => {},

        # SM336: SEQUENCE. Everything above is a marginal count - nothing pairs
        # one dimension with another and nothing records order, so the question
        # a site owner asks first (how do people move through my site, and where
        # do they give up) was answerable only from a rolling sample, and never
        # for any period already past.
        #
        # All of these are aggregates. A hundred visitors going / -> /products
        # -> /contact is one counter of 100 on each edge, NOT a hundred stored
        # journeys: it reconstructs a flow without retaining anybody's path.
        transitions => {},    # "from>to" -> count
        entry       => {},    # first page of a session
        exit        => {},    # last page - the most actionable field there is
        depth       => {},    # 1 / 2 / 3 / 4-6 / 7+
        dwell       => {},    # under_10s / 10_30s / 30_120s / over_120s
        landing     => {},    # "referrer-host>landing-path"
        nf_from     => {},    # "missing-path>internal-referrer"
        sessions    => 0,

        # SM338: which counting basis this day's numbers were built under. A
        # SET, not a scalar, because the day an instance upgrades genuinely has
        # events tallied under both - and a day that is half one basis and half
        # the other must be able to say so rather than pick.
        basis => {},
    };
}

# SM340: one event's contribution to a day bucket, applied with $sign = +1 or
# reversed with $sign = -1.
#
# It exists because the cache fix creates a case that could not arise while the
# cache was discarded: a token promoted to scanner in a LATER batch, whose
# earlier requests are already counted under `human`. While every call re-read
# the whole log, that reclassification happened by brute force and nobody had to
# think about it. With the cache honoured, the earlier events are already in the
# bucket and the promotion has to reach back - so the counting has to be
# reversible, and the only safe way to reverse it is to run the same code
# backwards rather than a second copy written to match.
#
# Class-INDEPENDENT effects stay at the call site: the visitor set, which a
# reclassification does not change, and the day's basis marker.
sub _apply_event {
    my ( $b, $r, $cls, $sign, $site_host, $inferred, $nf_cap ) = @_;
    my $st = $r->{status} // 0;

    $b->{cls}{$cls} += $sign;
    delete $b->{cls}{$cls} if ( $b->{cls}{$cls} // 0 ) <= 0;

    $b->{scanner_inferred} += $sign if $cls eq 'scanner' && $inferred;

    if ( $st == 404 ) {
        if ( $cls eq 'human' ) {
            # The cap governs GROWTH only. A reversal must always be allowed
            # through, or a capped map could never shrink and the map would
            # keep a path whose count had gone to nothing.
            if ( $sign < 0 || keys %{ $b->{nf_plausible} } < $nf_cap ) {
                $b->{nf_plausible}{ $r->{path} } += $sign;
                delete $b->{nf_plausible}{ $r->{path} }
                    if ( $b->{nf_plausible}{ $r->{path} } // 0 ) <= 0;
            }
        }
        else { $b->{nf_junk} += $sign }
    }

    return unless $cls eq 'human';

    my $is_asset = _is_asset( $r->{path} );
    if   ( $is_asset && $st < 400 ) { $b->{asset_hits} += $sign }
    else                            { $b->{hits}       += $sign }

    # SM336 item 6: device, on PAGE views only. Counting an asset would report
    # the device that fetched a stylesheet, which is the same device that
    # fetched the page and would multiply every visit by however many files its
    # layout happens to load. Same reasoning as SM329.
    if ( !$is_asset && $st < 400 ) {
        my $dev = $r->{device} // 'unknown';
        $b->{device}{$dev} += $sign;
        delete $b->{device}{$dev} if ( $b->{device}{$dev} // 0 ) <= 0;
    }

    # SM336 item 7: a search term, counted behind a floor.
    #
    # THE WORDS ARE NOT WRITTEN DOWN UNTIL THE FLOOR IS REACHED. `sq_seen` holds
    # a hash of the term against its count and is what persists between calls;
    # the term itself only enters `sq` once that count reaches the floor, and
    # leaves again if a reversal takes it back below. So a term one visitor
    # typed once exists on disk as twelve hex characters and nothing else.
    #
    # Reversible, because SM339's recount replays every event with sign -1 and a
    # tally that cannot be undone would make a repair produce a different answer
    # from the ingest it repairs. The raw term is available on the way down as
    # well as the way up, since it rides on the event rather than the bucket.
    if ( defined $r->{term} && length $r->{term} && !$is_asset ) {
        my $h = _visitor_token( $r->{term} );
        $b->{sq_seen}{$h} += $sign;
        my $n = $b->{sq_seen}{$h} // 0;
        if ( $n <= 0 ) { delete $b->{sq_seen}{$h} }
        if ( $n >= $SEARCH_TERM_FLOOR ) { $b->{sq}{ $r->{term} } = $n }
        else                            { delete $b->{sq}{ $r->{term} } }
    }

    $b->{status}{$st} += $sign;
    delete $b->{status}{$st} if ( $b->{status}{$st} // 0 ) <= 0;

    if ( $st < 400
        && !$is_asset
        && $r->{path} !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b} )
    {
        $b->{pages}{ $r->{path} } += $sign;
        delete $b->{pages}{ $r->{path} } if ( $b->{pages}{ $r->{path} } // 0 ) <= 0;
    }

    my $ref = $r->{ref} // '';
    if    ( !length $ref || $ref eq '-' ) { $b->{ref_direct} += $sign }
    elsif ( $ref =~ m{^\S+?://([^/\s]+)} ) {
        ( my $rh = $1 ) =~ s/^www\.//i;
        if ( length $site_host
            && ( lc $rh eq lc $site_host || $rh =~ /\Q$site_host\E$/i ) )
        {
            $b->{ref_internal} += $sign;
        }
        elsif ( !_ref_is_spam($rh) ) {
            $b->{ref_ext}{$rh} += $sign;
            delete $b->{ref_ext}{$rh} if ( $b->{ref_ext}{$rh} // 0 ) <= 0;
        }
    }
    return;
}

# SM336: fold a finished session into its day.
#
# One place, called from both the point where a gap starts a new session and the
# sweep that closes sessions nothing has touched. Two callers writing this
# separately is how the two would come to disagree about what a session IS.
# SM336: close every visit that has gone quiet.
#
# A session's exit page is otherwise recorded only when that visitor comes BACK,
# so the last visit of every day would be missing from `exit` and `depth` for
# ever - the most actionable field silently excluding the most recent traffic.
#
# Thirty minutes of silence ends a visit whether or not anything else has
# happened, so the boundary is measured against the clock and not against the
# batch.
sub _close_stale_sessions {
    my ($cache) = @_;
    return unless ref $cache->{sess} eq 'HASH';
    my $stale = time() - $SESSION_GAP;
    for my $tok ( keys %{ $cache->{sess} } ) {
        _close_session( $cache, $tok, 500 )
            if ( $cache->{sess}{$tok}{t} // 0 ) < $stale;
    }
    return;
}

# SM336: place one page view in a session, and record what that reveals.
#
# The session state is per token and lives in the export cache beside SM213's
# scanner map - transient working state, salt-obsoleting, never written into a
# durable day file. What reaches the day file is only ever an AGGREGATE: a
# counter on an edge, a bucket in a histogram. No visitor's path is stored.
sub _sessionise {
    my ( $cache, $r, $tok, $b, $site_host, $cap ) = @_;
    $cache->{sess} ||= {};
    my $now  = $r->{t} // 0;
    my $path = $r->{path};
    my $s    = $cache->{sess}{$tok};

    # A gap, or a day boundary, ends the visit. The day boundary matters
    # independently: a session straddling midnight would otherwise fold its exit
    # page into the wrong day, and the durable store is per-day.
    if ( $s && ( $now - ( $s->{t} // 0 ) > $SESSION_GAP || $s->{day} ne $r->{day} ) ) {
        _close_session( $cache, $tok, $cap );
        $s = undef;
    }

    unless ($s) {
        # A new visit. The referrer that STARTED it is the one worth pairing
        # with the landing page; a referrer on a later page is on-site
        # navigation and says nothing about where the visitor came from.
        my $ref_host = '';
        if ( length( $r->{ref} // '' ) && $r->{ref} ne '-' ) {
            if ( my ($h) = ( $r->{ref} =~ m{^\S+?://([^/\s]+)} ) ) {
                ( my $bare = $h ) =~ s/^www\.//i;
                my $internal = length $site_host
                    && ( lc $bare eq lc $site_host || $bare =~ /\Q$site_host\E$/i );
                $ref_host = $bare if !$internal && !_ref_is_spam($bare);
            }
        }
        $cache->{sess}{$tok} = {
            day      => $r->{day},
            t        => $now,
            first    => $path,
            last     => $path,
            n        => 1,
            ref_host => $ref_host,
        };

        # Bounded like every other per-token map here. A sweep arriving under
        # many tokens must not grow the cache without limit; the set
        # self-obsoletes on a salt roll in any case.
        $cache->{sess} = {} if keys %{ $cache->{sess} } > 20_000;
        return;
    }

    # A step within the visit. The transition is the trail question answered as
    # an aggregate, and the dwell belongs to the page being LEFT.
    if ( defined $s->{last} && $s->{last} ne $path ) {
        $b->{transitions}{"$s->{last}>$path"}++
            if keys %{ $b->{transitions} } < $cap;
        $s->{n}++;
    }
    $b->{dwell}{ _dwell_bucket( $now - ( $s->{t} // $now ) ) }++;

    $s->{last} = $path;
    $s->{t}    = $now;
    return;
}

sub _close_session {
    my ( $cache, $tok, $cap ) = @_;
    my $s = delete $cache->{sess}{$tok} or return;
    my $b = $cache->{days}{ $s->{day} } or return;

    $b->{sessions}++;
    $b->{depth}{ _depth_bucket( $s->{n} ) }++;

    # Entry and exit. The exit page is the one a content owner can act on: it
    # names where the argument fails.
    $b->{entry}{ $s->{first} }++ if defined $s->{first} && keys %{ $b->{entry} } < $cap;
    $b->{exit}{ $s->{last} }++   if defined $s->{last}  && keys %{ $b->{exit} } < $cap;

    # Where the session came from, paired with where it landed - the difference
    # between "we get traffic from X" and "traffic from X arrives on the wrong
    # page".
    if ( defined $s->{ref_host} && length $s->{ref_host} && defined $s->{first} ) {
        my $k = "$s->{ref_host}>$s->{first}";
        $b->{landing}{$k}++ if keys %{ $b->{landing} } < $cap;
    }
    return;
}

sub _tally_batch {
    my ( $cache, $batch, $cfg ) = @_;

    # SM336: the stale-session sweep runs even when there is nothing to ingest,
    # and that is the whole point of putting it before the early return: a visit
    # ends by SILENCE, so the run that has nothing new is exactly the one that
    # should notice a session has finished. Leaving it after would mean a site
    # that stops receiving traffic never records its last visit's exit page.
    _close_stale_sessions($cache);

    return unless @$batch;
    my $site_host = _site_domain();
    my $EVENT_CAP = 5000;
    my $IP_CAP    = 50000;
    my $NF_CAP    = 500;
    $cache->{scanner}    ||= {};
    $cache->{scanner_by} ||= {};
    $cache->{sweep}      ||= {};

    # SM332: two triggers, and the ORDER matters only for attribution - a token
    # caught by both is recorded as caught by signature, because that is the
    # cheaper and more certain of the two.
    #
    # The second trigger is behavioural: a visitor asking for many DISTINCT
    # missing paths in a short window is sweeping, whatever the paths are. It
    # exists because the first trigger is a signature list and signature lists
    # date - `/wp-login.php` is caught by the `.php` rule and its modern
    # replacement `/wp-json/batch/v1` is caught by nothing, so a WordPress
    # enumeration ran as `human` and would have been the top journey on the site
    # the moment trail metrics existed.
    my ( $sweep_n, $sweep_w ) = _sweep_thresholds($cfg);
    my @newly_promoted;    # SM340: tokens that became scanners in THIS batch
    for my $r (@$batch) {
        my $tok = $r->{token} // '';
        next unless length $tok;
        if ( _is_probe( $r->{path}, $r->{status} ) ) {
            push @newly_promoted, $tok unless $cache->{scanner}{$tok};
            $cache->{scanner}{$tok}    = 1;
            $cache->{scanner_by}{$tok} = 'signature';
            delete $cache->{sweep}{$tok};    # promoted; stop accruing state for it
            next;
        }
        next if $cache->{scanner}{$tok};
        next unless ( $r->{status} // 0 ) == 404;

        # DISTINCT paths, timestamped. One path retried is a broken link or a
        # stuck client; the same path a hundred times is not a sweep.
        my $seen = $cache->{sweep}{$tok} ||= {};
        my $now  = $r->{t} // 0;
        $seen->{ $r->{path} } = $now
            if !exists $seen->{ $r->{path} } && keys %$seen < ( $sweep_n * 4 );
        delete $seen->{$_} for grep { $now - $seen->{$_} > $sweep_w } keys %$seen;

        if ( keys %$seen >= $sweep_n ) {
            push @newly_promoted, $tok unless $cache->{scanner}{$tok};
            $cache->{scanner}{$tok}    = 1;
            $cache->{scanner_by}{$tok} = 'behaviour';
            delete $cache->{sweep}{$tok};
        }
    }

    # SM340: REACH BACK. A token promoted in this batch may have requests that
    # were counted under `human` in an EARLIER one - the scanner's homepage hit,
    # which is the whole reason SM213 classifies per visitor rather than per
    # request. While the cache was discarded on every call this fixed itself by
    # brute force, because the entire log was re-read each time. With the cache
    # honoured it has to be done deliberately.
    #
    # Bounded by construction: the event ring is capped, so this can only ever
    # revisit recent events, and each is reversed exactly once because its class
    # in the ring is rewritten as it goes. What has scrolled out of the ring
    # keeps the class it was counted under - stated in the export's own note
    # that `events` is a bounded sample rather than the dataset.
    if (@newly_promoted) {
        my %promoted = map { ( $_ => 1 ) } @newly_promoted;
        for my $e ( @{ $cache->{events} } ) {
            my $tok = $e->{visitor} // '';
            next unless length $tok && $promoted{$tok};
            next if ( $e->{class} // '' ) eq 'scanner';
            my $b   = $cache->{days}{ $e->{day} // '' } or next;
            my $was = $e->{class} // 'human';
            _apply_event( $b, $e, $was, -1, $site_host, 0, $NF_CAP );
            _apply_event( $b, $e, 'scanner', 1, $site_host,
                ( ( $cache->{scanner_by}{$tok} // '' ) eq 'behaviour' ), $NF_CAP );
            $e->{class} = 'scanner';
        }
    }

    # Both maps self-obsolete on a salt roll; the sweep map is transient working
    # state and is bounded harder, because it holds a path set per token rather
    # than a flag.
    $cache->{scanner} = {} if keys %{ $cache->{scanner} } > 200_000;
    $cache->{sweep}   = {} if keys %{ $cache->{sweep} } > 20_000;
    delete $cache->{scanner_by}{$_}
        for grep { !$cache->{scanner}{$_} } keys %{ $cache->{scanner_by} };

    for my $r (@$batch) {
        my $tok = $r->{token} // '';
        my $cls = ( length($tok) && $cache->{scanner}{$tok} ) ? 'scanner' : $r->{class};
        my $b   = $cache->{days}{ $r->{day} } ||= _new_day_bucket();
        $b->{basis}{$COUNTING_BASIS} = 1;    # SM338
        $b->{ips}{$tok}              = 1 if length($tok) && keys %{ $b->{ips} } < $IP_CAP;

        # SM335: bytes and per-class visitors, for the page that used to count
        # them itself. Capped exactly as the visitor set above is, so a scanner
        # arriving under many tokens cannot grow the cache without bound.
        # SM336: SEQUENCE, for human page views only.
        #
        # A scanner has no journey worth modelling - and until SM332 the top
        # journey on the site would have been a WordPress sweep, which is what
        # made classification quality a prerequisite for this rather than an
        # adjacent concern. An asset is not a step either: it is not an entry
        # page, not an exit page and not a transition (SM329).
        if ( $cls eq 'human'
            && length $tok
            && ( $r->{status} // 0 ) < 400
            && !_is_asset( $r->{path} )
            && $r->{path} !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b} )
        {
            _sessionise( $cache, $r, $tok, $b, $site_host, $NF_CAP );
        }

        # SM336: the referring page for a 404, INTERNAL referrers only. A broken
        # internal link is a one-edit fix and the owner was being told the
        # destination and never the source. Internal-only keeps it small and
        # keeps it about their own site.
        if ( ( $r->{status} // 0 ) == 404 && length( $r->{ref} // '' ) ) {
            my ($rh) = ( $r->{ref} =~ m{^\S+?://([^/\s]+)} );
            if ( defined $rh ) {
                ( my $bare = $rh ) =~ s/^www\.//i;
                if ( length $site_host
                    && ( lc $bare eq lc $site_host || $bare =~ /\Q$site_host\E$/i ) )
                {
                    my ($rp) = ( $r->{ref} =~ m{^\S+?://[^/\s]+([^\s?#]*)} );
                    $rp = '/' unless defined $rp && length $rp;
                    $b->{nf_from}{"$r->{path}>$rp"}++
                        if keys %{ $b->{nf_from} } < $NF_CAP;
                }
            }
        }

        $b->{bytes} += ( $r->{bytes} // 0 );
        $b->{cls_ips}{$cls}{$tok} = 1
            if length($tok) && keys %{ $b->{cls_ips}{$cls} || {} } < $IP_CAP;

        _apply_event( $b, $r, $cls, 1, $site_host,
            ( ( $cache->{scanner_by}{$tok} // '' ) eq 'behaviour' ), $NF_CAP );

        # SM223: refusals are counted per PATH, for every class rather than
        # humans only. The case this exists to catch is an asset that became
        # protected by accident when the ACL's read list started governing the
        # public path as well as the authoring channels - and an asset is fetched
        # by whatever the page embeds it in, which is often not classified human.
        # Capped like the 404 map so a scanner cannot grow the file without bound.
        $b->{auth_refused}{ $r->{path} }++
            if $r->{auth_refused} && keys %{ $b->{auth_refused} || {} } < $NF_CAP;

        # SM340: `day` and `ref` are carried for the reconciliation below and
        # are NOT exported - the projection in _export_assemble enumerates the
        # published fields, so a referrer cannot leave attached to a visitor
        # token by sharing a hash with one.
        push @{ $cache->{events} }, {
            t       => $r->{t},
            class   => $cls,
            path    => $r->{path},
            status  => ( $r->{status} // 0 ),
            visitor => $tok,
            day     => $r->{day},
            ref     => ( $r->{ref} // '' ),
        };
        shift @{ $cache->{events} } while @{ $cache->{events} } > $EVENT_CAP;
    }

    _close_stale_sessions($cache);    # SM336: and again, for this batch's own
    return;
}

# SM339: the recount itself.
#
# It does NOT re-implement ingestion. It resets the incremental state - the
# per-file byte offsets and the day buckets the logs can rebuild - and lets the
# ordinary export path do the reading, so a recount and a normal run cannot
# disagree about how an event is counted. A second parser would be one fact in
# two places, which is the defect this project keeps closing.
sub cmd_recount {
    my ($apply) = @_;

    my @files = first_party_files();
    return {
        ok    => JSON::PP::false,
        error => 'no first-party logs to recount from - this site reads the '
            . 'web-server log, which has no per-day retention the engine controls',
    } unless @files;

    # Which days can the retained logs actually rebuild? The filenames say so
    # without reading a byte: access-YYYYMMDD.jsonl.
    my %covered;
    for my $f (@files) {
        next unless $f =~ m{access-(\d{4})(\d{2})(\d{2})\.jsonl\z};
        $covered{"$1-$2-$3"} = 1;
    }
    my @days = sort keys %covered;
    return { ok => JSON::PP::false, error => 'no dated first-party logs found' }
        unless @days;

    # What the durable store says now, so the report can be a comparison rather
    # than an assertion that something was done.
    my %before;
    for my $d (@days) {
        my $cur = _read_daily($d) or next;
        my $r   = $cur->{day}     or next;    # _read_daily wraps the rollup
        $before{$d} = {
            pageviews      => $r->{pageviews},
            asset_hits     => $r->{asset_hits},
            counting_basis => $r->{counting_basis},
        };
    }

    unless ($apply) {
        return {
            ok      => JSON::PP::true,
            dry_run => JSON::PP::true,
            note    => 'Nothing was changed. Re-run with --apply to rewrite '
                . 'these days from the retained logs.',
            days_the_logs_cover => scalar @days,
            from                => $days[0],
            to                  => $days[-1],
            current             => \%before,
            what_it_would_do    =>
                'Reset the ingest offsets and the buckets for these days, '
                . 're-read the retained logs, and rewrite each day file under '
                . "the current counting basis ($COUNTING_BASIS). Days older "
                . 'than the logs are not touched and keep the basis they were '
                . 'counted under.',
        };
    }

    # APPLY. Drop the incremental state for the covered window only: the
    # offsets, so the logs are read again from the start, and the buckets for
    # those days, so nothing is double-counted into figures that already hold
    # them. Days OUTSIDE the window keep their buckets untouched - they cannot
    # be rebuilt and must not be discarded.
    my $cache = _load_export_cache() || {};
    delete $cache->{files};
    delete $cache->{days}{$_}  for @days;
    delete $cache->{final}{$_} for @days;    # so each is written again on close

    # The event ring and the visitor-level maps are transient working state and
    # are rebuilt by the re-read. Dropping them avoids a token promoted from
    # events that are about to be re-ingested being counted twice.
    delete @{$cache}{qw(events scanner scanner_by sweep)};
    _save_export_cache($cache);

    # Remove the day files for the covered window so _persist_durable writes
    # them fresh rather than treating them as already present.
    for my $d (@days) {
        my $path = _daily_dir() . "/$d.json";
        unlink $path if -f $path;
    }
    # The months those days belong to must be rebuilt too, or a month keeps a
    # total summed from the figures being replaced.
    my %months = map { substr( $_, 0, 7 ) => 1 } @days;
    for my $m ( keys %months ) {
        my $path = _monthly_dir() . "/$m.json";
        unlink $path if -f $path;
    }

    # The ordinary path does the work.
    export_stats(30);

    my %after;
    for my $d (@days) {
        my $cur = _read_daily($d) or next;
        my $r   = $cur->{day}     or next;
        $after{$d} = {
            pageviews      => $r->{pageviews},
            asset_hits     => $r->{asset_hits},
            counting_basis => $r->{counting_basis},
        };
    }

    # A per-day comparison, because "it ran" is not a result. A day whose
    # pageviews fall by exactly the asset_hits it gains is the SM329 correction
    # doing what it says; a day that RISES is the SM343 truncation being
    # repaired, and both can happen to the same day.
    my @changed = grep {
        my $b = $before{$_} || {};
        my $a = $after{$_}  || {};
        ( $b->{pageviews} // -1 ) != ( $a->{pageviews} // -1 )
            || ( $b->{counting_basis} // 0 ) != ( $a->{counting_basis} // 0 );
    } @days;

    return {
        ok        => JSON::PP::true,
        applied   => JSON::PP::true,
        days      => scalar @days,
        from      => $days[0],
        to        => $days[-1],
        changed   => scalar @changed,
        unchanged => scalar(@days) - scalar(@changed),
        before    => \%before,
        after     => \%after,
        note      => 'Days older than the retained logs were not touched and '
            . 'keep the counting basis they were written under.',
    };
}

sub export_stats {
    my ($window) = @_;
    $window = ( $window || 30 ) + 0;
    $window = 30  if $window < 1;
    $window = 365 if $window > 365;

    my $cfg = read_conf();

    # SM140: first-party data wins, exactly as scan_stats. The server-log
    # ingestion below survives as the fallback when no first-party data
    # exists.
    my @fp    = first_party_files();
    my $cache = _load_export_cache() || {};
    if (@fp) {
        _export_ingest_first_party( $cfg, $cache, \@fp );
        return _export_assemble( $cfg, $cache, $window, 'first-party' );
    }

    my $ingested = _export_ingest_server_log( $cfg, $cache );
    return $ingested unless ref $ingested eq 'HASH' && $ingested->{ok_to_assemble};
    return _export_assemble( $cfg, $cache, $window, 'server-log' );
}

# SM335: the server-log ingest, lifted out of export_stats so the manager Stats
# page can drive the same tally the export does instead of counting the log a
# second time. Returns { ok_to_assemble => 1 } or a caller-facing error hash.
sub _export_ingest_server_log {
    my ( $cfg, $cache ) = @_;
    my $log = find_log($cfg);

    # SM335: TWO refusals, not one. The manager Stats page distinguished these
    # and the export did not, and collapsing them when the readers were unified
    # would have been a real loss - an operator whose log exists but cannot be
    # read needs a permission fixed, and one with no log at all needs a path
    # configured. Telling them the same thing sends half of them to the wrong
    # place.
    return {
        ok           => 0,
        needs_config => JSON::PP::true,
        error        => 'No access log found for this site. The log path is '
            . 'auto-detected, or set by the server owner at install time via '
            . 'the LAZYSITE_ACCESS_LOG environment variable.',
    } unless length $log;

    return {
        ok           => 0,
        needs_config => JSON::PP::true,
        error        => 'An access log exists for this site but is not readable '
            . 'by the web server user. Grant read access to it, or point '
            . 'LAZYSITE_ACCESS_LOG at a log the site can read.',
    } unless -r $log;

    my @st = stat($log);
    my ( $inode, $size ) = ( $st[1], $st[7] );

    # Rotation / truncation: a different inode, or the file is now smaller than our
    # offset, means the offset is untrustworthy - reprocess from the start. (A v2
    # first-party cache lands here too and resets to the server-log shape.)
    if ( ( $cache->{inode} // -1 ) != $inode || ( $cache->{offset} // 0 ) > $size ) {
        # SM335: %$cache, not $cache. This was a lexical inside export_stats and
        # reassigning it was fine; as a PARAMETER, reassigning rebinds the local
        # name and the caller's hash never receives anything - the whole scan
        # came back zeroes with no error. Clear the caller's hash in place.
        %{$cache} = ( v => 1, inode => $inode, offset => 0, days => {}, events => [] );
    }
    $cache->{v}     = 1;
    $cache->{inode} = $inode;
    $cache->{days}   ||= {};
    $cache->{events} ||= [];

    my $extra_ai = _split_csv( $cfg->{ai_user_agents} );
    # SM336 item 7: off unless the operator turned it on. Read here rather than
    # inside the loop so a site that has not opted in never even extracts a term.
    my $want_terms = _flag_on( $cfg->{search_terms} );
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $site_host   = _site_domain();
    my $EVENT_CAP   = 5000;
    my $IP_CAP      = 50000;

    my $offset = $cache->{offset} // 0;
    if ( $size > $offset && open my $fh, '<', $log ) {
        seek $fh, $offset, 0;
        my @batch;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: process next time
            my $p = _parse_line($line) or next;
            push @batch, {
                day    => $p->{day},
                path   => $p->{path},
                status => $p->{status},
                class => classify( $p->{path}, $p->{ua}, $extra_ai, $extra_noise, $p->{status} ),
                # SM336: the user-agent was consumed by classify() and dropped.
                # The verdict is not the only thing it can answer.
                device => _device_class( $p->{ua} ),
                term   => ( $want_terms ? _search_term( $p->{query} ) : undef ),
                bytes  => ( ( $p->{bytes} // 0 ) + 0 ),            # SM335
                token  => _visitor_token( _anon_ip( $p->{ip} ) ),
                ref    => $p->{ref},
                t      => $p->{epoch},
            };
        }
        close $fh;
        $cache->{offset} = $size;
        _tally_batch( $cache, \@batch, $cfg );    # SM213: two-pass (scanner + 404 split)
    }

    return { ok_to_assemble => 1 };
}

# SM140: incremental first-party ingestion into the same day-bucket cache the
# server-log path uses. Day files are append-only, so a per-file byte offset
# is all the incremental state needed; pruned files simply drop out.
sub _export_ingest_first_party {
    my ( $cfg, $cache, $files ) = @_;
    if ( ( $cache->{v} // 0 ) != 2 || ref $cache->{files} ne 'HASH' ) {
        %{$cache} = ( v => 2, files => {}, days => {}, events => [] );
    }
    $cache->{days}   ||= {};
    $cache->{events} ||= [];

    my $extra_ai    = _split_csv( $cfg->{ai_user_agents} );
    my $want_terms  = _flag_on( $cfg->{search_terms} );    # SM336 item 7
    my $extra_noise = _split_csv( $cfg->{noise_paths} );

    my %live = map { (m{([^/]+)$})[0] => 1 } @{$files};
    delete @{ $cache->{files} }{ grep { !$live{$_} } keys %{ $cache->{files} } };

    my @batch;
    for my $f ( @{$files} ) {
        my ($base) = $f =~ m{([^/]+)$};
        my $size   = ( -s $f )              // 0;
        my $offset = $cache->{files}{$base} // 0;
        $offset = 0 if $offset > $size;                  # rewritten/truncated: reprocess
        next unless $size > $offset;
        open my $fh, '<', $f or next;
        seek $fh, $offset, 0;
        my $pos = $offset;
        $WORK{log_files_read}++;                         # SM342
        $WORK{log_bytes_read} += ( $size - $offset );    # SM342
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: next time
            $pos += length $line;
            my $r = eval { JSON::PP::decode_json($line) } or next;
            next unless ref $r eq 'HASH' && defined $r->{t};
            next if ( $r->{ch} // 'page' ) ne 'page';    # operator traffic out
            my $st = ( $r->{s} // 0 ) + 0;
            my @dt = gmtime( $r->{t} );
            push @batch, {
                day    => sprintf( '%04d-%02d-%02d', $dt[5] + 1900, $dt[4] + 1, $dt[3] ),
                path   => ( $r->{p} // '' ),
                status => $st,
                class => classify( ( $r->{p} // '' ), ( $r->{ua} // '' ), $extra_ai, $extra_noise, $st ),
                # SM336: same two facts, from the same user-agent, on the other
                # ingester - so a site with either log source answers the same
                # questions. The record's own path may carry a query too.
                device => _device_class( $r->{ua} // '' ),
                term   => (
                    $want_terms
                    ? _search_term( ( _split_query( $r->{p} // '' ) )[1] )
                    : undef
                ),
                token => ( $r->{v} // '' ),           # already an anonymised daily token
                bytes => ( ( $r->{b} // 0 ) + 0 ),    # SM335
                    # SM223: this request was REFUSED by an access decision. The
                    # status alone cannot say so - the anonymous refusal is a 302 to
                    # the login page, identical in the log to any other redirect.
                auth_refused => ( $r->{ar} ? 1 : 0 ),
                ref          => ( $r->{r} // '' ),
                t            => $r->{t} + 0,
            };
        }
        close $fh;
        $cache->{files}{$base} = $pos;
    }
    _tally_batch( $cache, \@batch, $cfg );    # SM213: two-pass (scanner + 404 split)
    return;
}

# SM216-2: fold the form-handler's append-only outcome log into the SAME
# day-buckets, so the durable rollups (and the report) show blocked-vs-stored
# per form. The form handler appends one JSON line per submission to
# lazysite/stats/form-events/<day>.jsonl {day,form,outcome[,reason]}; we track a
# per-file byte offset in the cache exactly as the first-party ingester does.
# The offset lives in the cache, so a cache reset (rotation / shape change) drops
# it alongside {days} and the events re-fold from zero into the rebuilt buckets -
# the aggregate stays idempotent. Counts only; no submission content is read.
sub _ingest_form_events {
    my ( $cache, $cfg ) = @_;
    my $dir = _stats_dir() . '/form-events';
    return unless -d $dir;
    opendir my $dh, $dir or return;
    my @files = sort grep { /^\d{4}-\d{2}-\d{2}\.jsonl\z/ } readdir $dh;
    closedir $dh;

    $cache->{form_files} ||= {};
    my %live = map { $_ => 1 } @files;
    delete @{ $cache->{form_files} }{ grep { !$live{$_} } keys %{ $cache->{form_files} } };

    for my $base (@files) {
        my $f      = "$dir/$base";
        my $size   = ( -s $f )                   // 0;
        my $offset = $cache->{form_files}{$base} // 0;
        $offset = 0 if $offset > $size;    # rewritten/truncated: reprocess
        next unless $size > $offset;
        open my $fh, '<', $f or next;
        seek $fh, $offset, 0;
        my $pos = $offset;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: next time
            $pos += length $line;
            my $r = eval { JSON::PP::decode_json($line) } or next;
            next unless ref $r eq 'HASH';
            my $day = $r->{day} // '';
            next unless $day =~ /^\d{4}-\d{2}-\d{2}\z/;
            my $form = $r->{form} // '';
            $form =~ s/[^a-zA-Z0-9_-]//g;
            next unless length $form;

            # Create the day-bucket with the full shape _tally_batch uses, so a
            # form-only day (blocks but no page traffic) is still safe for the
            # window loop and rollups.
            my $b = $cache->{days}{$day} ||= _new_day_bucket();
            my $fb = $b->{forms}{$form} ||= { stored => 0, quarantined => 0, blocked => {} };
            my $out = $r->{outcome} // '';
            if ( $out eq 'blocked' ) {
                my $reason = lc( $r->{reason} // 'other' );
                $reason =~ s/[^a-z_]//g;
                $reason ||= 'other';
                $fb->{blocked}{$reason}++;
            }
            elsif ( $out eq 'quarantined' ) { $fb->{quarantined}++; }
            elsif ( $out eq 'stored' )      { $fb->{stored}++; }
        }
        close $fh;
        $cache->{form_files}{$base} = $pos;
    }
    return;
}

sub _export_assemble {
    my ( $cfg, $cache, $window, $source ) = @_;
    my $EVENT_CAP = 5000;    # matches both ingesters' event-stream cap

    _ingest_form_events( $cache, $cfg );    # SM216-2: fold form outcomes in

    my $keep_from = _day_str( time() - 400 * 86400 );
    delete $cache->{days}{$_} for grep { $_ lt $keep_from } keys %{ $cache->{days} };
    # SM343: PERSIST FIRST, THEN SAVE. _persist_durable records which days it
    # has finalised, in the cache, so the marker has to exist before the cache
    # is written or it is lost every time and every closed day is rewritten on
    # every call - which is the write amplification the write-once rule existed
    # to avoid, reintroduced by the fix for it.
    _persist_durable( $cache, $cfg ); # SM213: mirror the day-buckets to the durable store
    _save_export_cache($cache);

    # --- assemble the window view from the day-buckets ---
    my $from_day  = _day_str( time() - ( $window - 1 ) * 86400 );
    my $cutoff_ep = time() - $window * 86400;
    my ( %cls, %uips, %pages, %status, %ref_ext, %nf_pl, %forms, @by_day );
    my %auth_ref;                     # SM223: paths a visitor was turned away from
    my ( $hits, $ref_internal, $ref_direct, $nf_junk ) = ( 0, 0, 0, 0 );

    for my $day ( sort keys %{ $cache->{days} } ) {
        next if $day lt $from_day;
        my $b = $cache->{days}{$day};
        for my $fn ( keys %{ $b->{forms} || {} } ) {    # SM216-2
            my $fb = $b->{forms}{$fn};
            $forms{$fn}{stored}      += $fb->{stored}      // 0;
            $forms{$fn}{quarantined} += $fb->{quarantined} // 0;
            $forms{$fn}{blocked}{$_} += $fb->{blocked}{$_} for keys %{ $fb->{blocked} || {} };
        }
        $cls{$_} += $b->{cls}{$_} for keys %{ $b->{cls} };
        $uips{$_} = 1 for keys %{ $b->{ips} };
        $pages{$_}    += $b->{pages}{$_}        for keys %{ $b->{pages} };
        $status{$_}   += $b->{status}{$_}       for keys %{ $b->{status} };
        $ref_ext{$_}  += $b->{ref_ext}{$_}      for keys %{ $b->{ref_ext} };
        $nf_pl{$_}    += $b->{nf_plausible}{$_} for keys %{ $b->{nf_plausible} || {} };
        $auth_ref{$_} += $b->{auth_refused}{$_} for keys %{ $b->{auth_refused} || {} };
        $hits         += $b->{hits}         // 0;
        $ref_internal += $b->{ref_internal} // 0;
        $ref_direct   += $b->{ref_direct}   // 0;
        $nf_junk      += $b->{nf_junk}      // 0;
        push @by_day, {
            date    => $day,
            human   => ( $b->{cls}{human}   // 0 ),
            ai      => ( $b->{cls}{ai}      // 0 ),
            bot     => ( $b->{cls}{bot}     // 0 ),
            noise   => ( $b->{cls}{noise}   // 0 ),
            scanner => ( $b->{cls}{scanner} // 0 ),
        };
    }

    my $total_cls = 0;
    $total_cls += $_ for values %cls;
    my %class_out;
    for my $c (@CLASSES) {    # SM330: derived, not a fifth hand-written copy
        my $v = $cls{$c} // 0;
        $class_out{$c} = {
            visits => $v,
            share  => ( $total_cls ? sprintf( '%.3f', $v / $total_cls ) + 0 : 0 ),
        };
    }

    my $top = sub {
        my ( $h, $n ) = @_;
        my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
        @k = @k[ 0 .. $n - 1 ] if @k > $n;
        return [ map { { key => $_, count => $h->{$_} } } @k ];
    };
    my $top_n = ( $cfg->{top_n} || 15 ) + 0;
    # SM340: an EXPLICIT projection, not the ring passed through. The ring is
    # internal working state and now carries fields the reconciliation below
    # needs - the referrer among them - which must not leave the machine
    # attached to a visitor token merely because they happen to be in the same
    # hash. Enumerating the output fields means adding one internally cannot
    # publish it by accident, which is SM330's lesson pointed the other way.
    my @events = map {
        { t => $_->{t},
            class   => $_->{class},
            path    => $_->{path},
            status  => $_->{status},
            visitor => $_->{visitor},
        }
    } grep { ( $_->{t} // 0 ) >= $cutoff_ep } @{ $cache->{events} };

    # SM213: the two horizons, stated explicitly so no consumer mistakes the capped
    # event SAMPLE for the (complete) aggregates. data_from = how far the durable
    # aggregates reach; sample = what the raw event ring actually covers.
    my @all_days = sort keys %{ $cache->{days} };
    my %month_pv;
    for my $day (@all_days) {
        my ($m) = $day =~ /^(\d{4}-\d{2})/;
        $month_pv{$m} += $cache->{days}{$day}{hits} // 0 if defined $m;
    }
    my @mk = sort keys %month_pv;
    my @months;
    for my $i ( 0 .. $#mk ) {
        my $prev = $i > 0 ? $month_pv{ $mk[ $i - 1 ] } : undef;
        push @months, {
            month           => $mk[$i],
            pageviews       => $month_pv{ $mk[$i] },
            delta_pageviews => ( defined $prev ? ( $month_pv{ $mk[$i] } - $prev ) : undef ),
        };
    }
    my ( $ev_from, $ev_to );
    for my $e ( @{ $cache->{events} } ) {
        my $t = $e->{t} // next;
        $ev_from = $t if !defined $ev_from || $t < $ev_from;
        $ev_to   = $t if !defined $ev_to   || $t > $ev_to;
    }

    # SM216-2: per-form delivery outcomes over the window - stored (delivered),
    # quarantined (stored but held from the bell), blocked (spam controls, by
    # reason). Lets the report say "controls stopped N" vs "nobody attacks us".
    my @form_delivery = map {
        my $fb = $forms{$_};
        my $bl = $fb->{blocked} || {};
        my $bt = 0;
        $bt += $_ for values %$bl;
        { form => $_,
            stored        => ( $fb->{stored}      // 0 ),
            quarantined   => ( $fb->{quarantined} // 0 ),
            blocked_total => $bt,
            blocked       => $bl,
        };
    } sort keys %forms;

    return {
        ok             => JSON::PP::true,
        schema_version => '2',
        source         => $source,
        generated      => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        window    => { days => $window, from => $from_day, to => _day_str( time() ) },
        data_from => ( @all_days ? $all_days[0] : undef ),
        totals => { human_visits => $hits, unique_visitors => scalar keys %uips, pageviews => $hits },
        traffic_classes => \%class_out,
        by_day          => \@by_day,
        months          => \@months,
        top_pages       => $top->( \%pages, $top_n ),
        referrers => { direct => $ref_direct, internal => $ref_internal, external => $top->( \%ref_ext, $top_n ) },
        status_codes => { map { ( $_ => $status{$_} ) } keys %status },
        not_found    => {
            plausible  => $top->( \%nf_pl, $top_n ),    # a human hit a missing page
            junk_count => $nf_junk,                     # scanner-chorus 404s (count only)
        },
        # SM223: paths a visitor was TURNED AWAY from, as opposed to paths that
        # were missing. A file appearing here that the operator believes is
        # public is the signal that an ACL entry written to govern authoring is
        # now also governing reading - the upgrade risk of extending the read
        # list to the public path, made visible whenever it bites rather than
        # only in the release notes of the version that changed it.
        auth_refused  => $top->( \%auth_ref, $top_n ),
        events        => \@events,
        form_delivery => \@form_delivery,    # SM216-2: blocked vs stored per form
        sample        => {
            from  => ( defined $ev_from ? _day_str($ev_from) : undef ),
            to    => ( defined $ev_to   ? _day_str($ev_to)   : undef ),
            count => scalar @{ $cache->{events} },
        },
        events_capped => ( @{ $cache->{events} } >= $EVENT_CAP ? JSON::PP::true : JSON::PP::false ),

        # SM342: the work this call did, so a regression in EFFORT is visible
        # without a stopwatch and without a fast disk to hide it.
        work  => {%WORK},
        notes =>
            'Aggregated, IP-anonymised, no filesystem paths. The aggregates (totals/by_day/months/top_pages) are complete over data_from..window.to; "events"/"sample" is a bounded recent SAMPLE, not the dataset.',
    };
}
