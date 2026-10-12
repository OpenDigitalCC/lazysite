package Lazysite::Manager::Users;

# Users and identity: who the caller is (whoami), the accounts and groups a
# picker offers (principals), the names that go with logins (display-names),
# the account store itself (users, through the users tool), the "sign
# everyone out" lever (rotate-auth-secret), and who is asking for
# Lazysite::Handlers' destination check. Moved out of lazysite-manager-api.pl
# unchanged by SM944 S32 (ruled 2026-10-10, "Yes, all four"); the users-tool
# client, the caps memo and the operator memo it reads are
# Lazysite::Manager::Common's (S22b, S32).
#
# Index
#   action_whoami                  whoami: the account asking, its grant and the site
#   _manager_groups_from_settings  the groups that confer manager access (SM138)
#   _handler_who                   who is asking, for Handlers' destination check
#   action_display_names           display-names: the names for logins a page holds
#   action_principals              principals: the accounts and groups to grant to
#   action_users                   users: the account store, through the users tool
#   action_rotate_auth_secret      rotate-auth-secret: sign every session out
#
# The request context ($auth_user, $token_auth, %token_caps) is read from
# Lazysite::Manager::Common, which lazysite-manager-api.pl sets and nothing here
# assigns (t/lint/217). Loaded where no request set the context, each action
# refuses (t/unit/manager/205, 220, 222, 223). $DOCROOT and $LAZYSITE_DIR are
# set by the dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use File::Basename            qw(dirname);
use File::Path                qw(make_path);
use IPC::Open2                qw(open2);
use JSON::PP                  qw(encode_json decode_json);
use Lazysite::Util            qw(log_event);
use Lazysite::Capabilities    qw(reachability);
use Lazysite::Auth::Settings  ();
use Lazysite::Auth::Acl       ();
use Lazysite::Manager::Common qw($auth_user $token_auth %token_caps
    users_api _users_tool_path _user_caps _operator _display_names _users_tool_run);
use Lazysite::Manager::Themes   qw(_read_active_layout_and_theme action_theme_list);
use Lazysite::Manager::Layouts  qw(action_layouts_available);
use Lazysite::Manager::Plugins  qw(action_plugin_list);
use Lazysite::Manager::Services qw(action_version _service_state);
use Lazysite::Manager::Describe qw(site_capabilities);
use Lazysite::Manager::Config   qw(_language_context);

our @EXPORT_OK = qw(action_whoami _manager_groups_from_settings _handler_who
    action_display_names action_principals action_users action_rotate_auth_secret _users_tool_call);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

