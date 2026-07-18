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

our @EXPORT_OK = qw(read_domains effective_scopes DENY_ALL_SCOPE);

# A scope string no real content path can match, so a LOCKED user whose lock
# excludes every domain they may manage is confined to NOTHING (deny-all) -
# never silently unconfined, which an empty scope list would mean.
sub DENY_ALL_SCOPE { return "\0sm165-locked-nowhere" }

sub _trim { my $v = shift // ''; $v =~ s/^\s+|\s+$//g; return $v }

# Parse the domain records from a lazysite.conf path:
#   { host => { content_root, allowed_groups => [...], locked_users => [...] } }
# The default site is the record under host ''. Read-only; never writes.
sub read_domains {
    my ($conf_path) = @_;
    my %dom = ( '' => { content_root => '', allowed_groups => [], locked_users => [] } );
    open my $fh, '<:utf8', $conf_path or return \%dom;
    while ( my $line = <$fh> ) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || !length $line;
        if ( $line =~ /^content_root\s*:\s*(.+)/ ) {
            $dom{''}{content_root} = _trim($1);
        }
        elsif ( $line =~ /^alias\.(.+)\.(content_root|allowed_groups|locked_users)\s*:\s*(.+)/x ) {
            my ( $host, $key, $val ) = ( $1, $2, $3 );
            $dom{$host} ||= { content_root => '', allowed_groups => [], locked_users => [] };
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
#   allowed(U)   : domains whose allowed_groups intersect U's (compound) groups.
#                  A NON-DEFAULT domain with an EMPTY allow-list is operator-only
#                  (no group reaches it). The default site ('') needs no allow.
#   locked(U)    : domains whose locked_users include U.
#   effective(U) : allowed, narrowed to locked when U is locked anywhere.
#   result       : the content_roots of the effective domains (deduped).
# An empty list (unconfined) is returned ONLY for a user with no lock and no
# allow-entry - a general editor, as today. A LOCKED user whose effective set is
# empty is confined to DENY_ALL_SCOPE (nothing), never left unconfined.
sub effective_scopes {
    my ( $dom, $user, $groups ) = @_;
    my %g = map { $_ => 1 } @{ $groups || [] };

    my ( %allowed, %locked );
    for my $host ( keys %{$dom} ) {
        my $d  = $dom->{$host};
        my @ag = @{ $d->{allowed_groups} || [] };
        if ( $host eq '' ) {
            $allowed{$host} = 1 if !@ag || grep { $g{$_} } @ag;
        }
        else {
            $allowed{$host} = 1 if @ag && grep { $g{$_} } @ag;
        }
        $locked{$host} = 1
            if defined $user && grep { $_ eq $user } @{ $d->{locked_users} || [] };
    }

    my $is_locked = %locked ? 1 : 0;
    my @eff       = $is_locked
        ? ( grep { $allowed{$_} } keys %locked )    # allowed INTERSECT locked
        : ( keys %allowed );

    if ( !@eff ) {
        return $is_locked ? (DENY_ALL_SCOPE) : ();
    }

    my ( %seen, @scopes );
    for my $host (@eff) {
        my $cr = $dom->{$host}{content_root} // '';
        next unless length $cr;    # a docroot-rooted domain does not confine
        push @scopes, $cr unless $seen{$cr}++;
    }
    # Every effective domain roots at the docroot => the user manages the whole
    # site (e.g. locked only to the default site): unconfined, as intended.
    return @scopes;
}

1;
