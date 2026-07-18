package Lazysite::Manager::Domains;

# SM154 (P2): the domain engine - register / list / configure / remove the
# domains this one lazysite instance serves. A domain is `alias_hosts` (the
# comma list of served hosts) + `alias.<host>.<key>` overrides in
# lazysite.conf, plus a content-root directory under the docroot. This module
# is the SINGLE source of that logic, shared by the manager control-API
# (domain-* actions) and the `lazysite-domains` CLI, so an external control
# panel can drive the lazysite side identically to the UI.
#
# HARD SCOPE LINE: lazysite owns only the lazysite side (conf + content root).
# DNS, the web-server domain alias and TLS are a PRECONDITION handled by the
# operator / Hestia / an external orchestrator - this module never touches
# them.

use strict;
use warnings;
use Cwd                       qw(realpath);
use File::Path                qw(make_path);
use Lazysite::Util            qw(log_event);
use Lazysite::Manager::Common qw(path_is_reserved);
use Exporter 'import';
our @EXPORT_OK = qw(domains_list domains_using domain_add domain_remove domain_set domain_check instance_public_ips);

our $DOCROOT;           # set by the caller (manager-api or the CLI)
our $auth_user = '';    # for log attribution

# Per-host presentation/routing keys that may be overridden for an alias. Same
# set the read-only view (action_domains_list) surfaces and domain_set accepts.
# content_root is the one that actually roots a domain's content; the rest are
# presentation. SM165 adds the two ACCESS keys: allowed_groups (comma list of
# groups that may manage this domain) and locked_users (comma list of accounts
# confined to it). SM179 adds the language keys: lang (this host's language) and
# lang_group (the language set it belongs to) - so a language set is configurable
# through the Domains page / control API / CLI, not only by hand-editing the conf.
my @DOMAIN_KEYS = qw(content_root site_url site_name theme layout nav_file
    search_default allowed_groups locked_users lang lang_group);
my %IS_KEY = map { $_ => 1 } @DOMAIN_KEYS;

sub _conf_path { return "$DOCROOT/lazysite/lazysite.conf" }

# A host label is a lowercase DNS name: dot-separated labels of [a-z0-9-], no
# leading/trailing hyphen, no traversal, no scheme/port/path. Kept strict so a
# host can never be spelled to inject a conf line or escape a directory.
sub _valid_host {
    my ($h) = @_;
    return 0 unless defined $h && length $h && length $h <= 253;
    $h = lc $h;
    return 0 if $h =~ /[^a-z0-9.-]/;
    return 0 if $h =~ /\.\./ || $h =~ /^[.-]/ || $h =~ /[.-]$/;
    for my $label ( split /\./, $h ) {
        return 0 unless length $label && $label !~ /^-/ && $label !~ /-$/;
    }
    return 1;
}

# A content root is a docroot-relative directory. Reject traversal and any
# reserved (system) root - path_is_reserved is the single definition, shared
# with the manager blocklist and mirrored by the processor's
# confine_content_root: a domain's content must never be the secrets/auth/ACL
# tree. Returns the cleaned relative path, or undef.
sub _clean_content_root {
    my ($rel) = @_;
    return undef unless defined $rel && length $rel;
    $rel =~ s{^/+|/+$}{}g;
    return undef unless length $rel;
    return undef if $rel =~ m{(?:^|/)\.\.(?:/|$)};    # traversal
    return undef if $rel =~ m{(?:^|/)\.[^/]};         # dotfile/dotdir segment
    return undef if path_is_reserved($rel);           # engine-owned (system) area
    return $rel;
}

