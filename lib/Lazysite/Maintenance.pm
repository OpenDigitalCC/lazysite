package Lazysite::Maintenance;

# SM1118 (ruled 2026-10-20, #338): A SITE CAN BE PUT INTO MAINTENANCE.
#
# One decision, asked by every door. The processor asks it for a page request, the
# MCP connector, the manager / control API, WebDAV, the data endpoint and the form
# handler ask it for theirs, and `lazysite check` asks it to warn. They differ in
# how they REFUSE (a 302 to the page, a JSON 503, a plain 503) and agree on
# everything else: whether maintenance is on for this host, where the page is, when
# it is expected to end, which paths stay reachable, and who gets through.
#
# THE SETTINGS (lazysite.conf)
#
#   maintenance: on|off        the switch; absent is off
#   maintenance_page: PATH     where visitors are sent; default /maintenance, a
#                              system page the site ships (SM201), or any path on
#                              the site, or an absolute https:// address
#   maintenance_until: TIME    optional; shown on the page, sent as Retry-After.
#                              YYYY-MM-DD HH:MM (UTC), or ISO 8601 with a T and
#                              optional seconds and Z
#
# PER DOMAIN, with an instance switch covering all (ruled): the base keys are the
# instance's; `alias.<host>.maintenance: on` (and `.maintenance_page`,
# `.maintenance_until`) puts ONE declared domain into maintenance. The instance
# switch wins: base `on` puts every domain in maintenance whatever an alias says,
# because a switch that one domain's line could undo would not cover all of them.
# An alias line counts only for a host listed in `alias_hosts`, as every alias key.
#
# WHO GETS THROUGH (ruled): a request whose VERIFIED identity holds the
# `maintenance_access` capability. Everyone else is sent to the page (a page
# request) or refused 503 (a machine door). Identity is each caller's own: the
# processor's one reader, the token or Basic credential a door verifies. This
# module never decides who somebody is; `holds()` only asks what a set of groups
# grants.
#
# Module-free callers (the processor's render path, ADR 0001) load this lazily and
# only when lazysite.conf mentions the key, so a site that has never used
# maintenance pays nothing.

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(status on_value page_ok until_ok exempt is_page retry_after request_host
    message refusal_json default_page);

our $DEFAULT_PAGE  = '/maintenance';
our $DEFAULT_RETRY = 3600;          # seconds, when maintenance_until names no future time

sub default_page { return $DEFAULT_PAGE }

# The switch's value. on / enabled / true / yes / 1 are on; anything else is off -
# an unreadable value must not close a site (the Config page refuses to store one,
# and `lazysite check` names it).
sub on_value {
    my ($v) = @_;
    return 0 unless defined $v;
    $v =~ s/\A\s+|\s+\z//g;
    return ( $v =~ /\A(?:on|enabled|true|yes|1)\z/i ) ? 1 : 0;
}

