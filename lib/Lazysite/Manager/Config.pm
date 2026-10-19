package Lazysite::Manager::Config;

# The site configuration and the language set: reading the operator-visible
# subset of lazysite.conf (config-read), setting one allowlisted key through the
# one conf writer (config-set; Manager::Common::_write_conf_key, t/lint/25),
# the translation coverage of a language set (lang-status), and the language
# context whoami reports. Moved unchanged out of lazysite-manager-api.pl by
# SM944 S30.
#
# Index
#   _conf_text          lazysite.conf's text, raw, as Lazysite::Lang reads it
#   action_config_read  config-read: the settings the Config page shows
#   action_lang_status  lang-status: a language set's translation coverage
#   action_config_set   config-set: one allowlisted key, for an account
#   _language_context   whoami's language block (whoami reads it)
#
# The request context ($auth_user, $token_auth) is read from
# Lazysite::Manager::Common, which lazysite-manager-api.pl sets and nothing here
# assigns (t/lint/217). config-set is instance-wide: the dispatcher refuses it to
# a domain-confined caller before it runs (Lazysite::ControlApi::Actions,
# t/lint/218). Loaded where no request set the context, config-set refuses and
# writes nothing; the site facts answer (t/unit/manager/205). $DOCROOT and
# $LAZYSITE_DIR are set by the dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util              qw(log_event);
use Lazysite::Lang              qw(lang_status sole_group);
use Lazysite::Manager::Common   qw($auth_user $token_auth _user_caps _write_conf_key);
use Lazysite::Manager::Describe qw(_json_bool);
use Lazysite::Validate          ();
use Lazysite::Auth::Acl         ();

our @EXPORT_OK = qw(action_config_read action_config_set action_lang_status _language_context);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

# The lazysite.conf text, verbatim, as Lazysite::Lang wants it - the raw layer
# because the language helpers parse bytes and re-emit them unchanged.
sub _conf_text {
    my $conf = '';
    if ( open my $fh, '<:raw', "$LAZYSITE_DIR/lazysite.conf" ) {
        local $/;
        $conf = <$fh>;
        close $fh;
    }
    # SM917: an unreadable conf leaves $conf undef, which every reader below
    # treats as "no setting" - the same answer as a site that set nothing.
    else { Lazysite::Util::cannot_read( 'the site conf', "$LAZYSITE_DIR/lazysite.conf" ) }
    return $conf;
}

# SM122: a manage_config token may read a safe subset of the site config to
# self-diagnose (active layout/theme, whether WebDAV is on) instead of inferring
# from HTTP codes. No secrets - just the operator-visible site settings.
sub action_config_read {
    # SM042: the Config page loads via config-read (not the retired lazysite
    # pseudo-plugin), so this subset must surface EVERY key the page shows -
    # settable ones and the readonly_with_link ones (layout/theme/layouts_repo,
    # managed on Appearance). Kept in lock-step with config.md SITE_SCHEMA and
    # config-set's allow-list by t/lint/18-config-key-parity.t.
    my %out = map { $_ => '' }
        qw(site_name site_url layout theme layouts_repo nav_file webdav_enabled
        manager manager_path search_default update_channel canonical_ip
        asset_max_age manager_style backup_retention trusted_proxies
        manager_addresses manager_addresses_deny
        signin_addresses signin_addresses_deny
        app_name app_short_name app_scope app_start_url
        app_theme_colour app_background_colour
        app_icon_64 app_icon_192 app_icon_512 app_icon_maskable app_shell
        app_offline_pages app_update
        mcp_enabled oauth_enabled control_api_enabled token_exchange_enabled);
    if ( open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
        while ( my $line = <$fh> ) {
            next unless $line =~ /^(\w+)\s*:\s*(.*?)\s*$/;
            $out{$1} = $2 if exists $out{$1};
        }
        close $fh;
    }
    # SM917: %out keeps its declared defaults when the conf will not open, so the
    # manager would show the DEFAULTS as though they were the site's settings.
    else { Lazysite::Util::cannot_read( 'the site conf', "$LAZYSITE_DIR/lazysite.conf" ) }
    # SM1192: the address fields on the Config page show this when every visitor would
    # be the front proxy; decided here with the limiter's own address logic.
    require Lazysite::Auth::AddressLists;
    no warnings 'once';
    local $Lazysite::Auth::AddressLists::AUTH_DIR = "$LAZYSITE_DIR/auth";
    my $proxy = Lazysite::Auth::AddressLists::front_end_warning();
    return { ok => 1, config => \%out, ( defined $proxy ? ( proxy_warning => $proxy ) : () ) };
}

