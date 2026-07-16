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
use Cwd            qw(realpath);
use File::Path     qw(make_path);
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(domains_list domain_add domain_add_alias domain_remove domain_set);

our $DOCROOT;           # set by the caller (manager-api or the CLI)
our $auth_user = '';    # for log attribution

# Per-host presentation/routing keys that may be overridden for an alias. Same
# set the read-only view (action_domains_list) surfaces. content_root is the one
# that actually roots a domain's content; the rest are presentation.
my @DOMAIN_KEYS = qw(content_root site_url site_name theme layout nav_file search_default);
my %IS_KEY      = map { $_ => 1 } @DOMAIN_KEYS;

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

# A content root is a docroot-relative directory. Reject traversal and the
# lazysite/ management tree (parity with the processor's confine_content_root):
# a domain's content must never be the secrets/auth/ACL tree. Returns the
# cleaned relative path, or undef.
sub _clean_content_root {
    my ($rel) = @_;
    return undef unless defined $rel && length $rel;
    $rel =~ s{^/+|/+$}{}g;
    return undef unless length $rel;
    return undef if $rel =~ m{(?:^|/)\.\.(?:/|$)};    # traversal
    return undef if $rel =~ m{(?:^|/)\.[^/]};         # dotfile/dotdir segment
    return undef if $rel =~ m{^lazysite(?:/|$)};      # management tree
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
    my %canon_for;    # content_root -> the first host that declared it (canonical)
    for my $h (@$hosts) {
        my %row = ( host => $h, is_primary => 0 );
        for my $k (@DOMAIN_KEYS) {
            $row{$k} = defined $ov->{$h}{$k} ? $ov->{$h}{$k}      : ( $base->{$k} // '' );
            $row{ $k . '_inherited' } = defined $ov->{$h}{$k} ? 0 : 1;
        }
        # SM155: an ALIAS is a host that shares another registered domain's own
        # content root. The first host to declare a given root is canonical;
        # later hosts with the same root are marked as its aliases so the UI can
        # group them under it rather than list them as separate domains.
        my $cr = $ov->{$h}{content_root};
        if ( defined $cr && length $cr ) {
            if   ( defined $canon_for{$cr} ) { $row{alias_of}  = $canon_for{$cr} }
            else                             { $canon_for{$cr} = $h }
        }
        push @domains, \%row;
    }
    return { ok => 1, domains => \@domains, keys => \@DOMAIN_KEYS };
}

# --- public: add an alias --------------------------------------------------

# SM155: register $host as an ALIAS of an existing domain $of - the same content
# root (and canonical site_url), a different host. Aliases let one first-class
# domain answer to several hosts (clienta.com + www.clienta.com), each unique in
# this instance. The shared content root is intentional (that is what an alias
# is); domain_add enforces host-uniqueness and reuses the existing directory.
sub domain_add_alias {
    my ( $host, $of ) = @_;
    $of = lc( $of // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid canonical host' }
        unless _valid_host($of);

    my ( undef, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'not-found', error => "Not a registered domain: $of" }
        unless grep { $_ eq $of } @$hosts;

    my $cr = $ov->{$of}{content_root};
    return { ok => 0, kind => 'invalid',
        error => "$of has no content_root of its own to alias" }
        unless defined $cr && length $cr;

    my %opts = ( content_root => $cr );
    # Carry the canonical's site_url so the alias's canonical link points at the
    # same site (proper mirror SEO); every other key inherits the base.
    $opts{site_url} = $ov->{$of}{site_url}
        if defined $ov->{$of}{site_url} && length $ov->{$of}{site_url};
    return domain_add( $host, %opts );
}

# --- public: add -----------------------------------------------------------

# %opts: content_root (required), and any of site_url/site_name/theme/layout/
# nav_file/search_default; seed => 1 to write a starter index.md.
sub domain_add {
    my ( $host, %opts ) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'Invalid domain host' }
        unless _valid_host($host);

    my $rel = _clean_content_root( $opts{content_root} );
    return { ok => 0, kind => 'invalid',
        error => 'content_root must be a directory under the docroot, '
            . 'not a traversal or the lazysite/ tree' }
        unless defined $rel;

    my ( $base, $ov, $hosts ) = _parse();
    return { ok => 0, kind => 'exists', error => "Domain already registered: $host" }
        if grep { $_ eq $host } @$hosts;

    my $content = _slurp();
    return { ok => 0, error => 'Cannot read lazysite.conf' } unless defined $content;

    # content_root first, then any presentation overrides provided.
    $content = _set_line( $content, $host, 'content_root', $rel );
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

1;
