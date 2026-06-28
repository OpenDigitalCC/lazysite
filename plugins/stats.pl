#!/usr/bin/perl
# stats.pl - SM083: on-site visitor statistics from the web server access log.
#
# Read-only and out of band: it parses the access log (combined/common format)
# and returns aggregated stats; it never writes content. This complements the
# audit trail, which records material actions (auth, edits, deletes) - NOT
# browsing. Browsing analytics live here.
#
# Because lazysite uses no cookies or JS for analytics, every classification is a
# LOG-ONLY heuristic (UA + path + status), attributed at request granularity -
# it is an honest estimate, not authenticated identity.
#
# Invoked by the manager plugin API: `--describe` returns the contract;
# `--scan --docroot DIR` parses the log and prints the stats JSON;
# `--resolve-log --docroot DIR` prints the resolved log path for the (operator-
# only, server-internal) download endpoint - the path is never sent to the page.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX ();

my %arg;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--describe' )    { $arg{describe}    = 1 }
    elsif ( $a eq '--scan' )        { $arg{scan}        = 1 }
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
my $BOT_RE = qr{
    bot | crawl | spider | slurp | bingpreview | facebookexternalhit
  | headless | uptime | monitor | pingdom | curl | wget | python-requests
  | go-http | libwww | httpclient | scrapy | java/ | okhttp | axios
  | nuclei | nikto | masscan | zgrab | censys | nmap
}xi;

# AI assistants / model fetchers + the lazysite automation surface.
my $AI_RE = qr{
    GPTBot | ChatGPT | OAI-SearchBot | ClaudeBot | Claude-User | anthropic
  | PerplexityBot | Google-Extended | CCBot | Bytespider | Amazonbot
  | cohere-ai | Diffbot | Applebot-Extended | YouBot | meta-externalagent
}xi;

if ( $arg{describe} ) {
    print encode_json({
        id          => 'stats',
        name        => 'Visitor Stats',
        description => 'On-site visitor statistics from the web server access log '
                     . '(read-only). Classifies traffic into people, AI assistants, '
                     . 'bots and noise - all log-only heuristics, not authenticated. '
                     . 'Complements the audit trail, which records material actions.',
        version     => '2.0',
        config_file => 'lazysite/stats.conf',
        config_schema => [
            { key => 'access_log',   label => 'Access log path', type => 'text', default => '',
              note => 'Combined-format access log. Blank = auto-detect (on Hestia, ../logs/<domain>.log). The CGI user must be able to read it.' },
            { key => 'window_days',  label => 'Window (days)',           type => 'text',    default => '30' },
            { key => 'top_n',        label => 'Top N (pages / referrers)', type => 'text',  default => '15' },
            { key => 'anonymise_ip', label => 'Anonymise visitor IPs',   type => 'boolean', default => 'true' },
            { key => 'ai_user_agents', label => 'Extra AI user-agents', type => 'text', default => '',
              note => 'Comma-separated UA substrings to also count as AI assistants, on top of the built-ins (GPTBot, ClaudeBot, anthropic, ...).' },
            { key => 'noise_paths', label => 'Extra noise paths', type => 'text', default => '',
              note => 'Comma-separated path prefixes to treat as probe/scanner noise, on top of the built-ins (/wp-login.php, /.env, *.php, ...).' },
            { key => 'offer_log_download', label => 'Offer raw log download', type => 'boolean', default => 'true' },
        ],
        actions => [ { id => 'refresh', label => 'Refresh stats' } ],
    });
    exit 0;
}

if ( $arg{resolve_log} ) {
    my $log = find_log( read_conf() );
    print encode_json({ ok => ( length $log ? JSON::PP::true : JSON::PP::false ),
                        configured => ( length $log ? JSON::PP::true : JSON::PP::false ),
                        path => $log });   # server-internal only; never shown to the page
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
    return $cfg->{access_log} if defined $cfg->{access_log} && length $cfg->{access_log};

    my $domain = _site_domain();
    return '' unless length $domain;

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
    }
    return '';
}

# Autoconfig: persist a freshly auto-detected log path to stats.conf so the
# Plugin Config page shows it and later scans skip the candidate search.
sub _save_access_log {
    my ($path) = @_;
    my $f = "$DOCROOT/lazysite/stats.conf";
    my @lines;
    if ( open my $fh, '<', $f ) { @lines = <$fh>; close $fh; }
    my $found = 0;
    for my $l (@lines) {
        if ( $l =~ /^\s*access_log\s*:/ ) { $l = "access_log: $path\n"; $found = 1; }
    }
    push @lines, "access_log: $path\n" unless $found;
    if ( open my $wf, '>', $f ) { print {$wf} @lines; close $wf; }
    return;
}

sub _is_browser {
    my ($ua) = @_;
    return $ua =~ /Mozilla|Chrome|Safari|Firefox|Edge|Opera|Gecko/i ? 1 : 0;
}

# Returns one of: noise, ai, bot, logged_in, human. First match wins.
sub classify {
    my ( $path, $ua, $extra_ai, $extra_noise ) = @_;

    return 'noise' if $path =~ $NOISE_RE;
    return 'noise' if $path =~ m{\.php(?:[?/]|$)}i;      # PHP-less site: any .php is a probe
    if ($extra_noise) {
        for my $p (@$extra_noise) { return 'noise' if length $p && index( $path, $p ) == 0 }
    }

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

sub scan_stats {
    my $cfg = read_conf();
    my $detected = !( defined $cfg->{access_log} && length $cfg->{access_log} );
    my $log = find_log($cfg);
    return { ok => 0, needs_config => JSON::PP::true,
        error => 'No access log found for this site automatically. Set the access-log path '
               . 'in the plugin config (on Hestia it is usually ../logs/<domain>.log).' }
        unless length $log;
    return { ok => 0, needs_config => JSON::PP::true,
        error => 'Access log is not readable. The CGI user (www-data) may lack permission; '
               . 'check the path on the Plugin Config page.' }
        unless -r $log;
    _save_access_log($log) if $detected;   # autoconfig: remember what we found

    my $window = ( $cfg->{window_days}  || 30 ) + 0;  $window = 30 if $window < 1;
    my $top_n  = ( $cfg->{top_n}        || 15 ) + 0;  $top_n  = 15 if $top_n < 1;
    my $anon   = !( defined $cfg->{anonymise_ip} && lc( $cfg->{anonymise_ip} ) eq 'false' );
    my $extra_ai    = _split_csv( $cfg->{ai_user_agents} );
    my $extra_noise = _split_csv( $cfg->{noise_paths} );
    my $offer_dl    = !( defined $cfg->{offer_log_download}
                         && lc( $cfg->{offer_log_download} ) eq 'false' );
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
        next unless $line =~ m{^(\S+) \S+ \S+ \[([^\]]+)\] "\S+ (\S+) [^"]*" (\d{3}) (\S+) "([^"]*)" "([^"]*)"};
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
        window_days     => $window,
        scanned_lines   => $scanned,
        capped          => ( $scanned > $CAP ? JSON::PP::true : JSON::PP::false ),
        anonymised      => ( $anon ? JSON::PP::true : JSON::PP::false ),
        log_configured  => JSON::PP::true,                 # never the disk path
        log_download    => ( $offer_dl ? JSON::PP::true : JSON::PP::false ),
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
