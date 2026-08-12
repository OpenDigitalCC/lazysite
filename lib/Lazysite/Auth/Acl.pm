package Lazysite::Auth::Acl;

# SM074 per-file ACL store (lazysite/auth/acls.json) and the ownership/allow
# checks, shared (SM079). Context is $DOCROOT, set by the script. The
# operator-bypass decision (_is_operator) is request-context-bound and stays in
# the manager, which combines it with _acl_allows here.

use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Exporter 'import';

our @EXPORT_OK = qw(load_acls save_acls _acl_norm _to_list _acl_allows _acls_path
    _is_operator _acl_denied);

our $DOCROOT;    # set by the script

# Manager auth-state, set per request by the dispatcher (the operator-bypass
# decision). A token client is never an operator; otherwise group-granted
# capabilities decide (SM138: the conf manager_groups fallback is retired).
our $auth_user  = '';
our $token_auth = 0;

# SM077: the requesting user's groups (for @group ACL entries), set per request
# by the dispatcher.
#
# WHAT EACH CHANNEL SETS - they do not agree, and this comment used to claim
# they did ("a token/WebDAV partner carries none"), which is false for WebDAV
# and was copied into the architecture doc and believed for a year:
#
#   lazysite-dav.pl         user_groups_for($user) - the account's REAL groups,
#                           so an @group entry DOES match a WebDAV partner
#   lazysite-mcp.pl         () - hard-zeroed, so an @group never matches
#   lazysite-manager-api.pl HTTP_X_REMOTE_GROUPS - the session's groups for a
#                           cookie client, empty for a token client
#
# One store answering one question three ways by channel. SM288 tracks making
# MCP and the token path resolve the account's groups as WebDAV already does;
# until then, name a partner explicitly rather than relying on its group.
our @user_groups;

sub _acls_path { "$DOCROOT/lazysite/auth/acls.json" }

sub load_acls {
    my $path = _acls_path();
    return {} unless -f $path;
    open my $fh, '<', $path or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $m = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ref $m eq 'HASH' ? $m : {};
}

sub save_acls {
    my ($map) = @_;
    my $path = _acls_path();
    my $dir  = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($map);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $path;
}

# Strip leading slashes so an ACL key matches the manager's relative paths.
sub _acl_norm { my $r = shift; $r =~ s{^/+}{} if defined $r; return $r }

# Normalise a list value (arrayref or comma/space string) to an arrayref,
# or undef if not provided.
sub _to_list {
    my ($v) = @_;
    return undef unless defined $v;
    return [ grep { length } @$v ] if ref $v eq 'ARRAY';
    return [ grep { length } split /[,\s]+/, $v ];
}

# Does the ACL for $rel allow $user $mode access? No entry = allowed (the
# account's scope governs); owner always allowed; else membership of the
# mode's allow-list.
# SM268 H3: which entry governs $rel for $mode - exact, then the section's own
# landing page, then the LONGEST matching folder prefix.
#
# Folder scope was implemented only in the processor's module-free copy, so a
# "protected section" was protected on the anonymous read path and nowhere else:
# Acl::_acl_allows matched the exact key only, and the manager, MCP and WebDAV
# therefore granted full READ AND WRITE inside a section the operator had gated.
# An adversarial review demonstrated it. One store answering two different
# questions depending on which surface asks is precisely what SM223 chose a
# single store to avoid.
#
# Only entries carrying a non-empty list for the mode participate, so an
# owner-only entry - which action_copy writes for every duplicated file - cannot
# beat an enclosing folder rule. It is not a tighter rule, it is no rule.
sub _acl_entry_for {
    my ( $map, $rel, $mode ) = @_;
    $rel = _acl_norm($rel) // '';

    my $governs = sub {
        my ($e) = @_;
        return 0 unless ref $e eq 'HASH';
        return 1 unless defined $mode && length $mode;
        return ( ref $e->{$mode} eq 'ARRAY' && @{ $e->{$mode} } ) ? 1 : 0;
    };

    return $map->{$rel} if $governs->( $map->{$rel} );

    if ( $rel =~ m{\A(.+)\.(?:md|url|html)\z} ) {
        my $stem = $1;
        return $map->{$stem} if $governs->( $map->{$stem} );
    }

    my $best;
    my $best_len = -1;
    for my $k ( keys %$map ) {
        next unless $governs->( $map->{$k} );
        ( my $p = $k ) =~ s{\A/+}{};
        $p =~ s{/+\z}{};
        next unless length $p;
        next unless index( $rel, "$p/" ) == 0;
        next unless length($p) > $best_len;
        $best     = $map->{$k};
        $best_len = length $p;
    }
    return $best;
}

