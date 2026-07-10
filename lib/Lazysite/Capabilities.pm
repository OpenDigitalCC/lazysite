package Lazysite::Capabilities;

# SM126: the machine-parseable capability map. One builder, consulted by the
# MCP `describe_capabilities` tool and the control-API `describe-capabilities`
# action (and, later, a static generated doc), so a connecting agent can learn
# up front what it may do and how - instead of discovering by trial and error.
#
# The channel/action split derives from @CAP_KEYS (the single source of truth in
# Auth::Settings), so a new capability appears here automatically. The per-action
# "unlocks" and the task recipes are curated here; t/unit/lib/05-capabilities.t
# cross-checks them against the live control-API %need and MCP %TOOLS maps so
# they cannot silently drift.

use strict;
use warnings;
use JSON::PP ();
use Lazysite::Auth::Settings qw(@CAP_KEYS);
use Exporter 'import';
our @EXPORT_OK = qw(describe capability_keys channel_keys action_keys);

# The four channels (WHERE you operate). Fixed concept; the rest of @CAP_KEYS are
# actions (WHAT you may do).
my @CHANNELS = qw(ui webdav api mcp);
my %IS_CHANNEL = map { $_ => 1 } @CHANNELS;

sub channel_keys    { return @CHANNELS }
sub action_keys     { return grep { !$IS_CHANNEL{$_} } @CAP_KEYS }
sub capability_keys { return @CAP_KEYS }

# Channel descriptions. All four are enforced at the transport (SM126): ui at
# login, webdav by webdav_enabled_for, api on the control-API token path, mcp on
# the MCP tools/call dispatch.
my %CHANNEL_INFO = (
    ui     => 'Interactive manager UI over a browser cookie session.',
    webdav => 'The /dav publishing endpoint (files, themes, layouts).',
    api    => 'The token-authenticated control API (structured actions).',
    mcp    => 'The MCP connector (Claude.ai / ChatGPT / Code tools).',
);

# Action capabilities: a title and what holding it unlocks, per channel. The
# lists name real MCP tools, control-API actions, or WebDAV path shapes; the
# consistency test keeps the tool/action names honest against the live maps.
my %ACTION_INFO = (
    manage_content => {
        title   => 'Read and write site content (pages, assets).',
        unlocks => {
            api => [qw(aliases-list git-status git-history git-show git-restore)],
            mcp    => [qw(list_files read_file write_file replace_text copy_file
                          move_file delete_file create_page delete_page rename_page
                          list_pages read_page preview_page page_status search_files
                          validate_page invalidate_cache read_nav audit_site
                          get_permissions set_permissions)],
            webdav => ['write anywhere in the content namespace (within dav_scope)'],
        },
    },
    manage_nav => {
        title   => 'Edit site navigation.',
        unlocks => {
            api    => [qw(nav-read nav-save pages)],
            mcp    => [qw(set_nav)],
            webdav => ['lazysite/nav.conf'],
        },
    },
    manage_forms => {
        title   => 'Wire forms to delivery handlers.',
        unlocks => {
            mcp    => [qw(list_form_handlers bind_form)],
            webdav => ['lazysite/forms/<name>.conf (not smtp.conf / handlers.conf)'],
        },
    },
    manage_themes => {
        title   => 'Install and activate themes.',
        unlocks => {
            api    => [qw(theme-activate theme-list themes-for-layout themes-list-all)],
            mcp    => [qw(list_themes activate_theme)],
            webdav => ['lazysite/layouts/<layout>/themes/<theme>/ (active theme read-only)'],
        },
    },
    manage_layouts => {
        title   => 'Install, author and activate layouts.',
        unlocks => {
            api    => [qw(layout-activate layout-install layout-delete layouts-available layouts-manifest)],
            mcp    => [qw(activate_layout install_layout delete_layout list_layout_catalogue)],
            webdav => ['lazysite/layouts/<layout>/ (active layout read-only)'],
        },
    },
    manage_config => {
        title   => 'Read and set safe site configuration.',
        unlocks => {
            api    => [qw(config-read config-set git-init)],
            webdav => ['lazysite/nav.conf', 'lazysite/forms/<name>.conf'],
        },
    },
    manage_users => {
        title   => 'Manage user accounts and group membership.',
        unlocks => { ui => ['the manager Users and Groups pages'] },
    },
    analytics => {
        title   => 'Read sanitised, IP-anonymised visitor analytics.',
        unlocks => { api => [qw(analyse_visitors)], mcp => [qw(analyse_visitors)] },
    },
    audit => {
        title   => 'Read the append-only audit trail.',
        unlocks => { api => [qw(audit)] },
    },
    notifications => {
        title => 'See operator notifications (the manager bell: new form submissions, requests awaiting a response).',
        unlocks => { ui => ['the notifications bell + unread badge in the manager header'] },
    },
    create_sub_users => {
        title   => 'Create sub-accounts under your own account.',
        unlocks => { ui => ['sub-user creation'] },
    },
    delegate_sub_user_creation => {
        title   => 'Grant sub-accounts the ability to create their own sub-users.',
        unlocks => { ui => ['onward delegation of sub-user creation'] },
    },
);

