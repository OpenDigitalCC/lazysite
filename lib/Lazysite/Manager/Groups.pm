package Lazysite::Manager::Groups;

# SM1050 (inbox 2026-10-12, P-1, P-2, P-3): groups over the remote doors.
#
# A partner holding manage_users could not see which groups exist (`principals`
# and `users` are cookie-only, and whoami lists only its own) nor create one or
# set what it may do, so provisioning a site's roles stopped for a human every
# time. Ruled by the release manager, 2026-10-12, "Yes, within the delegation
# limit":
#
#   groups-list   read-only, any manage_users holder: names, capabilities,
#                 member counts. A domain-confined caller sees only the groups
#                 relevant to its domains (relevant_groups below says which).
#   group-set     behind manage_users: create a group and turn capabilities on
#                 or off - on only for a capability the caller HOLDS and may
#                 grant (SM195's ceiling, which the users tool applies again as
#                 the store's owner); NEVER the operator flag (`manager`, SM991).
#
# Both are surface-neutral: the control API and MCP each pass WHO is asking
# (%who below) and get the same answer, so the two doors cannot disagree (SM943).
# The store is written only through the users tool, its owner, with the caller
# as `actor`. Reads are in-process.
#
# %who:
#   actor     the account asking (required)
#   held      the capabilities it holds on this door: the token's grant, or the
#             cookie account's effective capabilities
#   confined  1 for a domain-confined caller (every token; a cookie manager
#             whose groups bind a domain)
#   reach     the arguments caller_may_reach_domain takes for this caller:
#             () on the manager request, (scopes => [...]) for an MCP grant
#   operator  1 for the operator (never a token)

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                  ();
use Lazysite::Util            qw(log_event);
use Lazysite::Auth::Settings  ();
use Lazysite::Auth::Acl       ();
use Lazysite::Manager::Common ();

our @EXPORT_OK = qw(groups_list group_set relevant_groups existing_groups);

# Group names the users tool accepts (cmd_group_create, cmd_group_settings_set).
my $NAME_RE = qr/\A[A-Za-z0-9_-]{1,64}\z/;

# The store, read once per call: ( settings hashref, membership hashref ).
sub _store {
    local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $gs = Lazysite::Auth::Settings::read_group_settings();
    my %m  = %{ Lazysite::Auth::Settings::group_members() };
    my $ac = Lazysite::Auth::Settings::account_names();
    return ( ( ref $gs eq 'HASH' ? $gs : {} ), \%m, ( ref $ac eq 'HASH' ? $ac : {} ) );
}

# THE GROUPS THAT EXIST: a name in either store - groups-settings.json (where the
# Groups page and group-create write a new group) or the groups file (where
# membership lives). SM1045's definition, asked of Settings::group_names, which
# acl-set and a domain's allowed_groups (SM1016) ask too; the users tool's
# group-create and group-nest ask the same union.
sub existing_groups {
    local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $g = Lazysite::Auth::Settings::group_names();
    return ref $g eq 'HASH' ? $g : {};
}