sub _acl_allows {
    my ( $rel, $mode, $user ) = @_;
    my $a = _acl_entry_for( load_acls(), $rel, $mode );
    return 1 unless $a;
    return 1 if defined $a->{owner} && defined $user && $a->{owner} eq $user;
    my $list = $a->{$mode};
    return 1 unless ref $list eq 'ARRAY' && @$list;
    # SM268 01-L1: case-insensitive, and compound-expanded - the same semantics
    # the processor's copy uses (t/lint/31 pins the pair) and the same ones
    # check_auth applies to `groups:` front matter. Three different answers to
    # "is this user in that group" on one request was the defect.
    require Lazysite::Auth::Settings;
    my %grp = map { lc($_) => 1 }
        do {
        local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
        Lazysite::Auth::Settings::group_closure(@user_groups);
        };
    for my $entry (@$list) {
        next unless defined $entry && length $entry;
        if ( $entry =~ /\A\@(.+)\z/ ) {          # SM077: @group entry
            return 1 if $grp{ lc $1 };
        }
        elsif ( defined $user && $entry eq $user ) {
            return 1;
        }
    }
    return 0;
}

# Operator bypass (manager-only). A token (control-API) client is NEVER an
# operator - per-file ACL ownership applies to it like any WebDAV partner. An
# unsecured site (no manager_groups) treats cookie clients as operators; the
# 'local' user is always operator; else manager-group membership decides. The
# token path never consults the client-influenceable X-Remote-Groups.
# SM095: does any of these groups carry capability $cap? Routed through the
# shared resolver helper (ADR 0001) - AUTH_DIR localised from this module's
# request context so callers that only set Acl::DOCROOT keep working.
sub _groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    require Lazysite::Auth::Settings;
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";
    return Lazysite::Auth::Settings::groups_grant_cap( $cap, @groups );
}

sub _is_operator {
    return 0 if $token_auth;
    return 1 if ( $auth_user // '' ) eq 'local';

    require Lazysite::Auth::Settings;
    local $Lazysite::Auth::Settings::AUTH_DIR = "$DOCROOT/lazysite/auth";

    # SM095/SM138: unrestricted account management is the manage_users
    # capability, granted through a group. The legacy lazysite.conf
    # manager_groups fallback is RETIRED - the migration granted those groups
    # their capabilities explicitly.
    #
    # SM268 02-7: ask the STORE FIRST, then the header - not the header alone.
    #
    # The two sources disagree for a session whose group set changed after the
    # header was written, and the header is the stale one. Asking the store
    # first means a grant that exists NOW is honoured now, which is the
    # direction that matters: it is how a revoked grant stops applying and a
    # fresh one starts.
    #
    # The header is NOT dropped, though the review suggested it. It carries
    # group names for identities the local store does not know - a trusted
    # reverse proxy or SSO, where membership lives in the IdP and the account
    # may not exist here at all. t/unit/manager/16 asserts exactly that case
    # (an operator known only as X-Remote-Groups: managers), so removing the
    # header check trades a LOW consistency finding for a broken deployment.
    # It reaches this code only when the wrapper set LAZYSITE_AUTH_TRUSTED, so
    # it is vouched for; the remaining objection was staleness, and consulting
    # the store first is what answers that.
    if ( defined $auth_user && length $auth_user ) {
        my $caps = eval { Lazysite::Auth::Settings::caps_for($auth_user) } || {};
        return 1 if $caps->{manage_users};
    }
    my @ug = grep { length } split /[,\s]+/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' );
    return 1 if _groups_grant_cap( 'manage_users', @ug );

    # A site where no group grants manager access at all is unsecured/dev: any
    # authenticated user is an operator.
    return 1 unless Lazysite::Auth::Settings::site_grants_manager();
    return 0;
}

# Combine operator bypass + the per-file allow check; returns a refusal hashref
# or undef if access is allowed.
sub _acl_denied {
    my ( $rel, $mode, $user ) = @_;
    return undef if _is_operator();
    return undef if _acl_allows( $rel, $mode, $user );
    return { ok => 0, error => "You do not have $mode access to this file", kind => 'permission' };
}

1;
