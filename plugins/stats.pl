#!/usr/bin/perl
# stats.pl - SM083: on-site visitor statistics from the web server access log.
#
# Read-only and out of band: it parses the access log (combined/common format)
# and returns aggregated stats; it never writes content. This complements the
# audit trail, which records material actions (auth, edits, deletes) - NOT
# browsing. Browsing analytics live here.
#
# Invoked by the manager plugin API: `--describe` returns the contract;
# `--scan --docroot DIR` parses the log and prints the stats JSON.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX ();

my %arg;
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--describe' ) { $arg{describe} = 1 }
    elsif ( $a eq '--scan' )     { $arg{scan}     = 1 }
    elsif ( $a eq '--docroot' )  { $arg{docroot}  = shift @ARGV }
}
my $DOCROOT = $arg{docroot} || $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '.';

if ( $arg{describe} ) {
    print encode_json({
        id          => 'stats',
        name        => 'Visitor Stats',
        description => 'On-site visitor statistics from the web server access log '
                     . '(read-only). Complements the audit trail, which records '
                     . 'material actions only - not browsing.',
        version     => '1.0',
        config_file => 'lazysite/stats.conf',
        config_schema => [
            { key => 'access_log',   label => 'Access log path', type => 'text', default => '',
              note => 'Combined-format access log. Blank = auto-detect (on Hestia, ../logs/<domain>.log). The CGI user must be able to read it.' },
            { key => 'window_days',  label => 'Window (days)',           type => 'text',    default => '30' },
            { key => 'top_n',        label => 'Top N (pages / referrers)', type => 'text',  default => '15' },
            { key => 'anonymise_ip', label => 'Anonymise visitor IPs',   type => 'boolean', default => 'true' },
            { key => 'exclude_bots', label => 'Exclude bots / crawlers',  type => 'boolean', default => 'true' },
        ],
        actions => [ { id => 'refresh', label => 'Refresh stats' } ],
    });
    exit 0;
}

if ( $arg{scan} ) {
    print encode_json( scan_stats() );
    exit 0;
}

print encode_json({ ok => 0, error => 'usage: --describe | --scan --docroot DIR' });
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
# site's log in a shared directory. From lazysite.conf site_url, else the Hestia
# docroot layout (/home/<user>/web/<domain>/public_html).
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

sub scan_stats {
    my $cfg = read_conf();
    my $detected = !( defined $cfg->{access_log} && length $cfg->{access_log} );
    my $log = find_log($cfg);
    return { ok => 0, needs_config => JSON::PP::true,
        error => 'No access log found for this site automatically. Set the access-log path '
               . 'in the plugin config (on Hestia it is usually ../logs/<domain>.log).' }
        unless length $log;
    return { ok => 0, error => "Access log not readable: $log - the CGI user (www-data) may lack "
           . "read access; grant it or point at a readable copy." } unless -r $log;
    _save_access_log($log) if $detected;   # autoconfig: remember what we found

    my $window = ( $cfg->{window_days} || 30 ) + 0;  $window = 30 if $window < 1;
    my $top_n  = ( $cfg->{top_n}       || 15 ) + 0;  $top_n  = 15 if $top_n < 1;
    my $anon   = !( defined $cfg->{anonymise_ip} && lc( $cfg->{anonymise_ip} ) eq 'false' );
    my $nobots = !( defined $cfg->{exclude_bots} && lc( $cfg->{exclude_bots} ) eq 'false' );
    my $cutoff = time() - $window * 86400;

    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my %mon = map { $months[$_] => $_ } 0 .. 11;

    open my $fh, '<', $log or return { ok => 0, error => "Cannot open $log: $!" };
    my ( $hits, $bytes, %ips, %pages, %refs, %status, %byday );
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
        next if $nobots && $ua =~ /bot|crawl|spider|slurp|bingpreview|facebookexternalhit|headless|monitor/i;

        $hits++;
        $bytes += ( $bs =~ /^\d+$/ ? $bs : 0 );
        ( my $ipk = $ip ) =~ s/\.\d+$/.0/ if $anon && $ip =~ /\./;   # zero last IPv4 octet
        $ips{ $anon ? $ipk : $ip } = 1;
        $status{$st}++;
        $byday{ sprintf '%04d-%02d-%02d', $y, $mon{$mo} + 1, $d }++;
        $pages{$path}++ if $st < 400
            && $path !~ m{^/(?:cgi-bin|lazysite-assets|dav|manager|login|logout)\b};
        $refs{$ref}++ if length $ref && $ref ne '-';
    }
    close $fh;

    my $top = sub {
        my ($h) = @_;
        my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
        @k = @k[ 0 .. ( $top_n - 1 ) ] if @k > $top_n;
        return [ map { { key => $_, count => $h->{$_} } } @k ];
    };

    return {
        ok              => 1,
        log             => $log,
        window_days     => $window,
        scanned_lines   => $scanned,
        capped          => ( $scanned > $CAP ? JSON::PP::true : JSON::PP::false ),
        anonymised      => ( $anon ? JSON::PP::true : JSON::PP::false ),
        hits            => $hits // 0,
        unique_visitors => scalar keys %ips,
        bytes           => $bytes // 0,
        top_pages       => $top->( \%pages ),
        top_referrers   => $top->( \%refs ),
        status          => { map { ( $_ => $status{$_} ) } keys %status },
        per_day         => [ map { { day => $_, count => $byday{$_} } } sort keys %byday ],
    };
}