# Parse the conf into ( \%base, \%overrides, \@hosts ). %overrides is
# host => { key => value }; @hosts is the ordered alias_hosts list.
sub _parse {
    my %base;
    my %ov;
    if ( open my $fh, '<:utf8', _conf_path() ) {
        while ( my $line = <$fh> ) {
            if ( $line =~ /^alias\.(\S+?)\.(\w+)\s*:\s*(.*?)\s*$/ ) {
                $ov{ lc $1 }{$2} = $3;
            }
            elsif ( $line =~ /^(\w+)\s*:\s*(.*?)\s*$/ ) {
                $base{$1} = $2;
            }
        }
        close $fh;
    }
    my @hosts = grep { length } map { s/^\s+|\s+$//gr } split /,/,
        ( $base{alias_hosts} // '' );
    return ( \%base, \%ov, \@hosts );
}

# Read the whole conf verbatim (for line-level rewrites).
sub _slurp {
    open my $fh, '<:utf8', _conf_path() or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Write the conf back IN PLACE (open '>', so the inode - and thus the owner and
# mode - is preserved; a temp+rename would drop a site-user's group/mode, the
# field bug fixed earlier this cycle). Returns ( ok, err ).
sub _write {
    my ($content) = @_;
    my $path = _conf_path();
    open my $fh, '>:utf8', $path or return ( 0, "Cannot write $path: $!" );
    print {$fh} $content or do { my $e = $!; close $fh; return ( 0, "Write failed: $e" ) };
    close $fh            or return ( 0, "Close failed: $!" );
    return ( 1, '' );
}

# Set (or replace) one `alias.<host>.<key>: value` line in $content, returning
# the new content. Appends if absent.
sub _set_line {
    my ( $content, $host, $key, $value ) = @_;
    my $k  = "alias.$host.$key";
    my $qk = quotemeta $k;
    if ( $content =~ /^$qk\s*:/m ) {
        $content =~ s/^$qk\s*:.*$/$k: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$k: $value\n";
    }
    return $content;
}

# Set (or replace) a bare `key: value` line (used for alias_hosts).
sub _set_base {
    my ( $content, $key, $value ) = @_;
    my $qk = quotemeta $key;
    if ( $content =~ /^$qk\s*:/m ) {
        $content =~ s/^$qk\s*:.*$/$key: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$key: $value\n";
    }
    return $content;
}

# --- public: list ----------------------------------------------------------

# The domains this instance serves: the primary/default host (base keys) plus
# each alias, an override winning over the inherited base value. Mirrors the
# manager's read-only domains view.
sub domains_list {
    my ( $base, $ov, $hosts ) = _parse();
    my @domains = ( {
            host       => '(default)',
            is_primary => 1,
            map { $_ => ( $base->{$_} // '' ) } @DOMAIN_KEYS,
    } );
    for my $h (@$hosts) {
        my %row = ( host => $h, is_primary => 0 );
        for my $k (@DOMAIN_KEYS) {
            $row{$k} = defined $ov->{$h}{$k} ? $ov->{$h}{$k}      : ( $base->{$k} // '' );
            $row{ $k . '_inherited' } = defined $ov->{$h}{$k} ? 0 : 1;
        }
        push @domains, \%row;
    }
    return { ok => 1, domains => \@domains, keys => \@DOMAIN_KEYS };
}

# SM177: which registered domains (base + every alias/sub-domain) currently
# depend on a given layout - or a given theme UNDER a given layout. Sub-domains
# are first-class peers here: a theme/layout one of them uses must block its
# deletion just as the primary's active one does. Effective values resolve the
# same way the engine serves them - a per-host override wins, else the base value
# is inherited - so an alias that inherits the base layout but pins its own theme
# is matched correctly. Returns the list of host labels ('(default)' for the
# primary) that use it, most useful hosts first. Pass (layout => L) to find
# layout users; (theme => T, layout => L) to find theme users under layout L.
sub domains_using {
    my (%q) = @_;
    my ( $base, $ov, $hosts ) = _parse();

    my $eff = sub {
        my ( $h, $k ) = @_;
        return $base->{$k} // '' if $h eq '';
        return defined $ov->{$h}{$k} ? $ov->{$h}{$k} : ( $base->{$k} // '' );
    };

    my @using;
    for my $h ( '', @$hosts ) {
        my $layout = $eff->( $h, 'layout' );
        if ( defined $q{theme} ) {
            next unless $layout eq ( $q{layout} // '' );
            next unless $eff->( $h, 'theme' ) eq $q{theme};
        }
        else {
            next unless $layout eq ( $q{layout} // '' );
        }
        push @using, ( $h eq '' ? '(default)' : $h );
    }
    return @using;
}

# --- public: add -----------------------------------------------------------

# %opts: content_root (OPTIONAL - empty means the host serves the DEFAULT site,
# i.e. the docroot root, no per-host content of its own), and any of
# site_url/site_name/theme/layout/nav_file/search_default; seed => 1 to write a
# starter index.md (ignored when there is no content root of its own).
sub domain_add {
    my ( $host, %opts ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    # Empty content_root is allowed: the host then serves the default site.
    # A NON-empty value must clean (under the docroot, not a reserved area).
    my $raw      = $opts{content_root};
    my $has_root = defined $raw && $raw =~ /\S/;
    my $rel      = '';
    if ($has_root) {
        $rel = _clean_content_root($raw);
        return { ok => 0, kind => 'invalid',
            error => 'The content folder must be inside your site. '
                . 'The lazysite system area is reserved - pick another folder.' }
            unless defined $rel;
    }

    # SM179: validate the language keys the same way domain_set does - they land
    # in <html lang> and name an i18n file, so fail closed on a bad value.
    if ( defined $opts{lang} && length $opts{lang}
        && $opts{lang} !~ /^[A-Za-z]+(?:-[A-Za-z0-9]+)*\z/ )
    {
        return { ok => 0, kind => 'invalid', error => 'Invalid language tag' };
    }
    if ( defined $opts{lang_group} && length $opts{lang_group}
        && $opts{lang_group} !~ /^[A-Za-z0-9_-]+\z/ )
    {
        return { ok => 0, kind => 'invalid', error => 'Invalid lang_group name' };
    }
    # SEC (F6.11): every override value is written as a single conf line via
    # _set_line, so reject CR/LF in ANY of them - matching domain_set - so a value
    # cannot smuggle a second conf directive (e.g. a reserved content_root).
    for my $k (@DOMAIN_KEYS) {
        next unless defined $opts{$k};
        return { ok => 0, kind => 'invalid', error => 'Value must be a single line' }
            if $opts{$k} =~ /[\r\n]/;
    }

    my ( $base, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'exists', error => "Domain already registered: $host" }
        if grep { $_ eq $host } @$hosts;

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;

    # content_root first (only when the host has its own), then any presentation
    # overrides. With no content root the host writes no content_root line and
    # inherits the base - it serves the default site.
    $content = _set_line( $content, $host, 'content_root', $rel ) if length $rel;
    for my $k (@DOMAIN_KEYS) {
        next if $k eq 'content_root';
        next unless defined $opts{$k} && length $opts{$k};
        $content = _set_line( $content, $host, $k, $opts{$k} );
    }

    # Append the host to alias_hosts (preserve order).
    my @new_hosts = ( @$hosts, $host );
    $content = _set_base( $content, 'alias_hosts', join( ',', @new_hosts ) );

    my ( $ok, $err ) = _write($content);
    return { ok => 0, error => $err } unless $ok;

    # A host with no content root of its own serves the default site - nothing
    # to provision or seed.
    unless ( length $rel ) {
        log_event( 'INFO', $host, 'domain registered (serves the default site)',
            host => $host, user => $auth_user );
        return { ok => 1, host => $host, content_root => '' };
    }

    # Provision the content-root directory (+ optional seed). A directory that
    # already exists is fine (adopting an existing tree).
    my $dir = "$DOCROOT/$rel";
    unless ( -d $dir ) {
        eval { make_path($dir); 1 }
            or return { ok => 0,
            error => "Domain registered but content root could not be created: $@" };
    }
    if ( $opts{seed} && !-e "$dir/index.md" ) {
        my $title = $opts{site_name} || $host;
        if ( open my $sf, '>:utf8', "$dir/index.md" ) {
            print {$sf} "---\ntitle: $title\n---\n\n# $title\n\n"
                . "This domain is served by lazysite. Replace this page.\n";
            close $sf;
        }
    }

    log_event( 'INFO', 'domain-add', 'domain registered',
        host => $host, content_root => $rel, user => $auth_user );
    return { ok => 1, host => $host, content_root => $rel };
}

# --- public: set -----------------------------------------------------------

sub domain_set {
    my ( $host, $key, $value ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);
    return { ok => 0, kind => 'invalid', error => "Not a settable domain key: $key" }
        unless defined $key && $IS_KEY{$key};
    $value = '' unless defined $value;

    if ( $key eq 'content_root' ) {
        my $rel = _clean_content_root($value);
        return { ok => 0, kind => 'invalid', error => 'Invalid content_root' }
            unless defined $rel;
        $value = $rel;
    }
    elsif ( $key eq 'allowed_groups' || $key eq 'locked_users' ) {
        # SM165: a comma list of group / account names. Normalise (trim, drop
        # blanks, dedupe) and reject any token that is not a plain name - this is
        # access-control config, so it fails closed rather than storing garbage.
        my @toks = grep { length } map { s/^\s+|\s+$//gr } split /,/, $value;
        for my $t (@toks) {
            return { ok => 0, kind => 'invalid', error => "Invalid name in $key: $t" }
                unless $t =~ /^[A-Za-z0-9_-]+\z/;
        }
        my %seen;
        $value = join ', ', grep { !$seen{$_}++ } @toks;
    }
    elsif ( $key eq 'lang' ) {
        # SM179: a BCP-47-ish language tag (en, fr, pt-BR). Strict - it lands in
        # <html lang> and names the i18n override file. Empty clears it.
        $value =~ s/^\s+|\s+$//g;
        return { ok => 0, kind => 'invalid', error => 'Invalid language tag' }
            unless $value eq '' || $value =~ /^[A-Za-z]+(?:-[A-Za-z0-9]+)*\z/;
    }
    elsif ( $key eq 'lang_group' ) {
        # SM179: the language-set name, shared across the set's hosts. A plain
        # name token; empty clears it.
        $value =~ s/^\s+|\s+$//g;
        return { ok => 0, kind => 'invalid', error => 'Invalid lang_group name' }
            unless $value eq '' || $value =~ /^[A-Za-z0-9_-]+\z/;
    }
    # Values are single-line conf values: no newlines.
    return { ok => 0, kind => 'invalid', error => 'Value must be a single line' }
        if $value =~ /[\r\n]/;

    my ( undef, undef, $hosts ) = _parse();
    return { ok => 0, kind => 'not-found', error => "Domain not registered: $host" }
        unless grep { $_ eq $host } @$hosts;

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;
    $content = _set_line( $content, $host, $key, $value );
    my ( $ok, $err ) = _write($content);
    return { ok => 0, error => $err } unless $ok;

    log_event( 'INFO', 'domain-set', 'domain key set',
        host => $host, key => $key, user => $auth_user );
    return { ok => 1, host => $host, key => $key, value => $value };
}

# --- public: remove --------------------------------------------------------

# Unregisters the host: drops it from alias_hosts and strips every
# alias.<host>.* line. The content directory is LEFT IN PLACE by default (data
# safety); pass purge => 1 to remove it too.
sub domain_remove {
    my ( $host, %opts ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    my ( undef, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'not-found', error => "Domain not registered: $host" }
        unless grep { $_ eq $host } @$hosts;

    my $rel = $ov->{$host}{content_root};

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;

    # Strip every alias.<host>.<key> line.
    my $qh = quotemeta $host;
    $content =~ s/^alias\.$qh\.\w+\s*:.*\n//mg;

    # Rewrite alias_hosts without this host.
    my @remaining = grep { $_ ne $host } @$hosts;
    $content = _set_base( $content, 'alias_hosts', join( ',', @remaining ) );

    my ( $ok, $err ) = _write($content);
    return { ok => 0, error => $err } unless $ok;

    my $purged = 0;
    if ( $opts{purge} && defined $rel ) {
        my $clean = _clean_content_root($rel);
        if ( defined $clean ) {
            my $real  = realpath("$DOCROOT/$clean");
            my $droot = realpath($DOCROOT);
            if ( defined $real
                && defined $droot
                && $real ne $droot
                && index( $real, "$droot/" ) == 0 )
            {
                require File::Path;
                eval { File::Path::remove_tree($real); $purged = 1; 1 };
            }
        }
    }

    log_event( 'INFO', 'domain-remove', 'domain unregistered',
        host => $host, purged => $purged, user => $auth_user );
    return { ok => 1, host => $host, purged => $purged };
}

# --- public: check a domain's live configuration (SM156) -------------------

# Resolve a host to its distinct IP addresses (v4 + v6). Returns the list, or
# () when the name does not resolve. Loaded lazily - the network modules must
# not add to every manager request's startup.
sub _resolve_ips {
    my ($host) = @_;
    return () unless eval { require Socket; 1 };    # absent => treated as "no resolution"
    my ( $err, @res )
        = Socket::getaddrinfo( $host, '', { socktype => Socket::SOCK_STREAM() } );
    return () if $err;
    my ( %seen, @ips );
    for my $ai (@res) {
        my ( $e, $ip )
            = Socket::getnameinfo( $ai->{addr}, Socket::NI_NUMERICHOST(), Socket::NIx_NOSERV() );
        next if $e;
        push @ips, $ip unless $seen{$ip}++;
    }
    return @ips;
}

# Open a verified TLS connection to $host:443. A connection only forms when the
# certificate is valid AND matches the host (SSL_verify_mode PEER + SNI), so a
# returned {ok=>1} means "trusted HTTPS". When full verification fails we probe
# again verifying the CHAIN but NOT the hostname, to tell a SAN/coverage gap
# (a trusted cert is served but does not cover this host - e.g. Hestia did not
# add the sub-domain to the certificate) apart from "no trusted HTTPS at all".
# Detail carries the CN and expiry when they can be read; never throws.
sub _tls_probe {
    my ( $host, $timeout ) = @_;
    return { ok => 0, detail => 'TLS check unavailable (IO::Socket::SSL not installed)' }
        unless eval { require IO::Socket::SSL; 1 };

    my $sock = IO::Socket::SSL->new(
        PeerHost          => $host,
        PeerPort          => 443,
        Timeout           => $timeout,
        SSL_verify_mode   => IO::Socket::SSL::SSL_VERIFY_PEER(),
        SSL_hostname      => $host,
        SSL_verifycn_name => $host,
    );
    if ($sock) {
        my $cn      = eval { $sock->peer_certificate('commonName') } // '';
        my $expires = eval {
            require Net::SSLeay;    # IO::Socket::SSL's backend; named for the SBOM
            my $t = Net::SSLeay::X509_get_notAfter( $sock->peer_certificate );
            $t ? Net::SSLeay::P_ASN1_TIME_get_isotime($t) : '';
        } // '';
        close $sock;
        my $detail = 'valid certificate';
        $detail .= " for $cn"           if length $cn;
        $detail .= ", expires $expires" if length $expires;
        return { ok => 1, detail => $detail, expires => $expires };
    }

    my $e = do { no warnings 'once'; $IO::Socket::SSL::SSL_ERROR || $! || 'connection failed' };
    $e =~ s/\s+/ /g;

    # Chain-only probe: same connection, hostname verification disabled. If it
    # succeeds, a TRUSTED certificate is served - it just does not cover $host.
    my $chain = IO::Socket::SSL->new(
        PeerHost            => $host,
        PeerPort            => 443,
        Timeout             => $timeout,
        SSL_verify_mode     => IO::Socket::SSL::SSL_VERIFY_PEER(),
        SSL_hostname        => $host,     # SNI, so the server returns its cert
        SSL_verifycn_scheme => 'none',    # verify the chain, NOT the hostname
    );
    if ($chain) {
        # What the cert DOES cover: its dNSName SANs (type 2), falling back to
        # the CN - so the operator sees exactly which name is missing.
        my @san = eval {
            map  { $_->[1] }
            grep { ref $_ eq 'ARRAY' && $_->[0] == 2 }
                $chain->peer_certificate('subjectAltNames');
        };
        my $cn = eval { $chain->peer_certificate('commonName') } // '';
        close $chain;
        my ( %seen, @cover );
        for ( @san, $cn ) { push @cover, $_ if defined && length && !$seen{$_}++ }
        my $shown
            = @cover > 6 ? ( join( ', ', @cover[ 0 .. 5 ] ) . ', …' ) : join( ', ', @cover );
        my $detail = 'a certificate is served';
        $detail .= " (covers $shown)" if length $shown;
        $detail .= ' but not this host'
            . ' - add this host to the certificate (e.g. via Hestia SSL)';
        return { ok => 0, kind => 'cert-mismatch', detail => $detail, covers => \@cover };
    }

    return { ok => 0, detail => "no trusted HTTPS ($e)" };
}

# GET the public instance marker over $host and read back its instance id, so
# the caller can tell whether the request terminated on THIS install.
sub _marker_fetch {
    my ( $host, $timeout ) = @_;
    return { ok => 0, detail => 'HTTPS check unavailable (HTTP::Tiny not installed)' }
        unless eval { require HTTP::Tiny; 1 };
    my $http = HTTP::Tiny->new(
        timeout    => $timeout,
        verify_SSL => 1,
        agent      => 'lazysite-domain-check/1 ',
    );
    my $res = $http->get("https://$host/.well-known/lazysite-instance.json");
    unless ( $res->{success} ) {
        my $why = $res->{status} == 599 ? ( $res->{content} || 'network error' )
            :   "HTTP $res->{status}";
        $why =~ s/\s+/ /g;
        return { ok => 0, detail => $why };
    }
    my ($inst) = ( $res->{content} // '' ) =~ /"instance"\s*:\s*"([0-9a-f]{1,64})"/;
    return { ok => 1, instance => ( $inst // '' ), detail => 'marker answered' };
}

# True for a routable public address - excludes RFC1918 / loopback / link-local
# (v4) and loopback / link-local / unique-local (v6). Used so a private
# SERVER_ADDR (the norm behind a proxy) is never taken for the public address.
sub _is_public_ip {
    my ($ip) = @_;
    return 0 unless defined $ip && length $ip;
    if ( $ip =~ /:/ ) {    # IPv6
        my $l = lc $ip;
        return 0 if $l eq '::1';                   # loopback
        return 0 if $l =~ /^fe80:/;                # link-local
        return 0 if $l =~ /^f[cd][0-9a-f]{2}:/;    # unique-local (fc00::/7)
        return 1;
    }
    my @o = $ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ or return 0;
    return 0 if $o[0] == 0 || $o[0] == 10 || $o[0] == 127;
    return 0 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 0 if $o[0] == 192 && $o[1] == 168;
    return 0 if $o[0] == 169 && $o[1] == 254;    # link-local
    return 1;
}

# The PUBLIC address(es) an operator would point a domain at to reach THIS
# install - for the "points to this server" check. Behind a proxy/NAT the
# private SERVER_ADDR is wrong, so discover the public address in order:
#   1. canonical_ip (an explicit override, or the config key) - authoritative;
#   2. resolving the install's own domain (the primary site_url host), which
#      goes through the same public entry point a new domain must;
#   3. SERVER_ADDR, only if it is itself public (a non-proxied host).
# Empty list => undecidable; the check then reports "unknown", not a failure.
sub instance_public_ips {
    my (%o)    = @_;
    my ($base) = _parse();

    my $cfg = ( defined $o{canonical_ip} && length $o{canonical_ip} )
        ? $o{canonical_ip}
        : ( $base->{canonical_ip} // '' );
    if ( length $cfg ) {
        my @ips = grep { _is_public_ip($_) } map { s/^\s+|\s+$//gr } split /,/, $cfg;
        return @ips if @ips;
    }

    my $site_url = $base->{site_url} // '';
    if ( $site_url =~ m{^https?://([^/:]+)}i ) {
        my @ips = grep { _is_public_ip($_) } _resolve_ips( lc $1 );
        return @ips if @ips;
    }

    return ( $o{fallback_ip} )
        if length( $o{fallback_ip} // '' ) && _is_public_ip( $o{fallback_ip} );

    return ();
}

# domain_check($host, %opt) - is $host configured to serve THIS install live?
# Runs four ordered checks and returns them as an array (UI renders in order):
#   dns        - the name resolves to an address
#   host       - one of those addresses is THIS server (opt{self_ips}); undef
#                (indeterminate) when our public address is unknown
#   ssl        - a trusted certificate terminates for the host
#   terminates - an HTTPS request lands on THIS install (marker id == opt{instance_id})
# %opt: self_ips (arrayref) or self_ip, instance_id, timeout; and
#       resolve/tls/fetch code-ref overrides
# so tests drive every branch without touching the network. A check `pass` is
# 1, 0, or undef (indeterminate - e.g. this server's own address is unknown).
sub domain_check {
    my ( $host, %opt ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    # The server's own PUBLIC address(es). A list, because behind a proxy / NAT
    # the private SERVER_ADDR is useless - the caller self-discovers the public
    # IP(s) (operator canonical_ip, or resolving the install's own domain) and
    # passes them here. self_ip (scalar) is still accepted for a simple caller.
    my @self_ips
        = $opt{self_ips} ? grep { length } @{ $opt{self_ips} }
        : ( defined $opt{self_ip} && length $opt{self_ip} ) ? ( $opt{self_ip} )
        :                                                     ();
    my $instance = $opt{instance_id} // '';
    my $timeout  = $opt{timeout} || 6;
    my $resolve  = $opt{resolve} || \&_resolve_ips;
    my $tls      = $opt{tls}     || \&_tls_probe;
    my $fetch    = $opt{fetch}   || \&_marker_fetch;

    my @checks;

    # 1. DNS resolution.
    my @ips    = $resolve->($host);
    my $dns_ok = @ips ? 1 : 0;
    push @checks, {
        id     => 'dns',
        label  => 'DNS resolves',
        pass   => $dns_ok,
        detail => $dns_ok
        ? ( 'resolves to ' . join( ', ', @ips ) )
        : 'the host name does not resolve yet - add the DNS record',
    };

    # 2. Points to this server (a resolved IP is one of ours). Behind a proxy or
    # NAT the server cannot know its own public IP, so when none was discovered
    # this is INDETERMINATE (undef), not a failure - the "Serves this lazysite"
    # check below is the authoritative reachability signal.
    if ( !$dns_ok ) {
        push @checks, { id => 'host', label => 'Points to this server',
            pass => 0, detail => 'skipped - the host does not resolve' };
    }
    elsif ( !@self_ips ) {
        push @checks, {
            id     => 'host',
            label  => 'Points to this server',
            pass   => undef,
            detail => "this server's public address is unknown (behind a proxy/NAT?) - "
                . 'set canonical_ip in config to enable this check',
        };
    }
    else {
        my %mine = map { $_ => 1 } @self_ips;
        my ($match) = grep { $mine{$_} } @ips;
        push @checks, {
            id     => 'host',
            label  => 'Points to this server',
            pass   => $match ? 1 : 0,
            detail => $match
            ? "points here ($match)"
            : ( 'resolves to ' . join( ', ', @ips )
                    . ', not this server (' . join( ', ', @self_ips ) . ')' ),
        };
    }

    # 3. Trusted HTTPS certificate.
    my $ssl = $tls->( $host, $timeout );
    push @checks, { id => 'ssl', label => 'HTTPS certificate valid',
        pass => $ssl->{ok} ? 1 : 0, detail => $ssl->{detail} };

    # 4. Terminates on THIS install (marker id match).
    my $mk = $fetch->( $host, $timeout );
    my $term_ok
        = ( $mk->{ok} && length $instance && ( $mk->{instance} // '' ) eq $instance ) ? 1 : 0;
    my $tdetail
        = !$mk->{ok} ? ( 'no reply over HTTPS - ' . ( $mk->{detail} || 'unreachable' ) )
        : $term_ok   ? 'serves this lazysite instance'
        :              'reachable, but answered by a different server or instance';
    push @checks, { id => 'terminates', label => 'Serves this lazysite',
        pass => $term_ok, detail => $tdetail };

    my $all_pass = ( grep { defined $_->{pass} && !$_->{pass} } @checks ) ? 0 : 1;
    return { ok => 1, host => $host, all_pass => $all_pass, checks => \@checks };
}

1;
