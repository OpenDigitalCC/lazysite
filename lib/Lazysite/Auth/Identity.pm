package Lazysite::Auth::Identity;

# SM1131 / SM1132 / SM1133 (SM1128 phase 1, P1-2 / P1-3 / P1-5): THE REQUEST'S
# IDENTITY, READ IN ONE PLACE.
#
# Before this, six readers asked the environment for who is calling and each had
# its own answer. The page gate honoured the configured header names
# (auth_header_user/_name/_email/_groups, SM960); the manager entry, the manager
# API, the per-file ACL code and two processor readers read the fixed X-Remote-*
# names; the page gate split a groups list on commas and the manager on commas or
# whitespace. A proxy that sends `Remote-User` therefore opened a page and not the
# manager, and a directory group named "Site Editors" read as two groups on one
# and one on the other. united/platform (Authentik) hit exactly this.
#
# request_identity() is the only code that reads the identity out of the
# environment (t/lint/268 pins that). It returns
#
#   { user, name, email, groups => [ ... ], source }
#
# WHICH HEADERS - one rule, three states:
#
#   LAZYSITE_AUTH_TRUSTED=1       the auth wrapper vouched for a signed cookie and
#                                 set the FIXED names (HTTP_X_REMOTE_USER and
#                                 _GROUPS; it clears the rest). source 'cookie'.
#   else, the proxy is trusted    the operator's proxy supplies the identity under
#     for this request            the CONFIGURED names. source 'proxy'. "Trusted"
#                                 is Lazysite::Util::proxy_identity's answer
#                                 (SM1129: auth_proxy_trusted on AND the peer in
#                                 auth_proxy_trusted_from), never the flag alone.
#   else                          the fixed names, which the trust gates strip from
#                                 any real request, so this is empty in service and
#                                 is what a direct call (a test, a tool) set.
#                                 source 'direct'.
#
# The wrapper does NOT also set the configured names. The cookie path is the
# fixed names whatever the proxy is called, so a site that renamed its proxy
# headers still has a working cookie login on every reader (the page gate used to
# read the configured name behind the wrapper and see nobody). A client can never
# make the configured names count: unless proxy_identity trusts this request's
# peer they are not read, whether or not a gate stripped them.
#
# GROUPS - the separator and the names are applied here and nowhere else:
#
#   cookie, direct   the wrapper wrote lazysite group names joined by commas;
#                    split on commas or whitespace (a lazysite name has neither),
#                    returned as stored. NOT lowercased: capability lookup
#                    (Settings::groups_grant_cap) is case-sensitive and a cookie
#                    session's names are the stored ones, so changing their case
#                    here would change what they are granted.
#   proxy            split on auth_header_groups_separator (default `,`; Authentik
#                    sends `|`), each part trimmed, empties dropped (SM1132); then
#                    each DIRECTORY name becomes a lazysite name (SM1133): the
#                    explicit auth_group_map first, else normalised to lowercase
#                    [a-z0-9_-]. So a proxy group comes back LOWERCASE unless the
#                    map named it otherwise (a map target is used as written, so a
#                    site can map onto an existing mixed-case group). The gates and
#                    ACLs lowercase both sides to compare, so either case matches
#                    them; a capability lookup matches a group record by its exact
#                    name, which is why the map is how a directory group reaches a
#                    mixed-case record.
#
# auth_group_map: one line, comma-separated entries `Directory Name = lazysite-name`,
# the shape of the other list-valued keys (alias_hosts, trusted_proxies): the conf
# reader is one `key: value` per line.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util ();

our @EXPORT_OK = qw(request_identity normalise_group_name parse_group_map);

# The fixed names, and the one place that spells them. The wrapper
# (lazysite-auth.pl) and the trust gates name them too; nothing else may.
my %FIXED = (
    user   => 'HTTP_X_REMOTE_USER',
    name   => 'HTTP_X_REMOTE_NAME',
    email  => 'HTTP_X_REMOTE_EMAIL',
    groups => 'HTTP_X_REMOTE_GROUPS',
);
my %DEFAULT_HEADER = (
    user   => 'X-Remote-User',
    name   => 'X-Remote-Name',
    email  => 'X-Remote-Email',
    groups => 'X-Remote-Groups',
);

# The group-name rule (tools/lazysite-users.pl, Manager::Groups).
my $GROUP_NAME_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;

sub _env_name {
    my ($header) = @_;
    ( my $e = 'HTTP_' . uc $header ) =~ s/-/_/g;
    return $e;
}

# The site's conf as a flat hash, for the callers that have no site vars at
# hand. mtime-keyed so a manager-API process that serves many requests re-reads a
# changed file, and the processor (one request per process) reads it once.
my %conf_cache;

sub _read_conf_file {
    my ($file) = @_;
    return {} unless defined $file && length $file && -f $file;
    my $sig = join "\0", ( stat $file )[ 9, 7 ];
    return $conf_cache{$file}{conf}
        if $conf_cache{$file} && $conf_cache{$file}{sig} eq $sig;
    my %c;
    if ( open my $fh, '<:utf8', $file ) {
        while ( my $l = <$fh> ) {
            $c{$1} = $2 if $l =~ /^(\w+)\h*:\h*(.+?)\h*$/;
        }
        close $fh;
    }
    $conf_cache{$file} = { sig => $sig, conf => \%c };
    return \%c;
}