sub action_whoami {
    my ( $user, $want_plugins ) = @_;
    # SM944 S32 (3), ruled 2026-10-10 ("Yes, all four"): WHOAMI ANSWERS FOR THE
    # ACCOUNT THAT IS ASKING, AND FOR NO OTHER. Inside a request the dispatcher
    # passes $auth_user, which it has refused empty, so the answer there is the
    # same; reached outside one it answered for account '' and for any account
    # it was handed, with nobody signed in as it
    # (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'whoami answers for the signed-in account that is asking, and only for it.' }
        unless defined $user && length $user && $user eq $auth_user;

    # SM671: THE PLUGIN INVENTORY IS OPT-OUT, NOT OPT-IN.
    #
    # `whoami` is what an agent calls to answer "who am I and what may I do",
    # and the field reported the answer being mostly a plugin catalogue - paid
    # on every preflight, and preflight is now standing practice for a testing
    # agent, once per account per run.
    #
    # Omitting it by default would be the leaner answer and a BREAKING one: a
    # client reading `plugins` would silently start seeing an empty list, and
    # this release is bound for stable across a fleet. So the array stays, and
    # `plugins=0` gets the lean response. Additive, nothing breaks, and the
    # caller who cares about the cost is exactly the caller who will pass it.
    my $skip_plugins = ( defined $want_plugins && $want_plugins =~ /\A(?:0|no|false|off)\z/i ) ? 1 : 0;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();

    return {
        ok => 1,
        # SM821: `user`, as MCP's whoami names it - one name for the identity on
        # both surfaces.
        user => $user,
        # SM612: the same build field the MCP whoami carries. The two doors
        # answer the same question the same way, or an agent that switches
        # surface gets a different answer about the same instance.
        engine_version => ( action_version() || {} )->{version},
        # SM094: the site's manager groups, so the Users UI can tell which accounts
        # are sysops (full access) vs partners gated by the capability toggles.
        # SM138: derived from group settings (ui / manage_users / the manager
        # flag) - the conf manager_groups key is retired.
        # SM565: the group names are returned only to a caller who may manage
        # accounts; a floor caller learns its own shape, never the site's.
        ( $s->{manage_users} ? ( manager_groups => [ _manager_groups_from_settings() ] ) : () ),
        # SM821: `capabilities` (exactly @CAP_KEYS; `ui` is the manager
        # capability) and `account` (the record: groups, email, provenance,
        # token and MFA state, and `interactive_login`), from the one builder
        # MCP's whoami uses, over the EFFECTIVE settings. Before, this `ui`
        # reported the login setting, and MCP put the whole settings map under
        # `capabilities`.
        Lazysite::Capabilities::whoami_grant($s),
        # SM491: per held capability, which channels of THIS grant reach it
        # (via) and which would but are off (requires). Same derivation as the
        # MCP whoami, so the two doors cannot disagree. THIS LINE WAS IN THE
        # SM491 WORKTREE AND NOT IN ITS COMMIT - the landing lost the API half
        # and no test noticed, because the test pinned the derivation and
        # neither surface's emission. t/integration/69 now pins both.
        reachable => reachability($s),
        # SM740: which capabilities reported false above are nonetheless SATISFIED
        # by a stronger one this account holds - manage_data admits everything
        # write_data unlocks - so a false never reads as a withholding. The same
        # derivation the MCP whoami uses.
        implied => Lazysite::Capabilities::implications($s),
        # SM612: WHICH TRANSPORTS THIS INSTANCE HAS SWITCHED ON, beside what
        # the grant holds. Reported as its own block rather than folded into
        # `reachable`, for two reasons found by trying the other way: services
        # are OPT-IN, so an absent key reads as off and folding it in would
        # have reported every api capability unreachable on any site that had
        # not enabled the control API; and `reachable` covers api and mcp only,
        # while the case that prompted this was WEBDAV - a grant holding it
        # while PROPFIND answered 404 for everyone.
        services => _service_state(),
        scope    => {
            # SM155: group-derived; a comma-joined list for a multi-domain editor.
            allow => ( @{ $s->{dav_scopes} || [] }
                ? join( ', ', @{ $s->{dav_scopes} } ) : '/' ),
            deny => [ '/cgi-bin/', '/manager/', '/lazysite/auth/',
                '/lazysite/forms/smtp.conf',    '/lazysite/forms/handlers.conf',
                '/lazysite/forms/submissions/', '/lazysite/cache/',
                '/lazysite/logs/',              '/lazysite/manager/',
                '/lazysite/templates/',         '/lazysite/lazysite.conf', '*.pl' ],
        },
        layouts => {
            active_layout => $active_layout,
            active_theme  => $active_theme,
            available     => ( action_layouts_available() || {} )->{layouts} || [],
        },
        # SM565: the theme inventory answers a caller who may change themes or
        # layouts; the plugin list stays for everyone (site_capabilities already
        # names the enabled ones) but its configuration schemas - keys, labels,
        # defaults, notes - answer only a caller holding manage_config.
        ( ( $s->{manage_themes} || $s->{manage_layouts} )
            ? ( themes => ( action_theme_list() || {} )->{themes} || [] )
            : () ),
        # SM589: the inventory says WHICH FEATURES EXIST, which is what a
        # partner needs before it can use one. It stopped short of saying how
        # the site is INSTALLED.
        #
        # `_script` and `config_file` are internal filesystem paths and are
        # withheld from every caller here - the Plugin Manager reads them from
        # `plugin-list`, which is gated separately, so nothing in the UI loses
        # them. `_enabled` is what is switched on: a caller who may configure
        # the site has a reason to know, and so does one holding a capability
        # the plugin itself governs (a manage_briefs holder learning the briefs
        # plugin is off is being told about its own capability, not about the
        # site's shape). Everyone else gets id, name, description and version.
        ( $skip_plugins ? () : ( plugins => [
                    map {
                        my $p = $_;
                        my @owns = ( ref $p->{owns} eq 'HASH' && ref $p->{owns}{capabilities} eq 'ARRAY' )
                            ? @{ $p->{owns}{capabilities} } : ();
                        my $may_see_state = $s->{manage_config} || ( grep { $s->{$_} } @owns );
                        my %out           = %$p;
                        delete @out{qw(_script config_file)};
                        delete $out{_enabled}                      unless $may_see_state;
                        delete @out{qw(config_schema config_keys)} unless $s->{manage_config};
                        \%out;
                    } @{ ( action_plugin_list() || {} )->{plugins} || [] }
        ] ) ),
        # SM072: site-level capabilities from enabled plugins (e.g. email-send).
        site_capabilities => site_capabilities(),
        # SM179 P7: when the bound site is a language-set member, tell the agent
        # its language, the group, and where every sibling's files live - so it
        # knows immediately a translation counterpart exists without probing.
        %{ _language_context($s) // {} },
    };
}

# SM138: the groups that confer manager access, read from group settings.
sub _manager_groups_from_settings {
    my $gs  = Lazysite::Auth::Settings::read_group_settings();
    my @mgr = sort grep {
        my $c = $gs->{$_};
        ref $c eq 'HASH' && ( $c->{ui} || $c->{manage_users} || $c->{manager} );
    } keys %{$gs};
    return @mgr;
}

# SM842: who is asking, for Lazysite::Handlers' destination check. The token
# channel carries its grant; a cookie session carries its account's, and an
# operator passes every capability gate on this channel already, so it passes
# this one.
sub _handler_who {
    return ( caps          => \%token_caps ) if $token_auth;
    return ( unconstrained => 1 )            if _operator();
    return ( caps          => _user_caps($auth_user) );
}

# SM778: the read action a page calls with an ordinary session - resolve the
# logins I already hold, and nothing else. No capability beyond being signed
# in, because it answers only about logins the caller supplied; it is not a
# listing and must never become one. `logins` comes as an array in the body or
# a comma-separated list in the query, so a plain GET works on both channels.
sub action_display_names {
    my ($raw) = @_;
    # SM944 S32 (4), ruled 2026-10-10 ("Yes, all four"): NAMES ARE RESOLVED FOR
    # AN ACCOUNT - "being signed in" is this action's whole grant, above. Inside a
    # request the dispatcher has refused an empty $auth_user before this runs,
    # so it is never empty here; reached outside one (the request context's
    # reset leaves nobody) it resolved the names asked
    # (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'Display names are resolved for a signed-in account, and no account is asking.' }
        unless length $auth_user;
    my @logins
        = ref $raw eq 'ARRAY'             ? @{$raw}
        : ( defined $raw && length $raw ) ? ( split /\s*,\s*/, $raw )
        :                                   ();
    return { ok => 0, kind => 'invalid', field => 'logins',
        error => 'logins must be an array of logins (or a comma-separated list)' }
        unless @logins;
    # A cap, so one call cannot be turned into a walk of the account store by
    # supplying every plausible login: this resolves a page's worth of names.
    return { ok => 0, kind => 'invalid', field => 'logins',
        error => 'Too many logins in one call (200 at most)' }
        if @logins > 200;
    return { ok => 1, _display_names(@logins) };
}

# SM077: assignable principals for the permissions pickers - usernames + group
# names only (no settings/records). Cookie-manager action, like 'users'.
sub action_principals {
    # SM944 S32 (4), ruled 2026-10-10 ("Yes, all four"): THE PRINCIPALS ARE
    # LISTED FOR AN ACCOUNT. Inside a request the dispatcher has refused an empty
    # $auth_user (and asked for `manage_content` or `manage_domains`) before this
    # runs, so it is never empty here; reached outside one (the request
    # context's reset leaves nobody) it listed every account and group
    # (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'The principals are listed for a signed-in account, and no account is asking.' }
        unless length $auth_user;
    my $u      = users_api( { action => 'list' } )   || {};
    my $g      = users_api( { action => 'groups' } ) || {};
    my @users  = ref $u->{users} eq 'ARRAY' ? @{ $u->{users} }                : ();
    my @groups = ref $g->{groups} eq 'HASH' ? ( sort keys %{ $g->{groups} } ) : ();
    # SM778: the permissions pickers are the surface the report was about -
    # they offered a list of logins to grant to and no way to tell two people
    # apart.
    return { ok => 1, users => \@users, groups => \@groups, _display_names(@users) };
}

# SM991: the users-tool verbs that only READ. Everything else the Users API
# passes on changes an account, a group or a credential.
my %USERS_READ_ONLY = map { $_ => 1 } qw(
    list groups users-detail users-page group-settings-get settings-get settings
    permissions-grid capability-holders permissions credential-status keys-list
    partner-caps audit-scope principals recent-changes sessions-list
);

# SM991: a refusal when a caller who is not the operator asks to change the
# operator's account, or a group whose membership makes an operator; undef
# otherwise. The names a verb can carry are all looked at - the account in
# `username`; `group`, and a nest's `sub` and `parent` - so a verb added later
# is covered by the parameter it takes.
sub _operator_target_refusal {
    my ( $act, $p ) = @_;
    return undef if $USERS_READ_ONLY{$act};
    {
        my $u = $p->{username};
        last unless defined $u && !ref $u && length $u;
        return { ok => 0, kind => 'forbidden',
            error => "'$u' is the site operator (a member of the operator group). "
                . 'Only the operator changes the operator\'s account.' }
            if Lazysite::Auth::Acl::account_is_operator($u);
    }
    for my $k (qw(group sub parent)) {
        my $g = $p->{$k};
        next unless defined $g && !ref $g && length $g;
        return { ok => 0, kind => 'forbidden',
            error => "'$g' is the operator group, or makes its members operators. "
                . 'Only the operator changes it or who belongs to it.' }
            if Lazysite::Auth::Acl::group_confers_operator($g);
    }
    return undef;
}

sub action_users {
    my ( $request_body, $params_ref ) = @_;
    # SM944 S32 (4), ruled 2026-10-10 ("Yes, all four"): THE ACCOUNT STORE IS
    # READ AND CHANGED FOR AN ACCOUNT. Inside a request the dispatcher has refused
    # an empty $auth_user (and asked for a user-management capability) before
    # this runs, so it is never empty here; reached outside one (the request
    # context's reset leaves nobody) it listed every account
    # (tmp/sm944-s31-s32-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'Accounts are managed by a signed-in account, and no account is asking.' }
        unless length $auth_user;

    my $users_script = _users_tool_path();
    return { ok => 0, error => "User management not available" }
        unless $users_script;

    # The child (tools/lazysite-users.pl --api) always expects a single
    # JSON object on stdin. If we're hit with a plain GET (empty body),
    # pipe through a read-only request derived from the query string
    # rather than feeding the child an empty buffer and surfacing its
    # "Invalid JSON input" reply. Allowed GET sub-actions are list and
    # groups; writes (add / passwd / remove / group-add / group-remove)
    # must go via POST so they pass through the CSRF gate upstream.
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    if ( $method ne 'POST' || !length $request_body ) {
        my $sub = ( $params_ref && $params_ref->{sub} ) || 'list';
        return { ok => 0, error => "Read-only sub-action on GET; allowed: list, groups" }
            unless $sub eq 'list' || $sub eq 'groups';
        $request_body = encode_json( { action => $sub } );
    }

    # SM071/SM072: scope sub-user management to the actor's own sub-tree.
    # claim-redeem is the PUBLIC redemption flow (lazysite-auth.pl /claim) -
    # the user sets their own secret, so it is never a manager action and is
    # refused here. For the account-* actions and claim-create (Generate setup
    # link / Reset credential) we inject actor=$auth_user so the users tool
    # confines a DELEGATED sub-manager to its own sub-tree.
    #
    # A manager-group sysop (and 'local', the sysadmin) is unrestricted and gets NO
    # actor, or it can only manage accounts it personally created - the cause
    # of "Not authorised to manage 'X'" when an operator generates a setup
    # link for a user it owns through the tree but did not directly create.
    # created_by still defaults to the actor so a new account has an owner.
    if ( length $request_body ) {
        my $parsed = eval { decode_json($request_body) };
        if ( ref $parsed eq 'HASH' ) {
            my $act = $parsed->{action} // '';
            return { ok => 0, error => "claim-redeem is not a manager action" }
                if $act eq 'claim-redeem';

            # SM1040: a password change or a 2FA disable signs the account's
            # other sessions out and keeps the one making the change - which is
            # this request's session only when the account is the caller's own.
            # The session to keep is never taken from the request: a body that
            # names one is ignored, so nobody can keep alive the session the
            # change was meant to end.
            {
                my $had = exists $parsed->{keep_sid};
                delete $parsed->{keep_sid};
                my $sid = $ENV{LAZYSITE_AUTH_SID} // '';
                if ( $act =~ /\A(?:passwd|mfa-disable)\z/
                    && $sid =~ /\A[0-9a-f]{16}\z/
                    && ( $parsed->{username} // '' ) eq $auth_user )
                {
                    $parsed->{keep_sid} = $sid;
                }
                $request_body = encode_json($parsed)
                    if $had || exists $parsed->{keep_sid};
            }

            # SEC-2026-07 (C1): a DELEGATED sub-manager (create_sub_users, not
            # full manage_users) may run only sub-tree-confinable operations on
            # its own descendants. The powerful account operations - group
            # membership, capability settings, account removal, token minting,
            # top-level add - require full manage_users, or a delegate could add
            # itself to an admin group / reset another account. Operators and
            # 'local' bypass. passwd is now actor-confined (below + in the tool).
            # SM194: account-promote (managed_by clear) and
            # account-scope-independent (created_by ceiling lift) are OPERATOR-
            # ONLY by omission from %DELEGABLE - a delegate promoting its own
            # child out from under itself would defeat confinement. The tool
            # refuses them for any present actor too (defence in depth).
            if ( $auth_user ne 'local' && !_operator() && !_user_caps($auth_user)->{manage_users} ) {
                my %DELEGABLE = map { $_ => 1 } qw(
                    account-create account-disable account-enable account-reassign
                    rename claim-create claim-cancel passwd
                    list groups users-detail settings-get group-settings-get
                    users-page principals recent-changes keys-list sessions-list
                );
                return { ok => 0, kind => 'forbidden',
                    error => "That account operation requires the 'Users & groups' "
                        . "permission (full user management)." }
                    unless $DELEGABLE{$act};
            }

            # SM991 (ruled 2026-10-12, "Operators bypass, others bound"): THE
            # OPERATOR'S ACCOUNT AND THE OPERATOR GROUP ARE THE OPERATOR'S.
            # manage_users is user and group management, and the operator is
            # no longer whoever holds it - so a holder that could reset the
            # operator's password, mint it a credential or a setup link, or
            # put itself in the operator group would become the operator by
            # one call. The users tool's ceiling already refuses JOINING the
            # operator group to anyone but `local` (it walks the `manager`
            # flag with the capabilities); this refuses the rest, for every
            # caller who is not the operator: any change to an account that
            # is the operator, or to a group whose membership makes one.
            if ( $auth_user ne 'local' && !_operator() ) {
                if ( my $r = _operator_target_refusal( $act, $parsed ) ) { return $r }
            }

            # SM195: group-settings-set now enforces a per-capability ceiling in
            # the tool (a non-operator may confer only what they hold, or what an
            # operator put in their groups' grantable set) - so the tool has to
            # KNOW who is asking. Without this the actor arrived undefined and the
            # ceiling silently did not apply, which is how the hole existed:
            # manage_users was the whole check.
            # NOT gated on _is_operator(). That returns TRUE for anyone holding
            # manage_users (Acl.pm:116), which is exactly the population the
            # ceiling exists to bound - so gating on it meant no actor was passed
            # for a delegate, the tool saw a sysop, and the ceiling never ran.
            # An adversarial review found that; the first cut of SM195 was inert
            # through the manager while its unit test passed, because the test
            # supplied the actor this line did not.
            #
            # The tool decides. `local` is the CLI/sysop sentinel and is the
            # only exemption here; the unsecured-site exemption lives in
            # _may_confer, where it can be stated once for every caller.
            # SM268 H8: the ceiling now covers every verb that can RAISE
            # privilege, not just the one that declares a capability - joining a
            # capable group, nesting one, and minting a credential all acquire
            # capabilities by another route. Each needs the actor, or the tool
            # sees a sysop and the ceiling does not run.
            if ( $auth_user ne 'local'
                && $act =~ /\A(?:group-settings-set|group-add|group-nest|token)\z/ )
            {
                $parsed->{actor} = $auth_user;
                $request_body = encode_json($parsed);
            }

            # SM346: the Users page needs to know WHO IS ASKING to decide which
            # sysop-only controls to show. Its single consolidated call
            # replaced three - one of which was whoami - and carried forward the
            # data and not the identity, so the page computed "am I a sysop"
            # against an empty username and got false for everybody.
            #
            # A separate key from `actor` on purpose: `actor` is an
            # authorisation signal (the users tool refuses privileged verbs when
            # it names a non-sysop), and this is a read-only call that just
            # needs a name to match against group membership.
            if ( $auth_user ne 'local' && $act eq 'users-page' ) {
                $parsed->{me} = $auth_user;
                $request_body = encode_json($parsed);
            }

            if ( $auth_user ne 'local'
                && $act =~ /^(?:account-(?:create|disable|enable|reassign)|claim-create|claim-cancel|rename|passwd)$/x ) {
                # SM991: a manage_users holder is not the operator, and is still
                # FULL user management - unconfined here as it was when it was
                # the operator. A delegate (create_sub_users) is confined.
                $parsed->{actor} = $auth_user
                    unless _operator() || _user_caps($auth_user)->{manage_users};
                $parsed->{created_by} //= $auth_user if $act eq 'account-create';
                $request_body = encode_json($parsed);
            }
        }
    }

    my ( $child_out, $child_in );
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $pid = eval {
        open2( $child_out, $child_in,
            $^X, $users_script, '--api', '--docroot', $DOCROOT );
    };
    return { ok => 0, error => "Cannot run user management: $@" } unless $pid;

    print $child_in $request_body;
    close $child_in;

    my $output = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;

    my $result = eval { decode_json( $output // '{}' ) } // { ok => 0, error => "Invalid response" };
    # The combined Users-page call folds in the current sysop's identity so the
    # browser needs no separate whoami round-trip (its shape carries users+groups).
    if ( ref $result eq 'HASH' && $result->{ok}
        && exists $result->{users} && exists $result->{groups} ) {
        $result->{me} = $auth_user;
    }

    # SM778: the logins this response hands back, named.
    #
    # `users` is either an array of logins (list) or an array of
    # {user,settings} rows (users-detail / users-page, whose settings already
    # carry the name); `groups` is group => [members], and a member may itself
    # be a group name (SM121 compound groups), which simply has no entry.
    # Resolving the union costs one memoised read whichever shape arrives.
    if ( ref $result eq 'HASH' && $result->{ok} ) {
        my %logins;
        if ( ref $result->{users} eq 'ARRAY' ) {
            for my $u ( @{ $result->{users} } ) {
                my $l = ref $u eq 'HASH' ? $u->{user} : $u;
                $logins{$l} = 1 if defined $l && length $l;
            }
        }
        if ( ref $result->{groups} eq 'HASH' ) {
            for my $members ( values %{ $result->{groups} } ) {
                next unless ref $members eq 'ARRAY';
                $logins{$_} = 1 for grep { defined && length } @{$members};
            }
        }
        if (%logins) { %$result = ( %$result, _display_names( sort keys %logins ) ) }
    }
    return $result;
}

# Rotate the per-installation HMAC secret in lazysite/auth/.secret.
# Every existing auth cookie is signed with the previous secret, so
# rewriting this file invalidates every outstanding session (the
# operator's own session included). This is the "log everyone out"
# lever - the server-side mitigation for the known "no session
# revocation" constraint.
sub action_rotate_auth_secret {
    my ($user) = @_;
    # SM944 ITEM 1, a security fix (ruled 2026-10-10, "SECURITY first"): THE
    # SECRET IS ROTATED FOR AN ACCOUNT. Inside a request the dispatcher has
    # refused an empty $auth_user before it passes it here, so $user is never
    # empty; reached outside one (the request context's reset leaves nobody)
    # this rotated the site's auth secret - signing every session out - with
    # nobody asking (tmp/sm944-s31-s32-refusal-probe.out). Refused before
    # /dev/urandom is opened.
    return { ok => 0, kind => 'forbidden',
        error => 'The auth secret is rotated for a signed-in account, and no account is asking.' }
        unless defined $user && length $user;
    # SM944 Q14 n342, ruled 2026-10-11 ("Yes, same as whoami"): AND FOR THE
    # ACCOUNT THAT IS ASKING. The refusal above trusted the account it was
    # handed, so a caller outside a request that named one still rotated. Inside
    # a request the dispatcher passes $auth_user itself, so the answer there is
    # the same. Users holds no per-module copy of the account: $auth_user here
    # is Manager::Common's request fact.
    return { ok => 0, kind => 'forbidden',
        error => 'The auth secret is rotated for the signed-in account that is asking, and only for it.' }
        unless $user eq $auth_user;
    my $path = "$LAZYSITE_DIR/auth/.secret";

    # Fail closed if CSPRNG unavailable (M-6 convention)
    open my $rand, '<:raw', '/dev/urandom'
        or return { ok => 0, error => "Cannot open /dev/urandom: $!" };
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    return { ok => 0, error => "Short read from /dev/urandom ($got of 32)" }
        unless defined $got && $got == 32;
    my $new = unpack( 'H*', $raw );

    make_path( dirname($path) ) unless -d dirname($path);

    # Atomic write: tempfile + rename. If anything in the chain fails,
    # the original .secret keeps working - we never leave the file
    # empty or partial, which would lock everyone out without giving
    # them a way back in.
    my $tmp = "$path.tmp.$$";
    open my $wfh, '>', $tmp
        or return { ok => 0, error => "Cannot write $tmp: $!" };
    # 0660: identity-shared secret (see _preview_secret) - never world.
    chmod 0o660, $tmp;
    print $wfh "$new\n";
    close $wfh;
    unless ( rename $tmp, $path ) {
        my $err = $!;
        unlink $tmp;
        return { ok => 0, error => "Cannot replace $path: $err" };
    }
    chmod 0o660, $path;

    # Also clear the CSRF secret cache file (if dedicated one exists).
    # The CSRF helper falls back to .secret, so the new .secret
    # becomes the new CSRF secret too - but the sysop's next POST
    # will race with their about-to-expire session cookie, so bail
    # out cleanly by cycling them through /login.
    my $csrf_secret = "$LAZYSITE_DIR/manager/.csrf-secret";
    unlink $csrf_secret if -f $csrf_secret;

    log_event( 'WARN', $user,
        'auth secret rotated - all sessions invalidated' );

    return {
        ok      => 1,
        message => 'All sessions invalidated. You will need to sign in again.',
    };
}


# SM944 S33 (held branch (2), approved 2026-10-11): moved here unchanged from
# lazysite-manager-api.pl, the runner of the keys-list and key-revoke actions.
# SM145: a thin one-shot call into the users tool (--api) for reads/writes that
# this file gates itself (keys-list / key-revoke), bypassing action_users'
# GET-guard and actor-injection which are specific to the account CRUD path.
sub _users_tool_call {
    my ($payload) = @_;
    return _users_tool_run( $payload, "User management not available",
        "Cannot run user management: %s", "Invalid response" );
}

1;