# The request's Host, as the processor's _request_host sanitises it (DNS alphabet
# only), from the environment a CGI child inherits.
sub request_host {
    my ($raw) = @_;
    my $host = lc( $raw // $ENV{HTTP_HOST} // q{} );
    $host =~ s/:\d+\z//;
    $host =~ s/\.\z//;
    return q{} if length $host > 253;
    return q{}
        unless $host =~ /\A [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )?
                         (?: \. [a-z0-9] (?: [a-z0-9-]* [a-z0-9] )? )* \z/x;
    return $host;
}

# A value acceptable as the page's address: a path on this site, or an absolute
# https:// address. Anything else (a relative word, a scheme-relative //host, a
# javascript: URL, a control character) is not an address we will redirect to.
sub page_ok {
    my ($p) = @_;
    return 0 unless defined $p && length $p;
    return 0 if $p =~ /[\x00-\x20\x7f"'<>\\]/x;
    return 1 if $p =~ m{\Ahttps://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(?::\d+)?(?:[/?#]\S*)?\z}x;
    return 0 unless $p =~ m{\A/};
    return 0 if $p =~ m{\A//};
    return 0 if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 0 if $p =~ /[?#]/;
    return 1;
}

# maintenance_until -> epoch, or undef when it names no time we can read.
sub _until_epoch {
    my ($v) = @_;
    return undef unless defined $v;
    $v =~ s/\A\s+|\s+\z//g;
    return undef
        unless $v =~ /\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?\s*Z?\z/;
    my ( $y, $mo, $d, $h, $mi, $s ) = ( $1, $2, $3, $4, $5, $6 // 0 );
    return undef if $mo < 1 || $mo > 12 || $d < 1 || $d > 31 || $h > 23 || $mi > 59 || $s > 59;
    require Time::Local;
    my $e = eval { Time::Local::timegm( $s, $mi, $h, $d, $mo - 1, $y ) };
    return $e;
}

# Is this a maintenance_until value we can read? (The Config page and the domain
# editor refuse one that is not.)
sub until_ok { return defined _until_epoch( $_[0] ) ? 1 : 0 }

# Retry-After for a status: seconds until `until`, or the default. Never zero or
# negative - a time already past says nothing about when to come back.
sub retry_after {
    my ( $st, $now ) = @_;
    $now //= time;
    my $e = _until_epoch( $st->{until} );
    return $DEFAULT_RETRY unless defined $e && $e > $now;
    return $e - $now;
}

# Is maintenance on for this host, and with what settings?
#
#   status( lazysite_dir => $dir | conf_text => $text, host => $host )
#
# Returns { on => 0 } or { on => 1, scope => 'instance'|'domain', host, page,
# until }. Last matching line wins, as the processor reads lazysite.conf.
sub status {
    my (%o) = @_;
    my $text = $o{conf_text};
    if ( !defined $text ) {
        my $dir = $o{lazysite_dir} // '';
        $text = '';
        if ( length $dir && open my $fh, '<:utf8', "$dir/lazysite.conf" ) {
            local $/;
            $text = <$fh> // '';
            close $fh;
        }
    }
    my $host = defined $o{host} ? request_host( $o{host} ) : request_host();

    my %d;
    while ( $text =~ /^(\w+)\h*:\h*(.+)$/mg ) {
        $d{$1} = $2;
    }
    for my $k ( keys %d ) { $d{$k} =~ s/\s+\z// }

    my %out = ( on => 0 );
    my ( $scope, %set );
    %set = map { $_ => $d{$_} } grep { defined $d{$_} } qw(maintenance_page maintenance_until);

    if ( on_value( $d{maintenance} ) ) {
        $scope = 'instance';
    }

    # The alias layer: only for a host the operator declared.
    if ( length $host && defined $d{alias_hosts} ) {
        my %declared = map { $_ => 1 } grep { length } map { s/^\s+|\s+$//gr } split /,/, lc $d{alias_hosts};
        if ( $declared{$host} ) {
            my %al;
            while ( $text =~ /^alias\.(\S+)\.(\w+)\h*:\h*(.+)$/mg ) {
                my ( $h, $k, $v ) = ( lc $1, $2, $3 );
                next unless $h eq $host;
                $v =~ s/\s+\z//;
                $al{$k} = $v;
            }
            $scope = 'domain' if !defined $scope && on_value( $al{maintenance} );
            for my $k (qw(maintenance_page maintenance_until)) {
                $set{$k} = $al{$k} if defined $al{$k};
            }
        }
    }
    return \%out unless defined $scope;

    my $page = $set{maintenance_page};
    $page = $DEFAULT_PAGE unless defined $page && page_ok($page);
    return {
        on    => 1,
        scope => $scope,
        host  => $host,
        page  => $page,
        until => ( defined $set{maintenance_until} && defined _until_epoch( $set{maintenance_until} ) )
        ? $set{maintenance_until}
        : '',
    };
}

# Does this path stay reachable while the site is in maintenance? The maintenance
# page itself (when it is on this site), the sign-in and sign-out pages, the
# assets they and the page need, and the well-known and robots files crawlers and
# probes read. `$login` is the site's configured sign-in address (auth_redirect).
sub exempt {
    my ( $path, $st, $login ) = @_;
    $path = '' unless defined $path;
    $path             =~ s/[?#].*\z//s;
    ( my $n = $path ) =~ s{/+\z}{};
    $n                =~ s/\.(?:md|html)\z//;
    $n = '/' unless length $n;
    return 1 if $n    =~ m{\A/lazysite-assets(?:/|\z)};
    return 1 if $path =~ m{\A/\.well-known/};
    return 1 if $n eq '/robots' || $path eq '/robots.txt' || $path eq '/favicon.ico';
    # The presentation assets a maintenance page (or the sign-in page) shows: a
    # stylesheet, script, image or font a domain's content root serves through the
    # engine. They are not pages, and a page without its styling is the failure the
    # ruling names ("the assets they need").
    return 1 if $path =~ /\.(?:css|mjs|js|map|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot)\z/ix;
    return 1 if grep { $n eq $_ } qw(/login /logout /forgot /claim);
    if ( defined $login && length $login && $login =~ m{\A/} ) {
        ( my $l = $login ) =~ s{/+\z}{};
        return 1 if $n eq $l;
    }
    my $page = ref $st eq 'HASH' ? ( $st->{page} // '' ) : '';
    if ( $page =~ m{\A/} ) {
        ( my $p = $page ) =~ s{/+\z}{};
        $p =~ s/\.(?:md|html)\z//;
        return 1 if length $p && $n eq $p;
    }
    return 0;
}

# Is this path the maintenance page (when the page is on this site)? That one
# answers 503 with Retry-After.
sub is_page {
    my ( $path, $st ) = @_;
    $path = '' unless defined $path;
    $path =~ s/[?#].*\z//s;
    my $page = ref $st eq 'HASH' ? ( $st->{page} // '' ) : '';
    return 0 unless $page =~ m{\A/};
    ( my $n = $path )     =~ s{/+\z}{};
    $n                    =~ s/\.(?:md|html)\z//;
    ( my $p = $page )     =~ s{/+\z}{};
    $p                    =~ s/\.(?:md|html)\z//;
    return ( length $p && $n eq $p ) ? 1 : 0;
}

# The sentence a refused caller reads. The same words on the page's fallback
# copy, in a form-post refusal and in a machine door's error.
sub message {
    my ($st) = @_;
    my $m = 'This site is in maintenance. Please try again later.';
    $m = "This site is in maintenance until $st->{until} (UTC). Please try again then."
        if ref $st eq 'HASH' && length( $st->{until} // '' );
    return $m;
}

# A door's JSON 503 body.
sub refusal_json {
    my ($st) = @_;
    require JSON::PP;
    return JSON::PP->new->canonical->encode( {
            ok          => JSON::PP::false(),
            kind        => 'maintenance',
            error       => message($st),
            retry_after => retry_after($st),
    } );
}

1;
