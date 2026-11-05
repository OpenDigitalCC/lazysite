package Lazysite::Auth::DomainAccess;

# SM165: a user's effective content-root scopes, resolved from DOMAIN access.
# Each domain (in lazysite.conf) names the GROUPS allowed to manage it
# (allowed_groups, additive) and the USERS locked to it (locked_users,
# subtractive). effective(U) = the domains U's groups allow, narrowed to U's
# locked domains when U is locked anywhere. The scope list is those domains'
# content roots - fed to the same confinement checks SM155 used, so the
# enforcement is unchanged; only the SOURCE of the scopes moves here (this
# replaces the per-group dav_scope of SM155). Access lives ON the domain.
use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util qw(cannot_read);

our @EXPORT_OK = qw(read_domains effective_scopes effective_home_domain
    intersect_scopes DENY_ALL_SCOPE PRIMARY_SCOPE is_primary_scope);

# A scope string no real content path can match, so a LOCKED user whose lock
# excludes every domain they may manage is confined to NOTHING (deny-all) -
# never silently unconfined, which an empty scope list would mean.
sub DENY_ALL_SCOPE { return "\0sm165-locked-nowhere" }

# SM1332 (ruling 78): the scope a grant on the PRIMARY's row adds - the docroot,
# the primary's content root. Before, the primary was reached only through the
# absence of a scope, so the first secondary domain an account was granted took
# the primary away, and there was no row to grant it back on. Every content-path
# check reads this scope as the whole docroot, as it reads an unbound account's
# empty list; the domain rule (Lazysite::Manager::Common::caller_may_reach_domain)
# reads it as the primary only, never as containing another domain's root.
sub PRIMARY_SCOPE { return '/' }

# Is this scope the primary's grant (it names the docroot itself)?
sub is_primary_scope {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    ( my $x = $s ) =~ s{^/+|/+$}{}g;
    return length $x ? 0 : 1;
}