# WHICH GROUPS A DOMAIN-CONFINED CALLER SEES. A group is relevant to it when:
#
#   (a) a domain the caller reaches names the group in its allowed_groups - the
#       groups that bind that domain's editors (caller_may_reach_domain decides
#       the domains, as every other confined read does);
#   (b) the caller is a member of the group, directly or through nesting
#       (Settings::effective_groups) - its own grant;
#   (c) the caller created the group with group-set (`created_by` on the group's
#       record) - the roles it provisioned for its site.
#
# Nothing else: not the operator group (unless (a)-(c) name it), not another
# domain's groups, not a group some other account created. An unconfined caller
# (the operator, a cookie manager bound to no domain) sees every group.
sub relevant_groups {
    my (%who) = @_;
    my ( $gs, $m ) = _store();
    my $all = existing_groups();
    return $all unless $who{confined};

    my %rel;
    my $actor = $who{actor} // '';

    # (a) the allowed_groups of each domain the caller reaches.
    require Lazysite::Manager::Domains;
    {
        no warnings 'once';
        local $Lazysite::Manager::Domains::DOCROOT = $Lazysite::Manager::Domains::DOCROOT
            // $Lazysite::Manager::Common::DOCROOT // $ENV{DOCUMENT_ROOT};
        my $list = eval { Lazysite::Manager::Domains::domains_list() };
        for my $d ( ref $list eq 'HASH' && $list->{ok} ? @{ $list->{domains} || [] } : () ) {
            next if $d->{is_primary};
            next unless Lazysite::Manager::Common::caller_may_reach_domain(
                @{ $who{reach} || [] }, host => $d->{host} );
            my $ag = $d->{allowed_groups} // '';
            $rel{$_} = 1 for grep { length } map { s/^\s+|\s+$//gr } split /,/,
                ( ref $ag eq 'ARRAY' ? join( ',', @$ag ) : $ag );
        }
    }

    # (b) its own groups.
    {
        local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
        $rel{$_} = 1 for Lazysite::Auth::Settings::effective_groups($actor);
    }

    # (c) the groups it created.
    for my $g ( keys %$gs ) {
        my $rec = $gs->{$g};
        $rel{$g} = 1 if ref $rec eq 'HASH' && length $actor && ( $rec->{created_by} // '' ) eq $actor;
    }

    return { map { $_ => 1 } grep { $all->{$_} } keys %rel };
}

# groups-list / list_groups.
sub groups_list {
    my (%who) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'Groups are listed for a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    my ( $gs, $m, $accounts ) = _store();
    my $show = relevant_groups(%who);
    my @caps = @Lazysite::Auth::Settings::CAP_KEYS;
    my @rows;
    for my $g ( sort keys %$show ) {
        my $rec     = ref $gs->{$g} eq 'HASH' ? $gs->{$g} : {};
        my @members = @{ $m->{$g} || [] };
        push @rows, {
            name => $g,
            ( defined $rec->{label} && length $rec->{label} ? ( label => $rec->{label} ) : () ),
            caps     => [ grep { $rec->{$_} } @caps ],
            members  => scalar( grep { $accounts->{$_} } @members ),
            operator => ( $rec->{manager} ? JSON::PP::true() : JSON::PP::false() ),
            ( ( $rec->{created_by} // '' ) eq $who{actor} ? ( yours => JSON::PP::true() ) : () ),
        };
    }
    return { ok => 1, groups => \@rows,
        ( $who{confined} ? ( confined => JSON::PP::true() ) : () ),
        note => 'caps are the capabilities the group itself turns on; a group nested '
            . 'inside another also passes on that group\'s. members counts the accounts '
            . 'directly in the group.' };
}

# A requested setting's value, as on/off, or undef when it is neither.
sub _bool {
    my ($v) = @_;
    return undef unless defined $v;
    return ( $v ? 1 : 0 ) if ref $v eq 'JSON::PP::Boolean';
    return undef          if ref $v;
    return 1              if $v =~ /\A(?:1|true|on|yes)\z/i;
    return 0              if $v =~ /\A(?:0|false|off|no)\z/i;
    return undef;
}

# group-set / set_group: create $group if it does not exist, then set each
# capability named in $want ({ cap => true|false }). Validated whole before
# anything is written: a refusal changes nothing.
sub group_set {
    my ( $group, $want, %who ) = @_;
    my $actor = $who{actor} // '';
    return { ok => 0, kind => 'forbidden',
        error => 'A group is set by a signed-in account, and no account is asking.' }
        unless length $actor;
    return { ok => 0, kind => 'invalid', field => 'group',
        error => 'group is required: a name of letters, digits, _ or - (64 at most).' }
        unless defined $group && !ref $group && $group =~ $NAME_RE;
    $want //= {};
    return { ok => 0, kind => 'invalid', field => 'caps',
        error => 'caps is an object of capability => true or false, e.g. {"webdav": true}.' }
        unless ref $want eq 'HASH';

    # NEVER THE OPERATOR FLAG (ruled). `manager` marks the operator group
    # (SM991); it is not a capability and this action does not set it, whoever
    # asks - the operator sets it with the users tool.
    my @flag = grep { $_ eq 'manager' || $_ eq 'operator' } sort keys %$want;
    return { ok => 0, kind => 'forbidden', field => 'caps',
        error => "group-set never sets the operator flag ('$flag[0]'). Nothing was changed." }
        if @flag;
    my %known = map  { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
    my @bad   = grep { !$known{$_} } sort keys %$want;
    return { ok => 0, kind => 'invalid', field => 'caps',
        error => 'unknown capability: ' . join( ', ', @bad )
            . '. describe-capabilities lists them. Nothing was changed.' }
        if @bad;
    my %to;
    for my $c ( sort keys %$want ) {
        my $v = _bool( $want->{$c} );
        return { ok => 0, kind => 'invalid', field => 'caps',
            error => "caps.$c must be true or false. Nothing was changed." }
            unless defined $v;
        $to{$c} = $v;
    }

    my ( $gs, $m ) = _store();
    my $exists = existing_groups()->{$group} ? 1             : 0;
    my $rec    = ref $gs->{$group} eq 'HASH' ? $gs->{$group} : {};

    # The operator group is the operator's (SM991).
    return { ok => 0, kind => 'forbidden',
        error => "'$group' is the operator group, and only the operator changes it." }
        if $exists && $rec->{manager} && !$who{operator};

    # A domain-confined caller changes the groups it made, and makes new ones.
    # Any other group is another domain's, or the instance's.
    return { ok => 0, kind => 'forbidden',
        error => "'$group' exists and was not created by this account. A domain-confined "
            . 'caller changes only the groups it created with group-set; choose another '
            . 'name, or ask the operator.' }
        if $exists && $who{confined} && ( $rec->{created_by} // '' ) ne $actor;

    # THE DELEGATION LIMIT (ruled: "holds AND may grant"). Turning a capability
    # on needs the caller to hold it; the users tool then asks SM195's ceiling
    # with the caller as actor. Turning one off is de-escalation and needs
    # neither. All are checked before any is written.
    my $held     = ref $who{held} eq 'HASH' ? $who{held} : {};
    my @not_held = grep { $to{$_} && !$held->{$_} } sort keys %to;
    return { ok => 0, kind => 'forbidden', field => 'caps', not_held => \@not_held,
        error => 'You cannot grant ' . join( ', ', map { "'$_'" } @not_held )
            . ': a group is given only capabilities its creator holds. Nothing was changed.' }
        if @not_held;

    my @changes = grep { ( $rec->{$_} ? 1 : 0 ) != $to{$_} } sort keys %to;

    # The writes, through the store's owner.
    my $created = 0;
    unless ($exists) {
        my $r = Lazysite::Manager::Common::users_api(
            { action => 'group-create', group => $group, actor => $actor, created_by => $actor } )
            || {};
        return { ok => 0, kind => ( $r->{kind} // 'error' ),
            error => 'The group could not be created: ' . ( $r->{error} // 'no answer' ) }
            unless $r->{ok};
        $created = 1;
    }
    my ( @granted, @revoked );
    for my $c (@changes) {
        my $r = Lazysite::Manager::Common::users_api(
            { action => 'group-settings-set', group => $group, key => $c,
                value => ( $to{$c} ? 'on' : 'off' ), actor => $actor } )
            || {};
        unless ( $r->{ok} ) {
            return { ok => 0, kind => 'partial', group => $group,
                created => $created, granted => \@granted, revoked => \@revoked,
                error => "'$c' could not be " . ( $to{$c} ? 'granted' : 'revoked' ) . ': '
                    . ( $r->{error} // 'no answer' )
                    . '. The changes listed in granted and revoked were made; the rest were not.',
                change => _change( $created, \@granted, \@revoked ) . "; failed $c" };
        }
        push @{ $to{$c} ? \@granted : \@revoked }, $c;
    }
    log_event( 'INFO', 'group-set', 'group set', group => $group, user => $actor,
        change => _change( $created, \@granted, \@revoked ) );
    my ($after) = _store();
    my $now = ref $after->{$group} eq 'HASH' ? $after->{$group} : {};
    return { ok => 1, group => $group, created => ( $created ? JSON::PP::true() : JSON::PP::false() ),
        granted => \@granted, revoked => \@revoked,
        caps    => [ grep { $now->{$_} } @Lazysite::Auth::Settings::CAP_KEYS ],
        change  => _change( $created, \@granted, \@revoked ) };
}

sub _change {
    my ( $created, $g, $r ) = @_;
    my @bits = ( ( $created ? 'created' : () ),
        ( @$g ? '+' . join( ',+', @$g ) : () ),
        ( @$r ? '-' . join( ',-', @$r ) : () ) );
    return @bits ? join( ' ', @bits ) : 'no change';
}

1;
