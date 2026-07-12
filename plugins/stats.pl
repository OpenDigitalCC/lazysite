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
use POSIX ();

my %arg;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--describe' )    { $arg{describe}    = 1 }
    elsif ( $a eq '--scan' )        { $arg{scan}        = 1 }
    elsif ( $a eq '--export' )      { $arg{export}      = 1 }
    elsif ( $a eq '--window' )      { $arg{window}      = shift @ARGV }
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

# AI assistants / model fetchers + the lazysite automation surface.
my $AI_RE = qr{
    GPTBot | ChatGPT | OAI-SearchBot | ClaudeBot | Claude-User | anthropic
  | PerplexityBot | Google-Extended | CCBot | Bytespider | Amazonbot
  | cohere-ai | Diffbot | Applebot-Extended | YouBot | meta-externalagent
}xi;

# Month-name map for log-date parsing. Declared up here (like the regexes above)
# so it is assigned BEFORE the dispatch below ever calls export_stats().
my @MONTHS_X = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %MON_X = map { $MONTHS_X[$_] => $_ } 0 .. 11;

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
                { key => 'anonymise_ip', label => 'Anonymise visitor IPs', type => 'boolean', default => 'true' },
                { key => 'ai_user_agents', label => 'Extra AI user-agents', type => 'text', default => '',
                    note => 'Comma-separated UA substrings to also count as AI assistants, on top of the built-ins (GPTBot, ClaudeBot, anthropic, ...).' },
                { key => 'noise_paths', label => 'Extra noise paths', type => 'text', default => '',
                    note => 'Comma-separated path prefixes to treat as probe/scanner noise, on top of the built-ins (/wp-login.php, /.env, *.php, ...).' },
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
    print encode_json({ ok => ( length $log ? JSON::PP::true : JSON::PP::false ),
                        configured => ( length $log ? JSON::PP::true : JSON::PP::false ),
                        path => $log });   # server-internal only; never shown to the page
    exit 0;
}

if ( $arg{export} ) {
    print encode_json( export_stats( $arg{window} ) );
    exit 0;
}

if ( $arg{scan} ) {
    print encode_json( scan_stats() );
    exit 0;
}