sub _trim { my $v = shift // ''; $v =~ s/^\s+|\s+$//g; return $v }

# Is scope $x within (under or equal to) scope $y? Slash-normalised, same test
# the enforcement uses.
sub _within {
    my ( $x, $y ) = @_;
    ( my $a = $x // '' ) =~ s{^/+|/+$}{}g;
    ( my $b = $y // '' ) =~ s{^/+|/+$}{}g;
    # SM1332: the primary's grant (the docroot) holds the primary only. By path it
    # contains every domain's content, so read that way a sub-user granted only
    # the primary would come out of the ceiling holding its creator's domains. It
    # meets only itself.
    return ( length $a || length $b ) ? 0 : 1 if !length $a || !length $b;

    return ( $a eq $b || index( $a, "$b/" ) == 0 ) ? 1 : 0;
}

# intersect_scopes(\@own, \@creator) -> the scope list a path must satisfy BOTH.
# The sub-user ceiling (SM165): a created account can never out-reach its
# creator. Semantics, with the empty-list = unconfined convention:
#   - either side empty (unconfined) => the other side stands;
#   - deny-all on either side dominates (=> deny-all);
#   - otherwise the intersection keeps, for each overlapping pair, the TIGHTER
#     scope (the one contained in the other); two disjoint scopes contribute
#     nothing, and if NOTHING overlaps the result is deny-all (access nothing) -
#     never an empty list, which would wrongly mean unconfined.
sub intersect_scopes {
    my ( $own, $creator ) = @_;
    my @o = @{ $own     || [] };
    my @c = @{ $creator || [] };
    return @c unless @o;    # own unconfined => bounded only by the creator
    return @o unless @c;    # creator unconfined => own stands
    my $DA = DENY_ALL_SCOPE();
    return ($DA) if grep { $_ eq $DA } ( @o, @c );
    my ( %seen, @out );
    for my $a (@o) {
        for my $b (@c) {
            my $keep =
                _within( $a, $b )   ? $a
                : _within( $b, $a ) ? $b
                :                     undef;
            next unless defined $keep;
            push @out, $keep unless $seen{$keep}++;
        }
    }
    return @out ? @out : ($DA);    # disjoint => confined to nothing
}

# The empty domain record, written once. read_domains seeds the default site
# with it and creates every alias with it; the two copies drifting apart is
# what this closes.
sub _blank_domain {
    return { content_root => '', allowed_groups => [], locked_users => [] };
}

# Parse the domain records from a lazysite.conf path:
#   { host => { content_root, allowed_groups => [...], locked_users => [...] } }
# The default site is the record under host ''. Its access keys are the bare
# `allowed_groups:` and `locked_users:` lines (SM1332), as
# its content root is the bare `content_root:`. Read-only; never writes.
sub read_domains {
    my ($conf_path) = @_;
    my %dom = ( '' => _blank_domain() );
    open my $fh, '<:utf8', $conf_path or return ( cannot_read( 'domains conf', $conf_path ) // \%dom );
    while ( my $line = <$fh> ) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || !length $line;
        if ( $line =~ /^content_root\s*:\s*(.+)/ ) {
            $dom{''}{content_root} = _trim($1);
        }
        elsif ( $line =~ /^(allowed_groups|locked_users)\s*:\s*(.+)/ ) {
            $dom{''}{$1} = [ grep { length } map { _trim($_) } split /,/, $2 ];
        }
        elsif ( $line =~ /^alias\.(.+)\.(content_root|allowed_groups|locked_users)\s*:\s*(.+)/x ) {
            my ( $host, $key, $val ) = ( $1, $2, $3 );
            $dom{$host} ||= _blank_domain();
            if ( $key eq 'content_root' ) {
                $dom{$host}{content_root} = _trim($val);
            }
            else {
                $dom{$host}{$key} = [ grep { length } map { _trim($_) } split /,/, $val ];
            }
        }
    }
    close $fh;
    return \%dom;
}

# effective_scopes(\%domains, $user, \@groups) -> the content-root scope list.
#   granted(U)   : domains whose allowed_groups intersect U's (compound) groups,
#                  the primary ('') among them (SM1332). A domain with an EMPTY
#                  allow-list grants nobody (a NON-DEFAULT one is sysop-only).
#   allowed(U)   : granted(U); and the primary when nothing is granted to U
#                  anywhere, or when the primary's own list is empty (the default
#                  site needs no allow, SM165).
#   locked(U)    : domains whose locked_users include U.
#   effective(U) : allowed, narrowed to locked when U is locked anywhere.
#   result       : the content_roots of the effective domains (deduped); for
#                  the primary, PRIMARY_SCOPE when it is GRANTED, and nothing
#                  when it is only allowed.
# An empty list (unconfined) is returned ONLY for a user with no lock and no
# allow-entry - a general editor, as today. A LOCKED user whose effective set is
# empty is confined to DENY_ALL_SCOPE (nothing), never left unconfined.
#
# SM1332 (ruling 78): GRANTS ADD. An account reaches every domain it is granted,
# the primary included when the primary's row grants it; an account granted
# nothing keeps the primary, as before; only a lock (a pin) takes the others
# away. Nothing changes at upgrade: no primary row named a group before, so no
# account is granted the primary, and an account scoped to a secondary domain
# keeps exactly that reach (it does not gain the primary; the operator grants it
# on the primary's row).
#
# The effective domain HOSTS for a user, whether the user is locked anywhere, and
# the hosts GRANTED to it: allowed(U) [INTERSECT locked(U) when locked]. Shared
# by the public resolvers so the allow/lock logic lives in ONE place.
sub _effective_hosts {
    my ( $dom, $user, $groups ) = @_;
    my %g = map { $_ => 1 } @{ $groups || [] };

    my ( %granted, %locked );
    for my $host ( keys %{$dom} ) {
        my $d  = $dom->{$host};
        my @ag = @{ $d->{allowed_groups} || [] };
        $granted{$host} = 1 if @ag && grep { $g{$_} } @ag;
        $locked{$host} = 1
            if defined $user && grep { $_ eq $user } @{ $d->{locked_users} || [] };
    }
    my %allowed = %granted;
    $allowed{''} = 1
        if exists $dom->{''} && ( !%granted || !@{ $dom->{''}{allowed_groups} || [] } );

    my $is_locked = %locked ? 1 : 0;
    my @eff       = $is_locked
        ? ( grep { $allowed{$_} } keys %locked )    # allowed INTERSECT locked
        : ( keys %allowed );
    return ( \@eff, $is_locked, \%granted );
}

sub effective_scopes {
    my ( $dom, $user, $groups ) = @_;
    my ( $eff, $is_locked, $granted ) = _effective_hosts( $dom, $user, $groups );

    if ( !@{$eff} ) {
        return $is_locked ? (DENY_ALL_SCOPE) : ();
    }

    my ( %seen, @scopes );
    for my $host ( @{$eff} ) {
        my $cr = $dom->{$host}{content_root} // '';
        # SM1332: the primary GRANTED on its row is a scope of its own; only
        # allowed (granted nothing, or its list empty), it confines nothing.
        $cr = PRIMARY_SCOPE() if $host eq '' && !length $cr && $granted->{''};
        next unless length $cr;    # a docroot-rooted domain does not confine
        push @scopes, $cr unless $seen{$cr}++;
    }
    # Every effective domain roots at the docroot => the user manages the whole
    # site (e.g. locked only to the default site): unconfined, as intended.
    return @scopes;
}

# The single domain HOST a user is effectively rooted at (for UI file-browser
# rooting), or '' when they have zero or several. Unconfined and deny-all both
# yield '' (no single home).
sub effective_home_domain {
    my ( $dom, $user, $groups ) = @_;
    my ( $eff, undef, $granted ) = _effective_hosts( $dom, $user, $groups );
    # SM1332: a granted primary is one of the domains, so primary + one other is
    # two, and no single home.
    my @rooted = grep { length( $dom->{$_}{content_root} // '' ) || ( $_ eq '' && $granted->{''} ) } @{$eff};
    return ( @rooted == 1 ) ? $rooted[0] : '';
}

1;