# Engine-owned paths: protected surface an agent must NOT try to write (the DAV
# blocklist / whole-lazysite denial already enforce this - this list makes the
# boundary legible so an agent uses the API instead of hunting for a workaround).
my @ENGINE_OWNED = (
    'lazysite/auth/**  (credentials, tokens, TOTP seeds, HMAC secret)',
    'lazysite/cache/** (generated HTML cache)',
    'lazysite/forms/smtp.conf, lazysite/forms/handlers.conf (delivery secrets)',
    'lazysite/manager/** (manager UI internals)',
    'cgi-bin/**, *.pl   (the engine scripts)',
);

# Task recipes: the sanctioned sequence for common jobs, machine-readable so an
# agent can plan without prose. The human quickstarts (Phase B) are the twins.
my @TASKS = (
    {   id => 'install-theme', title => 'Install and activate a theme',
        requires => ['manage_themes'],
        steps => [
            'PUT the theme files under lazysite/layouts/<layout>/themes/<name>/ over WebDAV (or use the MCP write_file tool on those paths)',
            'call activate_theme (MCP) or POST action=theme-activate (control API)',
        ],
    },
    {   id => 'author-layout', title => 'Author and activate a layout',
        requires => ['manage_layouts'],
        steps => [
            'PUT layout files (view.tt, components) under lazysite/layouts/<name>/ over WebDAV',
            'call activate_layout (MCP) or POST action=layout-activate (control API)',
        ],
    },
    {   id => 'publish-page', title => 'Publish a page',
        requires => ['manage_content'],
        steps => [
            'create the page with the MCP create_page tool, or PUT the .md over WebDAV in the content namespace',
            'optionally preview_page (MCP) to confirm the render before it goes live',
        ],
    },
    {   id => 'wire-form', title => 'Wire a form to a handler',
        requires => ['manage_forms'],
        steps => [
            'call bind_form (MCP), or PUT lazysite/forms/<name>.conf over WebDAV, naming an operator-defined handler',
        ],
    },
);

# Build the map. Pass caps => { cap => 0|1 } (the caller's resolved grant) and,
# optionally, groups => [...] and account => "name" to include the "holds" block;
# omit caps for the static model only (e.g. the generated doc).
sub describe {
    my (%opt) = @_;
    my $T = JSON::PP::true();
    my $F = JSON::PP::false();

    my %channels;
    $channels{$_} = { enforced => $T, note => $CHANNEL_INFO{$_} } for @CHANNELS;

    my %capabilities;
    for my $a ( action_keys() ) {
        my $info = $ACTION_INFO{$a} || { title => $a, unlocks => {} };
        $capabilities{$a} = { title => $info->{title}, unlocks => $info->{unlocks} };
    }

    my %map = (
        channels     => \%channels,
        capabilities => \%capabilities,
        tasks        => \@TASKS,
        engine_owned => \@ENGINE_OWNED,
    );

    if ( $opt{caps} ) {
        my $caps = $opt{caps};
        $map{holds} = {
            ( defined $opt{account} ? ( account => $opt{account} ) : () ),
            ( $opt{groups} ? ( groups => $opt{groups} ) : () ),
            capabilities => { map { $_ => ( $caps->{$_} ? $T : $F ) } @CAP_KEYS },
        };
    }

    return \%map;
}

1;