print encode_json({ ok => 0, error => 'usage: --describe | --scan --docroot DIR | --resolve-log --docroot DIR' });
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
    $host =~ s/:\d+$//;            # strip a port
    $host =~ s/^www\.//i;          # www-agnostic
    if ( $host !~ /^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/ ) {    # not a real host (e.g. ${SERVER_NAME})
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
        return $c if -r $c;
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
    my ($line) = @_;
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
    my ( $path, $ua, $extra_ai, $extra_noise ) = @_;

    return 'noise' if $path =~ $NOISE_RE;
    return 'noise' if $path =~ $INFRA_RE;                # favicon/robots/sitemap/feed
    return 'noise' if $path =~ m{\.php(?:[?/]|$)}i;      # PHP-less site: any .php is a probe
    if ($extra_noise) {
        for my $p (@$extra_noise) { return 'noise' if length $p && index( $path, $p ) == 0 }
    }

    # Self-identifying lazysite tooling (screenshots/QA/previews) is automation,
    # never a human visitor - honour the opt-out UA convention before anything else.
    return 'bot' if $ua =~ $AGENT_RE;

    my $is_auto_ep = $path =~ m{^/cgi-bin/lazysite-(?:mcp|manager-api|dav)\.pl}i;
    my $is_mgr     = $path =~ m{^/manager(?:/|$)}i
                  || $path =~ m{^/cgi-bin/lazysite-auth\.pl}i;
    my $browser    = _is_browser($ua);

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

sub scan_first_party {
    my ( $cfg, @files ) = @_;
    require JSON::PP;

    my $window = ( $cfg->{window_days} || 30 ) + 0;
    $window = 30 if $window < 1;
    my $top_n = ( $cfg->{top_n} || 15 ) + 0;
    $top_n = 15 if $top_n < 1;
    my $extra_ai    = _split_csv( $cfg->{ai_user_agents} );
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $site_host   = _site_domain();
    my $cutoff      = time() - $window * 86400;

    my ( %cls_hits, %cls_vis, %pages, %ref_ext, %status, %byday, %vis );
    my ( $hits, $bytes )              = ( 0, 0 );
    my ( $ref_internal, $ref_direct ) = ( 0, 0 );
    my $scanned = 0;
    my $CAP     = 10_000_000;    # runaway guard; aggregates use bounded memory

FILE: for my $f (@files) {
        # Filename-dated: skip whole files older than the window (day grain).
        next unless $f =~ /access-(\d{4})(\d{2})(\d{2})[.]jsonl$/;
        my $day_end = eval { POSIX::mktime( 59, 59, 23, $3, $2 - 1, $1 - 1900 ) };
        next if defined $day_end && $day_end < $cutoff;
        open my $fh, '<', $f or next;
        while ( my $line = <$fh> ) {
            last FILE if ++$scanned > $CAP;
            my $r = eval { JSON::PP::decode_json($line) } or next;
            next unless ref $r eq 'HASH';
            next unless ( $r->{t} // 0 ) >= $cutoff;
            next if ( $r->{ch} // 'page' ) ne 'page';    # operator traffic out

            my $path = $r->{p} // '';
            my $st   = ( $r->{s} // 0 ) + 0;
            my $ua   = $r->{ua} // '';
            my $v    = $r->{v}  // '';

            my $class = classify( $path, $ua, $extra_ai, $extra_noise );
            $cls_hits{$class}++;
            $cls_vis{$class}{$v} = 1 if length $v;

            # Headline = the genuine human audience only (as the server path).
            next unless $class eq 'human';

            $hits++;
            $bytes += ( $r->{b} // 0 ) + 0;
            $vis{$v} = 1 if length $v;
            $status{$st}++;
            my @d = gmtime( $r->{t} );
            $byday{ sprintf '%04d-%02d-%02d', $d[5] + 1900, $d[4] + 1, $d[3] }++;
            $pages{$path}++ if $st < 400
                && $path !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b};

            my $ref = $r->{r} // '';
            if ( !length $ref || $ref eq '-' ) {
                $ref_direct++;
            }
            elsif ( $ref =~ m{^\S+?://([^/\s]+)} ) {
                ( my $rh = $1 ) =~ s/^www\.//i;
                if ( length $site_host
                    && ( lc $rh eq lc $site_host || $rh =~ /\Q$site_host\E$/i ) )
                {
                    $ref_internal++;    # self-referrer (on-site navigation)
                }
                else { $ref_ext{$ref}++ }
            }
        }
        close $fh;
    }

    my $top = sub {
        my ($h) = @_;
        my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
        @k = @k[ 0 .. ( $top_n - 1 ) ] if @k > $top_n;
        return [ map { { key => $_, count => $h->{$_} } } @k ];
    };
    my %classes;
    for my $c (qw(human ai bot noise logged_in)) {
        $classes{$c} = {
            hits     => $cls_hits{$c} // 0,
            visitors => scalar keys %{ $cls_vis{$c} || {} },
        };
    }

    return {
        ok              => 1,
        source          => 'first-party',
        window_days     => $window,
        scanned_lines   => $scanned,
        capped          => ( $scanned > $CAP ? JSON::PP::true : JSON::PP::false ),
        anonymised      => JSON::PP::true,         # always, at write time
        log_configured  => JSON::PP::true,
        errors          => _error_surface($cfg),
        classes         => \%classes,
        hits            => $hits,                  # human only
        unique_visitors => scalar keys %vis,       # distinct daily visitor keys
        bytes           => $bytes,
        top_pages       => $top->( \%pages ),
        referrers       => {
            external => $top->( \%ref_ext ),
            internal => $ref_internal,
            direct   => $ref_direct,
        },
        status  => { map { ( $_  => $status{$_} ) } keys %status },
        per_day => [ map { { day => $_, count => $byday{$_} } } sort keys %byday ],
    };
}

sub scan_stats {
    my $cfg = read_conf();

    # SM140: first-party data wins - zero-setup, complete for page views.
    # The web-server log survives as the fallback (and future enrichment).
    my @fp = first_party_files();
    return scan_first_party( $cfg, @fp ) if @fp;

    my $log = find_log($cfg);
    return { ok => 0, needs_config => JSON::PP::true,
        error => 'No access log found for this site. The log path is auto-detected, '
               . 'or set by the server owner at install time (LAZYSITE_ACCESS_LOG); '
               . 'a site manager cannot configure it. Ask the server owner to set it up.' }
        unless length $log;
    return { ok => 0, needs_config => JSON::PP::true,
        error => 'An access log exists for this site but is not readable by the '
            . 'web-server user. Ask the server owner to grant read access; they '
            . 'can see the detected path with '
            . '"plugins/stats.pl --resolve-log --docroot <docroot>".' }
        unless -r $log;

    my $window = ( $cfg->{window_days}  || 30 ) + 0;  $window = 30 if $window < 1;
    my $top_n  = ( $cfg->{top_n}        || 15 ) + 0;  $top_n  = 15 if $top_n < 1;
    my $anon   = !( defined $cfg->{anonymise_ip} && lc( $cfg->{anonymise_ip} ) eq 'false' );
    my $extra_ai    = _split_csv( $cfg->{ai_user_agents} );
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $site_host   = _site_domain();
    my $cutoff = time() - $window * 86400;

    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my %mon = map { $months[$_] => $_ } 0 .. 11;

    open my $fh, '<', $log or return { ok => 0, error => "Cannot open the access log: $!" };
    my ( %cls_hits, %cls_ips, %pages, %ref_ext, %status, %byday );
    my ( $hits, $bytes, %ips ) = ( 0, 0 );
    my ( $ref_internal, $ref_direct ) = ( 0, 0 );
    my $scanned = 0;
    my $CAP = 10_000_000;   # runaway guard; aggregates use bounded memory
    while ( my $line = <$fh> ) {
        last if ++$scanned > $CAP;
        next unless $line =~ m{
            ^(\S+)\ \S+\ \S+          # remote host (1), ident, authuser
            \ \[([^\]]+)\]            # [date] (2)
            \ "\S+\ (\S+)\ [^"]*"     # "method  path(3)  protocol"
            \ (\d{3})\ (\S+)          # status (4), bytes (5)
            \ "([^"]*)"\ "([^"]*)"    # "referer(6)"  "user-agent(7)"
        }x;
        my ( $ip, $date, $path, $st, $bs, $ref, $ua ) = ( $1, $2, $3, $4, $5, $6, $7 );
        next unless $date =~ m{^(\d+)/(\w+)/(\d+):(\d+):(\d+):(\d+)} && exists $mon{$2};
        my ( $d, $mo, $y, $H, $Mi, $S ) = ( $1, $2, $3, $4, $5, $6 );
        my $epoch = eval { POSIX::mktime( $S, $Mi, $H, $d, $mon{$mo}, $y - 1900 ) };
        next unless defined $epoch && $epoch >= $cutoff;

        my $class = classify( $path, $ua, $extra_ai, $extra_noise );
        ( my $ipk = $ip ) =~ s/\.\d+$/.0/ if $anon && $ip =~ /\./;   # zero last IPv4 octet
        my $ipkey = $anon ? $ipk : $ip;

        $cls_hits{$class}++;
        $cls_ips{$class}{$ipkey} = 1;

        # The headline (totals, pages, trend, referrers) is the genuine human
        # audience only; the other classes are reported separately.
        next unless $class eq 'human';

        $hits++;
        $bytes += ( $bs =~ /^\d+$/ ? $bs : 0 );
        $ips{$ipkey} = 1;
        $status{$st}++;
        $byday{ sprintf '%04d-%02d-%02d', $y, $mon{$mo} + 1, $d }++;
        $pages{$path}++ if $st < 400
            && $path !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b};

        if ( !length $ref || $ref eq '-' ) {
            $ref_direct++;
        }
        elsif ( $ref =~ m{^\S+?://([^/\s]+)} ) {
            ( my $rh = $1 ) =~ s/^www\.//i;
            if ( length $site_host && ( lc $rh eq lc $site_host || $rh =~ /\Q$site_host\E$/i ) ) {
                $ref_internal++;   # self-referrer (on-site navigation)
            }
            else { $ref_ext{$ref}++ }
        }
    }
    close $fh;

    my $errors = _error_surface($cfg);

    my $top = sub {
        my ($h) = @_;
        my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
        @k = @k[ 0 .. ( $top_n - 1 ) ] if @k > $top_n;
        return [ map { { key => $_, count => $h->{$_} } } @k ];
    };

    my %classes;
    for my $c (qw(human ai bot noise logged_in)) {
        $classes{$c} = {
            hits     => $cls_hits{$c} // 0,
            visitors => scalar keys %{ $cls_ips{$c} || {} },
        };
    }

    return {
        ok              => 1,
        source          => 'server-log',
        window_days     => $window,
        scanned_lines   => $scanned,
        capped          => ( $scanned > $CAP ? JSON::PP::true : JSON::PP::false ),
        anonymised      => ( $anon ? JSON::PP::true : JSON::PP::false ),
        log_configured  => JSON::PP::true,                 # never the disk path
        errors          => $errors,
        classes         => \%classes,
        hits            => $hits,                          # human only
        unique_visitors => scalar keys %ips,               # human only
        bytes           => $bytes,
        top_pages       => $top->( \%pages ),
        referrers       => {
            external => $top->( \%ref_ext ),
            internal => $ref_internal,
            direct   => $ref_direct,
        },
        status          => { map { ( $_ => $status{$_} ) } keys %status },
        per_day         => [ map { { day => $_, count => $byday{$_} } } sort keys %byday ],
    };
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
    my ( $ip, $date, $path, $st, $bs, $ref, $ua ) = ( $1, $2, $3, $4, $5, $6, $7 );
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
        status => $st + 0,
        ref    => $ref,
        ua     => $ua,
    };
}

sub _anon_ip {
    my ($ip) = @_;
    $ip =~ s/\.\d+$/.0/;    # zero the last IPv4 octet (no-op for a non-dotted addr)
    return $ip;
}

# A short, non-reversible token for grouping events by visitor at NETWORK level
# (the address is already truncated to its /24 before hashing).
sub _visitor_token {
    require Digest::SHA;
    return substr( Digest::SHA::sha256_hex( $_[0] ), 0, 12 );
}

sub _day_str { return POSIX::strftime( '%Y-%m-%d', localtime( $_[0] ) ) }

sub _cache_path { return "$DOCROOT/lazysite/cache/stats-export.json" }

sub _load_export_cache {
    open my $fh, '<', _cache_path() or return undef;
    local $/;
    my $j = <$fh>;
    close $fh;
    my $c = eval { JSON::PP::decode_json($j) };
    return ( ref $c eq 'HASH' && ( $c->{v} // 0 ) == 1 ) ? $c : undef;
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

    my $log = find_log($cfg);
    return {
        ok           => 0,
        needs_config => JSON::PP::true,
        error        => 'No access log is configured for this site.',
    } unless length $log && -r $log;

    my @st = stat($log);
    my ( $inode, $size ) = ( $st[1], $st[7] );

    # Rotation / truncation: a different inode, or the file is now smaller than our
    # offset, means the offset is untrustworthy - reprocess from the start. (A v2
    # first-party cache lands here too and resets to the server-log shape.)
    if ( ( $cache->{inode} // -1 ) != $inode || ( $cache->{offset} // 0 ) > $size ) {
        $cache = { v => 1, inode => $inode, offset => 0, days => {}, events => [] };
    }
    $cache->{v}     = 1;
    $cache->{inode} = $inode;
    $cache->{days}   ||= {};
    $cache->{events} ||= [];

    my $extra_ai    = _split_csv( $cfg->{ai_user_agents} );
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $site_host   = _site_domain();
    my $EVENT_CAP   = 5000;
    my $IP_CAP      = 50000;

    my $offset = $cache->{offset} // 0;
    if ( $size > $offset && open my $fh, '<', $log ) {
        seek $fh, $offset, 0;
        my $pos = $offset;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;   # incomplete final line: process next time
            $pos += length $line;          # advance only past COMPLETE lines
            my $p = _parse_line($line) or next;
            my $class = classify( $p->{path}, $p->{ua}, $extra_ai, $extra_noise );
            my $b = $cache->{days}{ $p->{day} } ||= {
                cls => {}, ips => {}, hits => 0, pages => {}, status => {},
                ref_ext => {}, ref_internal => 0, ref_direct => 0,
            };
            $b->{cls}{$class}++;
            my $ipk = _anon_ip( $p->{ip} );
            $b->{ips}{$ipk} = 1 if keys %{ $b->{ips} } < $IP_CAP;

            if ( $class eq 'human' ) {
                $b->{hits}++;
                $b->{status}{ $p->{status} }++;
                $b->{pages}{ $p->{path} }++
                    if $p->{status} < 400
                    && $p->{path} !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b};
                my $ref = $p->{ref};
                if    ( !length $ref || $ref eq '-' ) { $b->{ref_direct}++ }
                elsif ( $ref =~ m{^\S+?://([^/\s]+)} ) {
                    ( my $rh = $1 ) =~ s/^www\.//i;
                    if ( length $site_host
                        && ( lc $rh eq lc $site_host || $rh =~ /\Q$site_host\E$/i ) )
                    {
                        $b->{ref_internal}++;
                    }
                    else { $b->{ref_ext}{$rh}++ }
                }
            }

            push @{ $cache->{events} }, {
                t       => $p->{epoch},
                class   => $class,
                path    => $p->{path},
                status  => $p->{status},
                visitor => _visitor_token($ipk),
            };
            shift @{ $cache->{events} } while @{ $cache->{events} } > $EVENT_CAP;
        }
        close $fh;
        $cache->{offset} = $size;
    }

    return _export_assemble( $cfg, $cache, $window, 'server-log' );
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
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $site_host   = _site_domain();
    my $EVENT_CAP   = 5000;
    my $VIS_CAP     = 50000;

    my %live = map { (m{([^/]+)$})[0] => 1 } @{$files};
    delete @{ $cache->{files} }{ grep { !$live{$_} } keys %{ $cache->{files} } };

    for my $f ( @{$files} ) {
        my ($base) = $f =~ m{([^/]+)$};
        my $size   = ( -s $f )              // 0;
        my $offset = $cache->{files}{$base} // 0;
        $offset = 0 if $offset > $size;    # rewritten/truncated: reprocess
        next unless $size > $offset;
        open my $fh, '<', $f or next;
        seek $fh, $offset, 0;
        my $pos = $offset;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: next time
            $pos += length $line;
            my $r = eval { JSON::PP::decode_json($line) } or next;
            next unless ref $r eq 'HASH' && defined $r->{t};
            next if ( $r->{ch} // 'page' ) ne 'page';    # operator traffic out
            my $path  = $r->{p} // '';
            my $st    = ( $r->{s} // 0 ) + 0;
            my $ua    = $r->{ua} // '';
            my $v     = $r->{v}  // '';
            my $class = classify( $path, $ua, $extra_ai, $extra_noise );
            my @dt    = gmtime( $r->{t} );
            my $day   = sprintf '%04d-%02d-%02d', $dt[5] + 1900, $dt[4] + 1, $dt[3];
            my $b     = $cache->{days}{$day} ||= {
                cls     => {}, ips          => {}, hits => 0, pages => {}, status => {},
                ref_ext => {}, ref_internal => 0,  ref_direct => 0,
            };
            $b->{cls}{$class}++;
            $b->{ips}{$v} = 1 if length $v && keys %{ $b->{ips} } < $VIS_CAP;

            if ( $class eq 'human' ) {
                $b->{hits}++;
                $b->{status}{$st}++;
                $b->{pages}{$path}++
                    if $st < 400
                    && $path !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b};
                my $ref = $r->{r} // '';
                if    ( !length $ref || $ref eq '-' ) { $b->{ref_direct}++ }
                elsif ( $ref =~ m{^\S+?://([^/\s]+)} ) {
                    ( my $rh = $1 ) =~ s/^www\.//i;
                    if ( length $site_host
                        && ( lc $rh eq lc $site_host || $rh =~ /\Q$site_host\E$/i ) )
                    {
                        $b->{ref_internal}++;
                    }
                    else { $b->{ref_ext}{$rh}++ }
                }
            }

            # The visitor key is already an anonymised daily token - use it
            # directly as the event's visitor identity.
            push @{ $cache->{events} }, {
                t       => $r->{t} + 0,
                class   => $class,
                path    => $path,
                status  => $st,
                visitor => $v,
            };
            shift @{ $cache->{events} } while @{ $cache->{events} } > $EVENT_CAP;
        }
        close $fh;
        $cache->{files}{$base} = $pos;
    }
    return;
}

# Shared tail: cache retention + save, then assemble the window view from the
# day-buckets. Identical for both ingestion sources.
sub _export_assemble {
    my ( $cfg, $cache, $window, $source ) = @_;
    my $EVENT_CAP = 5000;    # matches both ingesters' event-stream cap

    my $keep_from = _day_str( time() - 400 * 86400 );
    delete $cache->{days}{$_} for grep { $_ lt $keep_from } keys %{ $cache->{days} };
    _save_export_cache($cache);

    # --- assemble the window view from the day-buckets ---
    my $from_day  = _day_str( time() - ( $window - 1 ) * 86400 );
    my $cutoff_ep = time() - $window * 86400;
    my ( %cls, %uips, %pages, %status, %ref_ext, @by_day );
    my ( $hits, $ref_internal, $ref_direct ) = ( 0, 0, 0 );

    for my $day ( sort keys %{ $cache->{days} } ) {
        next if $day lt $from_day;
        my $b = $cache->{days}{$day};
        $cls{$_}     += $b->{cls}{$_}     for keys %{ $b->{cls} };
        $uips{$_} = 1                     for keys %{ $b->{ips} };
        $pages{$_}   += $b->{pages}{$_}   for keys %{ $b->{pages} };
        $status{$_}  += $b->{status}{$_}  for keys %{ $b->{status} };
        $ref_ext{$_} += $b->{ref_ext}{$_} for keys %{ $b->{ref_ext} };
        $hits         += $b->{hits}         // 0;
        $ref_internal += $b->{ref_internal} // 0;
        $ref_direct   += $b->{ref_direct}   // 0;
        push @by_day, {
            date  => $day,
            human => ( $b->{cls}{human} // 0 ),
            ai    => ( $b->{cls}{ai}    // 0 ),
            bot   => ( $b->{cls}{bot}   // 0 ),
            noise => ( $b->{cls}{noise} // 0 ),
        };
    }

    my $total_cls = 0;
    $total_cls += $_ for values %cls;
    my %class_out;
    for my $c (qw(human ai bot noise)) {
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
    my @events = grep { ( $_->{t} // 0 ) >= $cutoff_ep } @{ $cache->{events} };

    return {
        ok              => JSON::PP::true,
        schema_version  => '1',
        source         => $source,
        generated       => POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        window          => { days => $window, from => $from_day, to => _day_str( time() ) },
        totals          => { human_visits => $hits, unique_visitors => scalar keys %uips, pageviews => $hits },
        traffic_classes => \%class_out,
        by_day          => \@by_day,
        top_pages       => $top->( \%pages, $top_n ),
        referrers       => { direct => $ref_direct, internal => $ref_internal, external => $top->( \%ref_ext, $top_n ) },
        status_codes    => { map { ( $_ => $status{$_} ) } keys %status },
        events          => \@events,
        events_capped   => ( @{ $cache->{events} } >= $EVENT_CAP ? JSON::PP::true : JSON::PP::false ),
        notes           => 'Aggregated, IP-anonymised, no filesystem paths. Log-only heuristics; not authenticated.',
    };
}