sub _conf {
    my ($opt) = @_;
    return $opt->{conf} if ref $opt->{conf} eq 'HASH';
    my $file = $opt->{conf_file};
    $file = "$opt->{lazysite_dir}/lazysite.conf"
        if !( defined $file && length $file )
        && defined $opt->{lazysite_dir} && length $opt->{lazysite_dir};
    return _read_conf_file($file);
}

# SM1133: lowercase; any run of characters outside [a-z0-9_-] becomes ONE hyphen;
# hyphens trimmed from both ends; cut to 64. '' when nothing is left.
sub normalise_group_name {
    my ($raw) = @_;
    return '' unless defined $raw;
    my $n = lc $raw;
    $n =~ s/[^a-z0-9_-]+/-/g;
    $n =~ s/\A-+//;
    $n = substr $n, 0, 64;
    $n =~ s/-+\z//;
    return $n;
}

sub _map_key {
    my ($s) = @_;
    $s =~ s/\A\s+|\s+\z//g;
    $s =~ s/\s+/ /g;
    return lc $s;
}

# `A B = a-b, C = c` -> { 'a b' => 'a-b', c => 'c' }. A target that is not a valid
# lazysite group name is dropped with a WARN: a map entry the code ignores in
# silence is the declaration-the-code-ignores trap.
sub parse_group_map {
    my ($spec) = @_;
    my %map;
    return \%map unless defined $spec && length $spec;
    for my $entry ( split /,/, $spec ) {
        next unless $entry =~ /\S/;
        my ( $dir, $to ) = split /=/, $entry, 2;
        $to = '' unless defined $to;
        $to =~ s/\A\s+|\s+\z//g;
        my $key = _map_key( $dir // '' );
        unless ( length $key && $to =~ $GROUP_NAME_RE ) {
            Lazysite::Util::log_event( 'WARN', '-',
                'auth_group_map entry ignored - needs `Directory Name = lazysite-name` '
                    . 'with a name of letters, digits, hyphen, underscore (max 64)',
                entry => $entry );
            next;
        }
        $map{$key} = $to;
    }
    return \%map;
}

sub _split_groups {
    my ( $raw, $sep ) = @_;
    return () unless defined $raw && length $raw;
    my @parts = defined $sep ? split( /\Q$sep\E/, $raw ) : split( /[,\s]+/, $raw );
    my @out;
    for my $p (@parts) {
        next unless defined $p;
        $p =~ s/\A\s+|\s+\z//g;
        push @out, $p if length $p;
    }
    return @out;
}

sub _dedupe {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

sub request_identity {
    my (%opt) = @_;
    my $conf = _conf( \%opt );

    my $wrapper = ( $ENV{LAZYSITE_AUTH_TRUSTED} // '' ) eq '1';

    # SM1129 / SM1131: "is the proxy trusted for THIS request" has one answer,
    # Lazysite::Util::proxy_identity (the flag on AND the TCP peer listed in
    # auth_proxy_trusted_from), and this asks it rather than reading the flag:
    # a second reading here would be the flag-alone trust SM1129 removed, kept
    # alive in the one place that decides which header names count. A caller
    # that already holds the answer for this request passes it as `proxy` (the
    # processor's pinned copy, ADR 0001; the auth wrapper's own ask), so a request
    # is judged once. Nothing at hand to ask about - no proxy answer and no
    # lazysite_dir - is untrusted: the configured names are not read.
    my $proxy = 0;
    unless ($wrapper) {
        my $pid = ref $opt{proxy} eq 'HASH'
            ? $opt{proxy}
            : Lazysite::Util::proxy_identity( $opt{lazysite_dir} );
        $proxy = $pid->{trusted} ? 1 : 0;
    }

    my %id = ( user => '', name => '', email => '', groups => [] );

    if ( $wrapper || !$proxy ) {
        $id{source} = $wrapper ? 'cookie' : 'direct';
        $id{$_}     = $ENV{ $FIXED{$_} } // '' for qw(user name email);
        $id{groups} = [ _dedupe( _split_groups( $ENV{ $FIXED{groups} } ) ) ];
        return \%id;
    }

    $id{source} = 'proxy';
    for my $f (qw(user name email)) {
        my $h = $conf->{"auth_header_$f"} || $DEFAULT_HEADER{$f};
        $id{$f} = $ENV{ _env_name($h) } // '';
    }
    my $gh  = $conf->{auth_header_groups} || $DEFAULT_HEADER{groups};
    my $sep = $conf->{auth_header_groups_separator};
    $sep = ',' unless defined $sep && length $sep;
    my $map = parse_group_map( $conf->{auth_group_map} );

    my @groups;
    for my $dir ( _split_groups( $ENV{ _env_name($gh) }, $sep ) ) {
        my $to = $map->{ _map_key($dir) };
        $to = normalise_group_name($dir) unless defined $to;
        if ( $to eq '' ) {
            Lazysite::Util::log_event( 'WARN', '-',
                'directory group dropped - its name has no letters or digits to make a lazysite group from',
                group => $dir );
            next;
        }
        push @groups, $to;
    }
    $id{groups} = [ _dedupe(@groups) ];
    return \%id;
}

1;