# SM179 P6: translation-coverage status for a language set. Read-only. `group`
# selects the set; when omitted, the base host's lang_group is used (the common
# single-set case). Returns the per-root missing/stale/current report from
# Lazysite::Lang, so an operator or a translation agent sees exactly what still
# needs doing without any bookkeeping of its own.
sub action_lang_status {
    my ($group) = @_;
    my $conf = _conf_text();
    if ( !defined $group || !length $group ) {
        $group = sole_group($conf);
    }
    if ( !length $group ) {
        return { ok => 0, error => 'no language group (set lang_group in the conf, or pass group=)' };
    }
    my $status = lang_status( docroot => $DOCROOT, conf_text => $conf, group => $group );
    return { ok => 1, %$status };
}

# SM1191: why an app_* value cannot be saved, or undef when it can. The rules are
# those of lazysite-processor/app.pm (_app_settings) and `lazysite check`
# (report_app_settings): app.pm loads nothing from Lazysite:: (ADR 0001), so the
# patterns are restated here and t/unit/manager/367 runs the same values through
# both so they cannot drift. Cross-key rules read the stored conf: a start page must
# sit inside the stored scope, and a scope must not strand the stored start page.
sub _app_setting_fault {
    my ( $key, $value ) = @_;
    ( my $v = $value ) =~ s/\A\s+|\s+\z//g;
    my $conf = _conf_text() // '';
    my $stored = sub { my ($k) = @_; my ($x) = $conf =~ /^\Q$k\E\s*:\s*(.*?)\s*$/m; return $x };
    my $in_scope = sub {
        my ( $start, $scope ) = @_;
        ( my $p = $start ) =~ s/\?.*\z//;
        return index( $p, $scope ) == 0 || "$p/" eq $scope;
    };

    if ( $key eq 'app_scope' ) {
        return "app_scope ($v) must start and end with / and name a directory, e.g. /portal/"
            unless $v =~ m{\A/(?:[A-Za-z0-9._~-]+/)*\z} && $v !~ m{(?:\A|/)\.\.?/};
        my $start = $stored->('app_start_url');
        return "app_scope ($v) would leave app_start_url ($start) outside it; change or clear app_start_url first"
            if defined $start && length $start && !$in_scope->( $start, $v );
        # SM1197: and the pages kept for offline, each of which must sit inside it.
        my $pages = $stored->('app_offline_pages');
        for my $pg ( grep { length } map { s/\A\s+|\s+\z//gr } split /,/, ( $pages // '' ) ) {
            return "app_scope ($v) would leave the offline page $pg outside it; change or clear app_offline_pages first"
                unless $in_scope->( $pg, $v );
        }
    }
    elsif ( $key eq 'app_start_url' ) {
        return "app_start_url ($v) must be a path starting with /, optionally with a ?query"
            unless $v =~ m{\A/[A-Za-z0-9._~/%-]*(?:\?[A-Za-z0-9._~%&=/-]*)?\z} && $v !~ m{(?:\A|/)\.\.(?:/|\z)};
        my $scope = $stored->('app_scope');
        $scope = '/' unless defined $scope && length $scope;
        return "app_start_url ($v) must be inside app_scope ($scope)"
            unless $in_scope->( $v, $scope );
    }
    elsif ( $key =~ /\Aapp_(?:theme|background)_colour\z/ ) {
        return "$key ($v) must be #rgb or #rrggbb" unless $v =~ /\A#(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})\z/;
    }
    elsif ( $key =~ /\Aapp_icon_(?:64|192|512|maskable)\z/ ) {
        return "$key ($v) must be a site path to a png, webp, svg or jpg"
            unless $v =~ m{\A/[A-Za-z0-9._~/-]+\.(?:png|webp|svg|jpe?g)\z}i && $v !~ m{\.\.};
        my $docroot = $DOCROOT // '';
        my $root    = $docroot;
        my $cr      = $stored->('content_root');
        $root = "$docroot/$cr"
            if defined $cr && length $cr && $cr =~ m{\A[A-Za-z0-9._/-]+\z} && $cr !~ m{\.\.} && -d "$docroot/$cr";
        return "$key ($v) is not a file this site serves; put the file there first"
            unless -f "$root$v" || -f "$docroot$v";
    }
    elsif ( $key eq 'app_update' ) {
        return "app_update ($v) must be now or wait" unless $v eq 'now' || $v eq 'wait';
    }
    elsif ( $key eq 'app_offline_pages' ) {
        my $scope = $stored->('app_scope');
        $scope = '/' unless defined $scope && length $scope;
        for my $pg ( grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $v ) {
            my $why = _app_offline_page_fault( $pg, $scope, $conf, $stored );
            return "app_offline_pages: $pg $why" if defined $why;
        }
    }
    elsif ( $key eq 'app_shell' ) {
        for my $p ( grep { length } map { s/\A\s+|\s+\z//gr } split /,/, $v ) {
            return "app_shell ($p) must be a site path starting with / and holding no .. or spaces"
                unless $p =~ m{\A/[A-Za-z0-9._~/%?&=-]*\z} && $p !~ m{\.\.} && $p !~ m{\A//};
        }
    }
    return undef;
}

# SM1197 (inbox 2026-10-19): WHY THIS PAGE MAY NOT BE KEPT ON A DEVICE FOR OFFLINE
# USE, or undef when it may. The worker keeps a listed page network-first and serves
# it with no signal, so a listed page must be the same for every visitor. This
# restates lazysite-processor/app.pm (_app_page_fault), which loads nothing from
# Lazysite:: (ADR 0001) and which DROPS what this refuses; t/unit/manager/368 runs
# the same pages through both. The sources of "not the same for everyone" are the
# ones the gate and the renderer use: the access keys (read by the validator's
# marked copy of the gate's reader), auth_default, the ACL store (read and address
# rules), and the front-matter bindings that make main mark a page per viewer
# (odoo-identity:, db:...(mine)). An `odoo:` binding is NOT one: a render runs only
# a binding that permits public and takes no visitor key and no Odoo session, so the
# page HTML is the same for everyone and the personal data comes from the Odoo
# endpoint at run time, which the worker never touches.
sub _app_offline_page_fault {
    my ( $p, $scope, $conf, $stored ) = @_;
    return 'is not a plain site path (a / path, no query, no ..)'
        unless $p =~ m{\A/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*\z} && $p !~ m{(?:\A|/)\.\.?(?:/|\z)};

    my $manager = $stored->('manager_path')  || '/manager';
    my $login   = $stored->('auth_redirect') || '/login';
    ( my $logout = $login ) =~ s{/login\b}{/logout};
    my %seen;
    for my $n ( grep { !$seen{$_}++ } ( '/cgi-bin/', '/lazysite/', $manager, $login, $logout ) ) {
        return 'is an endpoint, the manager, a sign-in path or the engine tree, which the app never keeps'
            if $p eq $n || index( $p, $n =~ m{/\z} ? $n : "$n/" ) == 0;
    }
    return 'is an endpoint, which the app never keeps' if $p =~ m{/lazysite-[a-z0-9-]+\.pl(?:/|\z)};
    # After the never-list, so an endpoint is named as one rather than as out of scope.
    return "is outside the app scope ($scope)" unless index( $p, $scope ) == 0 || "$p/" eq $scope;

    my $docroot = $DOCROOT // '';
    my $root    = $docroot;
    my $cr      = $stored->('content_root');
    $root = "$docroot/$cr"
        if defined $cr && length $cr && $cr =~ m{\A[A-Za-z0-9._/-]+\z} && $cr !~ m{\.\.} && -d "$docroot/$cr";
    ( my $base = $p ) =~ s{\A/}{};
    $base .= 'index' if $base eq '' || $base =~ m{/\z};
    my $file = "$root/$base.md";
    open my $fh, '<:utf8', $file or return 'is not a page this site has';
    my $text = do { local $/; <$fh> };
    close $fh;

    my ($fm) = Lazysite::Validate::split_front_matter( $text // '' );
    $fm = '' unless ( $text // '' ) =~ /\A\x{FEFF}?---/;
    my $ak = Lazysite::Validate::read_access_keys( $fm, 'content' );
    return 'has an access rule the engine cannot read, so the page is refused to everyone'
        if %{ $ak->{unreadable} };
    my $auth = $ak->{auth} || $stored->('auth_default') || 'none';
    return "needs sign-in (auth: $auth), so it is not the same for every visitor" if $auth ne 'none';
    return 'is limited to groups, so it is not the same for every visitor' if ref $ak->{auth_groups} eq 'ARRAY' && @{ $ak->{auth_groups} };
    return 'is a paid page, so it is not the same for every visitor' if ( $ak->{payment} // 'none' ) ne 'none';
    return 'is limited by address, so it is not the same for every visitor'
        if ( ref $ak->{addresses} eq 'ARRAY' && @{ $ak->{addresses} } ) || ( ref $ak->{addresses_deny} eq 'ARRAY' && @{ $ak->{addresses_deny} } );
    for my $line ( split /\r?\n/, $fm ) {
        return 'shows who the viewer is in Odoo (odoo-identity:), so it is different for each visitor' if $line =~ /\bodoo-identity:/;
        return 'binds the viewer\'s own rows (db:...(mine)), so it is different for each visitor'
            if $line =~ /\bdb:/i && $line =~ /\bmine\b/;
        return 'is rendered fresh for each request (nocache: true)' if $line =~ /^nocache\s*:\s*true/i;
        return 'is a data page (api: or raw: true), not a page' if $line =~ /^(?:api|raw)\s*:\s*true/i;
    }

    # The ACL store: a read list, an address list, or a draft section that governs the
    # page. A store that will not read refuses the page - the worker would keep an
    # answer the engine is refusing.
    ( my $rel = "$base.md" ) =~ s{\A/+}{};
    return 'is under an access rule whose store cannot be read' if Lazysite::Auth::Acl::gating_for( $docroot, $rel ) eq 'unknown';
    for my $mode (qw(read addresses addresses_deny)) {
        return 'is under an access rule (a read list or an address list), so it is not the same for every visitor'
            if defined Lazysite::Auth::Acl::governing_key( $docroot, $rel, $mode );
    }
    return undef;
}

# SM072 §13 / control API: set an allowlisted site-config key in
# lazysite.conf. The allowlist is deliberately narrow - benign display /
# behaviour keys only, NEVER privilege-relevant keys (manager_groups,
# plugins, auth_default) or ones with dedicated actions (layout/theme via
# theme-activate/layout-activate). Gated on manage_config by %need.
# (Defined inside the sub: the dispatch runs above this point in the file,
# so a file-level `my` initialised here would still be empty at call time.)
sub action_config_set {
    my ( $key, $value ) = @_;
    # SM944 S30, the established fail-closed pattern (ruled 2026-10-09/10): THE
    # SITE CONF IS WRITTEN FOR AN ACCOUNT. Inside a request the dispatcher has
    # refused an empty $auth_user (and required `manage_config`) before this
    # runs, so it is never empty here; reached outside one (the request
    # context's reset leaves nobody) it wrote site_name into lazysite.conf with
    # nobody asking (tmp/sm944-s29-s30-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'The site configuration is set by a signed-in account, and no account is asking.' }
        unless length $auth_user;
    # SM122: a small, injection-safe subset settable via the API (with manage_config).
    #
    # SM612: `manager` and `manager_path` are settable HERE but not by a TOKEN
    # client - see the channel check below. The reason is narrower than "they
    # are dangerous".
    #
    # Capabilities can be revoked in ONE place: the manager UI, over a cookie
    # session. The `users` action is refused to token clients outright, so no
    # API or MCP call writes a group's capabilities. That makes the manager the
    # recovery surface for every other mistake a sysop can make with a
    # grant.
    #
    # So a token grant holding manage_config could switch off - or relocate -
    # the only surface on which its own manage_config could be taken away.
    # That is not an escalation: the account was trusted with the capability.
    # It is a LOSS OF CONTROL, and the thing being switched off is the
    # sysop's ability to correct the decision. Recovery was editing
    # lazysite.conf on the host.
    #
    # THE TRANSPORT SWITCHES STAY, deliberately, and the difference is
    # recoverability. Disabling webdav, mcp, the control API or token exchange
    # is instance-wide and unpleasant, and the manager UI survives it - so an
    # operator can undo it from inside the product. Disabling the manager is
    # the one that removes the undo.
    # SM633: the five that turn a SURFACE on or off, as opposed to the ones that
    # change what the site looks like or is called. Named once, here, and read
    # by the capability check below - a second list would be the way the two
    # halves of this rule start disagreeing.
    my %SERVICE_KEY = map { $_ => 1 }
        qw(webdav_enabled mcp_enabled oauth_enabled control_api_enabled
        token_exchange_enabled);

    my %allow = map { $_ => 1 }
        qw(site_name site_url search_default webdav_enabled layout theme nav_file
        update_channel canonical_ip manager manager_path asset_max_age
        manager_style backup_retention trusted_proxies
        manager_addresses manager_addresses_deny
        signin_addresses signin_addresses_deny
        app_name app_short_name app_scope app_start_url
        app_theme_colour app_background_colour
        app_icon_64 app_icon_192 app_icon_512 app_icon_maskable app_shell
        app_offline_pages app_update
        mcp_enabled oauth_enabled control_api_enabled token_exchange_enabled);

    # SM612: settable, but NOT BY A TOKEN CLIENT. The operator toggles the
    # manager on its own Config page over a cookie session; a partner grant
    # holding manage_config may not.
    # SM1140: manager_addresses[_deny] limit who may reach the manager at all, so they
    # are the same kind of decision and are set the same way: a token that could narrow
    # the manager to nobody could not be undone from the manager.
    my %cookie_only_key = ( manager => 1, manager_path => 1, manager_addresses => 1, manager_addresses_deny => 1,
        signin_addresses => 1, signin_addresses_deny => 1 );

    # SM698: a manager style must be one the engine ships. The renderer already
    # falls back to `classic` for anything else, so an unknown value here is
    # inert rather than dangerous - but storing it would leave the Config page
    # showing a style the manager is not wearing, and an operator comparing the
    # two would be right to think something was broken. Refuse at the boundary
    # instead, naming what is available.
    if ( $key eq 'manager_style' && length($value) ) {
        my %shipped = map { $_ => 1 } qw(classic accessible modern);
        unless ( $shipped{ lc $value } ) {
            return { ok => 0, kind => 'invalid',
                error => "Unknown manager style '$value'. The styles this "
                    . 'release ships are: classic, accessible, modern.' };
        }
        $value = lc $value;
    }
    if ( $token_auth && $cookie_only_key{ $key // '' } ) {
        return { ok => 0, kind => 'forbidden', field => $key,
            error => "Config key '$key' is set only from the manager UI over a "
                . 'cookie session. It decides whether that UI exists, and the '
                . 'manager is the only surface on which a capability can be '
                . 'revoked - so a token client that could switch it off could '
                . 'not be switched off again.' };
    }
    # SM782: a MISSING key is named as missing. "Config key '' is not
    # settable" sent the field to the permitted-keys list for a key it never
    # sent (it had sent {backup_retention: 3} - the field as the key).
    return { ok => 0, error => 'key is required (send {"key": "<name>", "value": "<value>"} in the JSON body)' }
        unless defined $key && length $key;
    return { ok => 0, error => "Config key '$key' is not settable via the API" }
        unless $allow{$key};

    # SM633: THE SERVICE SWITCHES ARE A DIFFERENT GRANT.
    #
    # These five decide whether the remote surfaces answer AT ALL - for
    # everyone, including partners already connected. They sat under a
    # capability whose own title says "safe site configuration", beside the
    # site's name and its cache lifetime. Those are not the same size of
    # decision, and one name covered both.
    #
    # Checked HERE rather than in the %need table because %need gates the
    # ACTION and this is a rule about one of its KEYS - the same shape as the
    # SM612 channel check immediately above, and for the same reason: config-set
    # is one door onto settings that are not all alike.
    if ( $SERVICE_KEY{$key} && !_user_caps($auth_user)->{manage_services} ) {
        return { ok => 0, kind => 'forbidden',
            error => "Setting '$key' needs the 'Services' capability "
                . "(manage_services), which decides whether the remote surfaces "
                . "answer at all. 'manage_config' covers ordinary site settings "
                . "and no longer covers these." };
    }
    # 0.9.0 service killswitches + the manager toggle: enabled/disabled, same
    # shape as webdav_enabled (SM042: the whole site-settings page now saves via
    # config-set, not the lazysite pseudo-plugin, so config-set owns their rules).
    if ( $key =~ /^(?:mcp|oauth|control_api|token_exchange)_enabled$/
        && defined $value && $value !~ /^(?:enabled|disabled)$/ )
    {
        return { ok => 0, error => "$key must be 'enabled' or 'disabled'" };
    }
    if ( $key eq 'manager' && defined $value && $value !~ /^(?:enabled|disabled)$/ ) {
        return { ok => 0, error => "manager must be 'enabled' or 'disabled'" };
    }
    if ( $key eq 'manager_path' && defined $value && length $value
        && $value !~ m{^/[A-Za-z0-9_./-]*$} )
    {
        return { ok => 0, error => 'manager_path must be an absolute URL path (e.g. /manager)' };
    }
    # SM1140 (slice C of SM1134): the manager's address limit is a comma list of address
    # list NAMES (SM1138) and each must exist, in the right slot: a name no list carries
    # admits nobody under manager_addresses, which would lock the manager (and its
    # operator) out, so a typo is refused here and not written.
    if ( ( $key =~ /\A(?:manager|signin)_addresses(?:_deny)?\z/ ) && defined $value && length $value ) {
        require Lazysite::Auth::AddressLists;
        no warnings "once";
        local $Lazysite::Auth::AddressLists::AUTH_DIR = "$LAZYSITE_DIR/auth";
        my $lists = Lazysite::Auth::AddressLists::lists();
        if ( my $fault = Lazysite::Auth::AddressLists::store_fault() ) {
            return { ok => 0, kind => 'cannot-tell',
                error => 'lazysite/auth/address-lists.json ' . ( $fault eq 'undecodable' ? 'does not decode' : 'could not be read' )
                    . ', so the lists this names cannot be checked.' };
        }
        my $kind = $key !~ /_deny\z/ ? 'allow' : 'deny';
        for my $n ( grep { length } map { s/^\s+|\s+$//gr } split /,/, $value ) {
            return { ok => 0, field => $key,
                error => "'$n' is not " . ( $kind eq 'allow' ? 'an allow' : 'a deny' ) . ' address list. Make it on Access, Address lists first.' }
                unless $lists->{$n} && $lists->{$n}{kind} eq $kind;
        }
        $value = join ', ', grep { length } map { s/^\s+|\s+$//gr } split /,/, $value;
    }
    # ...and a rule that would refuse the very request making it is refused too: the
    # manager is the only place it could be undone from.
    if ( $key =~ /\A(?:manager|signin)_addresses(?:_deny)?\z/ ) {
        require Lazysite::Auth::AddressScope;
        my $conf  = _conf_text() // '';
        my $other = ( $key =~ s/_deny\z//r ) . ( $key =~ /_deny\z/ ? "" : "_deny" );
        my ($ov)  = $conf =~ /^\Q$other\E\s*:\s*(.*?)\s*$/m;
        my @mine  = Lazysite::Auth::AddressScope::names($value);
        my @their = Lazysite::Auth::AddressScope::names($ov);
        my ( $allow, $deny ) = $key !~ /_deny\z/ ? ( \@mine, \@their ) : ( \@their, \@mine );
        return { ok => 0, field => $key,
            error => ( $key =~ /\Asignin/
                ? 'That would shut your own address out of signing in (SM1159): the next time you signed in from here it '
                    . 'would be refused. Add your address to an allow list first, or take it off the deny list.'
                : 'That would shut your own address out of the manager, and the manager is where it '
                    . 'would be undone. Add your address to an allow list first, or take it off the deny list.' ) }
            if Lazysite::Auth::AddressScope::would_refuse( $LAZYSITE_DIR, $allow, $deny );
    }
    # SM156: canonical_ip is a comma list of this server's PUBLIC IPs (for the
    # domain-check "points here" check behind a proxy/NAT). Validate as IPv4/IPv6
    # literals, comma-separated - no hostnames, no shell/markup metacharacters.
    if ( $key eq 'canonical_ip' && defined $value && length $value ) {
        for my $ip ( split /\s*,\s*/, $value ) {
            return { ok => 0, error => 'canonical_ip must be comma-separated IP addresses' }
                unless $ip =~ /^[0-9.]+$/ || $ip =~ /^[0-9A-Fa-f:]+$/;
        }
    }
    # SM122: validate the enum/name-shaped keys.
    # SM416: seconds, bounded; 0 (or empty) restores the revalidation default.
    if ( $key eq 'asset_max_age' && defined $value && length $value
        && $value !~ /^\d{1,9}$/ ) {
        return { ok => 0, error => 'asset_max_age must be a number of seconds (0 disables)' };
    }
    # SM753: backups kept per kind; 0 keeps every one.
    if ( $key eq 'backup_retention' && defined $value && length $value && $value !~ /^\d{1,4}$/ ) {
        return { ok => 0, error => 'backup_retention must be a whole number of backups to keep (0 keeps all)' };
    }
    if ( $key eq 'webdav_enabled' && defined $value && $value !~ /^(?:enabled|disabled)$/ ) {
        return { ok => 0, error => "webdav_enabled must be 'enabled' or 'disabled'" };
    }
    # Channel ladder: 'all' (the UI vocabulary) and 'edge' (the CLI's) are
    # synonyms - both mean "accept every release".
    if ( $key eq 'update_channel' && defined $value && $value !~ /^(?:all|edge|beta|stable)$/ ) {
        return { ok => 0, error => "update_channel must be 'all', 'beta' or 'stable'" };
    }
    if ( ( $key eq 'layout' || $key eq 'theme' ) && defined $value && length $value
        && $value !~ /^[A-Za-z0-9_-]+$/ ) {
        return { ok => 0, error => "$key must be a simple name" };
    }
    # Keys whose EMPTY means "the default" may be cleared: canonical_ip
    # (auto-detect), asset_max_age (SM416: the revalidation default) and
    # backup_retention (SM753: 3). SM782: the field ships empty and meant the
    # default, and "A value is required" made the shipped state unreachable
    # through the API. Every other key needs a value.
    my %clearable = map { $_ => 1 } qw(canonical_ip asset_max_age backup_retention
        manager_addresses manager_addresses_deny signin_addresses signin_addresses_deny
        app_name app_short_name app_scope app_start_url app_theme_colour app_background_colour
        app_icon_64 app_icon_192 app_icon_512 app_icon_maskable app_shell
        app_offline_pages app_update);
    return { ok => 0,
        error => "A value is required: '$key' has no default to fall back to, so it "
            . 'cannot be cleared (the keys that can are '
            . join( ', ', sort keys %clearable ) . ')' }
        unless ( defined $value && length $value ) || $clearable{$key};
    $value = '' unless defined $value;
    return { ok => 0, error => "Value must be a single line" }
        if $value =~ /[\r\n]/;
    # SM1191 (test plan 0.15.10 F-5): the app_* keys SM1155 reads. The engine turns the
    # app OFF on a value it cannot honour and says nothing while serving, so the save
    # refuses what the engine would refuse, naming the key.
    if ( $key =~ /\Aapp_/ && length $value ) {
        my $fault = _app_setting_fault( $key, $value );
        return { ok => 0, kind => 'invalid', field => $key, error => $fault } if defined $fault;
        $value =~ s/\A\s+|\s+\z//g;
    }
    my ( $wok, $werr ) = _write_conf_key( $key, $value );
    return { ok => 0,
        error => 'Could not write lazysite.conf' . ( defined $werr ? ": $werr" : '' ) }
        unless $wok;
    log_event( 'INFO', 'config-set', 'config key set', key => $key, user => $auth_user );
    # SM255: the commit is no longer made here. lazysite.conf has ONE write path
    # and it records the change itself, so every writer - config-set, the domain
    # verbs, the CLI - produces the same history entry. A caller committing its
    # own write is how the two surfaces diverged in the first place.
    return { ok => 1, key => $key, value => $value };
}

# SM179 P7: the language context for a partner's whoami. Returns { language =>
# { lang, lang_group, siblings => [ { host, lang, content_root, source } ] } }
# when this instance has a language set, else undef (the block is omitted). The
# partner's `lang` is that of their bound home_domain (else the source). `source`
# marks the source-of-truth root a translation agent copies FROM.
sub _language_context {
    my ($s)   = @_;
    my $conf  = _conf_text();
    my $group = sole_group($conf);
    return undef unless length $group;
    my @members = Lazysite::Lang::set_members( $conf, $group );
    return undef unless @members;

    my $home = $s->{home_domain} // '';
    my ($me) = grep { $_->{host} eq $home } @members;
    ($me) = grep { $_->{source} } @members unless $me;

    return {
        language => {
            lang       => ( $me ? $me->{lang} : '' ),
            lang_group => $group,
            siblings   => [
                map {
                    { host => $_->{host},
                        lang         => $_->{lang},
                        content_root => $_->{content_root},
                        source       => _json_bool( $_->{source} ),
                    }
                } @members
            ],
        },
    };
}

1;
