#!/usr/bin/perl
# SM165: the domain-access resolver - a user's effective content-root scopes come
# from the DOMAIN (allowed_groups + locked_users), not a per-group dav_scope.
# This is a confinement spine, so the edge cases (empty allow-list = operator
# only; a lock that narrows to nothing = deny-all, never unconfined) are pinned.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::DomainAccess qw(read_domains effective_scopes intersect_scopes DENY_ALL_SCOPE);

sub scopes { [ sort( effective_scopes(@_) ) ] }
sub isect  { [ sort( intersect_scopes(@_) ) ] }

# A domain map fixture: default site + two client domains.
my $D = {
    '' => { content_root => '', allowed_groups => [], locked_users => [] },
    'clienta.com' => { content_root => 'sites/clienta', allowed_groups => ['clienta-editors'], locked_users => ['alice'] },
    'clientb.com' => { content_root => 'sites/clientb', allowed_groups => ['clientb-editors'], locked_users => [] },
    'shared.com' => { content_root => 'sites/shared', allowed_groups => [ 'clienta-editors', 'clientb-editors' ], locked_users => [] },
    'locked.com' => { content_root => 'sites/locked', allowed_groups => [], locked_users => ['bob'] },
};

# --- general editor: no allow-match, no lock => unconfined --------------------
is_deeply( scopes( $D, 'nobody', [] ), [], 'a user in no allowed group is unconfined (general editor)' );
is_deeply( scopes( $D, 'nobody', ['random-group'] ), [], 'a group that no domain allows confines nothing' );

# --- allow: a group grants exactly its domains -------------------------------
is_deeply( scopes( $D, 'ed', ['clientb-editors'] ), [ 'sites/clientb', 'sites/shared' ],
    'a group is confined to the domain(s) that allow it (shared allows it too)' );
is_deeply( scopes( $D, 'ed', ['clienta-editors'] ), [ 'sites/clienta', 'sites/shared' ],
    'a group allowed on two domains gets both content roots' );
is_deeply( scopes( $D, 'ed', [ 'clienta-editors', 'clientb-editors' ] ),
    [ 'sites/clienta', 'sites/clientb', 'sites/shared' ],
    'multiple groups union their allowed domains' );

# --- empty allow-list on a NON-default domain = operator-only ----------------
# locked.com allows no group; even a member of every editor group cannot reach it
# via the allow path.
{
    my $s = scopes( $D, 'ed', [ 'clienta-editors', 'clientb-editors' ] );
    ok( !grep( { $_ eq 'sites/locked' } @$s ),
        'a domain with an empty allow-list is operator-only (no group reaches it)' );
}

# --- lock NARROWS: allowed to two, locked to one => only that one ------------
# alice is in clienta-editors (allows clienta + shared) but is LOCKED to clienta.
is_deeply( scopes( $D, 'alice', ['clienta-editors'] ), ['sites/clienta'],
    'a lock narrows the allowed set to the locked domain only' );

# --- lock that intersects NOTHING allowed => DENY-ALL, never unconfined -------
# bob is locked to locked.com, but no group allows locked.com, so allowed ∩
# locked is empty. He must be confined to nothing - not left unconfined.
is_deeply( scopes( $D, 'bob', ['clienta-editors'] ), [DENY_ALL_SCOPE],
    'a lock with no allowed intersection is deny-all (confined to nothing)' );
isnt( scalar @{ scopes( $D, 'bob', ['clienta-editors'] ) }, 0,
    'the deny-all scope is a NON-empty list (an empty list would mean unconfined)' );

# --- a locked user with an allowed-and-locked match is confined there --------
is_deeply( scopes( $D, 'alice', [ 'clienta-editors', 'clientb-editors' ] ), ['sites/clienta'],
    'even with more groups, a locked user stays confined to the lock ∩ allow' );

# --- read_domains parsing (base + alias keys, host with dots) -----------------
my $dir  = tempdir( CLEANUP => 1 );
my $conf = "$dir/lazysite.conf";
open my $fh, '>', $conf or die $!;
print $fh <<'CONF';
site_name: Agency
content_root: sites/main
alias_hosts: clienta.com, www.clienta.com
alias.clienta.com.content_root: sites/clienta
alias.clienta.com.allowed_groups: clienta-editors, agency-leads
alias.clienta.com.locked_users: alice, clienta-bot
CONF
close $fh;
my $parsed = read_domains($conf);
is( $parsed->{''}{content_root}, 'sites/main', 'base content_root parsed' );
is( $parsed->{'clienta.com'}{content_root}, 'sites/clienta', 'alias content_root parsed (host with a dot)' );
is_deeply( $parsed->{'clienta.com'}{allowed_groups}, [ 'clienta-editors', 'agency-leads' ],
    'allowed_groups parsed as a list' );
is_deeply( $parsed->{'clienta.com'}{locked_users}, [ 'alice', 'clienta-bot' ],
    'locked_users parsed as a list' );

# End to end: parsed domains feed the resolver.
is_deeply( scopes( $parsed, 'alice', ['clienta-editors'] ), ['sites/clienta'],
    'parsed config resolves alice (locked) to her one domain' );

# --- SM165 sub-user ceiling: intersect_scopes --------------------------------
is_deeply( isect( [], ['sites/a'] ), ['sites/a'], 'own unconfined => bounded by the creator' );
is_deeply( isect( ['sites/a'], [] ), ['sites/a'], 'creator unconfined => own scope stands' );
is_deeply( isect( [ 'sites/a', 'sites/b' ], ['sites/a'] ), ['sites/a'],
    'intersection keeps only the shared scope' );
is_deeply( isect( ['sites'], ['sites/a'] ), ['sites/a'], 'the tighter (contained) scope wins' );
is_deeply( isect( ['sites/a'], ['sites'] ), ['sites/a'], 'the tighter scope wins in either order' );
is_deeply( isect( ['sites/a'], ['sites/b'] ), [DENY_ALL_SCOPE],
    'disjoint scopes intersect to deny-all, never unconfined' );
is_deeply( isect( ['sites/a'], [DENY_ALL_SCOPE] ), [DENY_ALL_SCOPE],
    'a deny-all creator caps the sub-user to nothing' );
is_deeply( isect( [], [DENY_ALL_SCOPE] ), [DENY_ALL_SCOPE],
    'even an unconfined sub-user is capped by a deny-all creator' );

done_testing;
