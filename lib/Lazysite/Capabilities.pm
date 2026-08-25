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
use JSON::PP                 ();
use Lazysite::Util           ();
use Lazysite::Auth::Settings qw(@CAP_KEYS);
use Exporter 'import';
our @EXPORT_OK = qw(describe capability_keys reachability reach_for channel_keys action_keys channel_service action_channel_surface);

# The four channels (WHERE you operate). Fixed concept; the rest of @CAP_KEYS are
# actions (WHAT you may do).
my @CHANNELS   = qw(ui webdav api mcp);
my %IS_CHANNEL = map { $_ => 1 } @CHANNELS;

sub channel_keys    { return @CHANNELS }
sub action_keys     { return grep { !$IS_CHANNEL{$_} } @CAP_KEYS }
sub capability_keys { return @CAP_KEYS }

# Channel descriptions. All four are enforced at the transport (SM126): ui at
# login, webdav by webdav_enabled_for, api on the control-API token path, mcp on
# the MCP tools/call dispatch.
my %CHANNEL_INFO = (
    ui => 'Interactive manager UI over a browser cookie session.',
    webdav => 'The /dav publishing endpoint (files, themes, layouts). Also gates the per-file ACL actions on the control API (acl-get / acl-set / acl-remove) - alongside manage_content since SM431, because a capability that lets you CREATE gated content must let you inspect and set the rule governing it, on the same surface.',
    api =>
        'The token-authenticated control API (structured actions). Call '
        . '`action=actions-list` for the actions THIS account may use, with '
        . 'the parameters each takes and where each is read from - the '
        . "control API's equivalent of MCP's tools/list (SM350). This map "
        . 'says what you may do; that says what you may call.',
    mcp => 'The MCP connector (Claude.ai / ChatGPT / Code tools).',
);

# SM180: each CHANNEL capability only DOES anything while its site service is
# enabled - the two planes (per-principal grant, per-site killswitch) are
# independent, so a grant can be dormant. This is the map from a channel to the
# lazysite.conf key that gates it: 'ui' by the `manager` key, the three remote
# channels by their *_enabled flags. The manager consults it to flag a
# granted-but-dormant capability (service off) in the Groups/Users grids. Single
# source of truth: surfaced in describe() and read by the control API.
my %CHANNEL_SERVICE = (
    ui     => 'manager',
    webdav => 'webdav_enabled',
    api    => 'control_api_enabled',
    mcp    => 'mcp_enabled',
);
sub channel_service { return {%CHANNEL_SERVICE} }

# Action capabilities: a title and what holding it unlocks, per channel. The
# lists name real MCP tools, control-API actions, or WebDAV path shapes; the
# consistency test keeps the tool/action names honest against the live maps.
my %ACTION_INFO = (
    manage_content => {
        title   => 'Read and write site content (pages, assets).',
        unlocks => {
            api => [ qw(aliases-list git-status git-history git-history-summary
                    git-show git-restore lang-status site-export-primary
                    regenerate-registries preview-public
                    acl-get acl-set acl-remove
                    brief-read brief-append briefs-migrate
                    briefs-list brief-delete
                    nav-read pages) ],
            mcp => [ qw(list_files read_file write_file upload_file replace_text copy_file
                    move_file delete_file create_page delete_page rename_page
                    list_pages read_page preview_page page_status search_files
                    validate_page invalidate_cache regenerate_registries read_nav audit_site create_form
                    get_permissions set_permissions read_brief append_brief
                    list_briefs delete_brief
                    list_versions list_content_history view_version restore_version preview_public_page)
            ],
            webdav => ['write anywhere in the content namespace (within dav_scope)'],
        },
    },
    manage_nav => {
        title => 'Edit site navigation.',
        # SM568: nav-read and pages are reads a content author needs as much
        # as a nav editor, so manage_content admits them too (the MCP twins
        # read_nav and list_pages sit under manage_content). Listed under
        # both, as form-submissions is under manage_forms and read_submissions.
        unlocks => {
            api    => [qw(nav-read nav-save pages)],
            mcp    => [qw(set_nav)],
            webdav => ['lazysite/nav.conf'],
        },
    },
    manage_forms => {
        title => 'Wire forms to delivery handlers. A submitted form also raises an '
            . 'operator notification of its own accord (the manager bell, plus chat '
            . 'where notify-xmpp is configured) naming the form and the time but '
            . 'never the content - so nothing needs to poll to learn that something '
            . 'arrived. See /docs/forms.',
        # SM457: the API list was MISSING, and its absence sent a real
        # operator's agent guessing.
        #
        # form-submissions is gated on [manage_forms, read_submissions] -
        # either capability admits it. read_submissions advertises it
        # correctly; this one advertised no api key at all, so a partner
        # holding manage_forms was told about MCP tools and a WebDAV path and
        # nothing about the control API, while enforcement let them straight
        # in. They tried describe_capabilities, list_form_handlers, forms,
        # form_submissions, list_submissions and submissions - six names, none
        # of them real, four of them snake_case guesses at a kebab-case
        # surface and two of them MCP tool names aimed at the API.
        #
        # SM435 was this defect pointed the other way: the descriptor CLAIMED
        # a path enforcement refused. Under-claiming is the quieter failure -
        # nothing 403s, nothing errors, the agent simply cannot find a door it
        # is holding the key to.
        unlocks => {
            api    => [qw(form-submissions form-list)],
            mcp    => [qw(list_form_handlers bind_form)],
            webdav => ['lazysite/forms/<name>.conf (not smtp.conf / handlers.conf)'],
        },
    },
    manage_themes => {
        title   => 'Install and activate themes.',
        unlocks => {
            # SM457: these are gated on [manage_themes, manage_layouts] -
            # EITHER admits - so both must name them. A partner holding only
            # one was admitted and never told.
            api => [ qw(theme-activate theme-list themes-for-layout themes-list-all
                    artifact-manifest artifact-validate preview-grant theme-delete
                    artifact-backups-delete layouts-available layouts-manifest) ],
            mcp => [qw(list_themes theme_tokens activate_theme create_theme delete_theme)],
            webdav => ['lazysite/layouts/<layout>/themes/<theme>/ (active theme read-only)'],
        },
    },
    manage_layouts => {
        title   => 'Install, author and activate layouts.',
        unlocks => {
            # SM457: as above - cross-gated actions belong on both lists.
            api => [ qw(layout-activate layout-install layout-delete layouts-available
                    layouts-manifest artifact-backups-delete
                    artifact-manifest artifact-validate preview-grant
                    theme-list themes-for-layout themes-list-all) ],
            mcp => [qw(activate_layout install_layout delete_layout list_layout_catalogue)],
            webdav => ['lazysite/layouts/<layout>/ (active layout read-only)'],
        },
    },
    manage_domains => {
        title   => 'Manage the domains this instance serves, and portable site packages.',
        unlocks => {
            api => [ qw(domains-list domain-add domain-set domain-remove
                    domain-preview domain-check
                    site-backup-create site-backup-download site-backup-upload
                    site-backup-apply site-backup-delete site-backup-inspect) ],
            mcp => [qw(list_domains domain_set preview_domain site_backup site_apply)],
        },
    },
    # SM447 / ADR 0009. DECLARED BY plugins/data.pl and mirrored here; the
    # plugin is the owner and t/lint/76 refuses a mirror with no plugin
    # claiming it, or one claimed twice.
    #
    # THE UNLOCK LISTS ARE EMPTY AND THAT IS ACCURATE. The typed core is built
    # and nothing routes to it yet: no control-API action and no MCP tool is
    # gated on this capability. Granting it today therefore admits an account
    # to nothing, which is honest - what it must never do is CLAIM actions that
    # do not exist, which is SM457's defect pointed the other way and the one
    # t/lint/71 exists to catch.
    manage_data => {
        title   => 'Read and write the site\'s data tables.',
        unlocks => {
            api => [
                qw(data-tables data-table data-table-save data-rows
                    data-migrate data-rebuild data-row-save data-row-delete
                    data-export data-import data-table-source data-migrate-plan
                    data-table-drop data-safety-exports data-safety-export-delete
                    data-safety-export-read data-safety-export-restore)
            ],

            mcp => [
                qw(list_data_tables describe_data_table save_data_table
                    read_data_rows migrate_data_table rebuild_data_table
                    save_data_row delete_data_row drop_data_table
                    list_data_safety_exports delete_data_safety_export
                    read_data_safety_export restore_data_safety_export
                    read_data_table_source plan_data_migration)
            ],
            # NO WEBDAV ENTRY, and this used to claim one. WebDAV allows
            # only lazysite/layouts/ - "the rest of lazysite/ is protected" -
            # so `lazysite/db/tables/<table>.yaml` was a path this capability
            # advertised and the front door refused. That is SM435's defect
            # exactly, and t/lint/68 exists for it on this plane. Descriptors
            # are written through data-table-save / save_data_table, which
            # validate before storing.
        },
    },
    manage_config => {
        title => 'Read and set safe site configuration.',
        # SM435: this listed lazysite/nav.conf and lazysite/forms/<name>.conf
        # over WebDAV, which 0.8.1 moved to manage_nav and manage_forms
        # respectively - see authorise() in lazysite-dav.pl, which admits
        # neither of them under this capability. Both new entries were written
        # and this one was never trimmed, so the descriptor promised a partner
        # holding manage_config alone a write it would be refused. Nothing was
        # over-permitted; enforcement was always the strict side. The cost was
        # that the descriptor is the ONE per-capability account of the boundary
        # readable from outside the code, so being wrong sent an agent to a 403
        # and then to trial and error - which is what RI-002's deny reasons
        # exist to end. t/lint/68 now checks the two against each other.
        unlocks => {
            api => [qw(config-read config-set git-init bad-url-blocks bad-url-unblock)],
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
        # SM281 item 3: it unlocked a manager page and nothing else - a
        # capability with no remote surface, which is an SM239 parity gap and
        # the reason remote agents had been editing a shared briefing document
        # to talk to each other. `notices` is READ; emission stays SM231's.
        unlocks => {
            ui  => ['the notifications bell + unread badge in the manager header'],
            api => ['notices'],
        },
    },
    feedback => {
        title => 'Submit agent feedback over MCP. Off by default: the operator opts a group in so an agent may write to lazysite/feedback/ and notify the operator.',
        unlocks => { mcp => [qw(submit_feedback)] },
    },
    read_submissions => {
        title => 'Read form submissions over the API/MCP. A least-privilege, read-only grant for an agent that processes form leads - it does NOT include managing form configs (that is manage_forms). Off by default.',
        unlocks => { api => [qw(form-submissions form-list)], mcp => [qw(read_form_submissions form_list)] },
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

# SM197: the per-action channel SURFACE - which channels a capability actually
# exposes something on, derived from the keys of its `unlocks` map. The manager's
# permission grid consults this so a capability x channel cell is ticked only
# where the capability has a REAL surface on that channel (e.g. manage_domains on
# api+mcp, not webdav), rather than merely "granted AND channel held". Same single
# source of truth as describe(); a new capability's surface appears automatically.
sub action_channel_surface {
    my %surface;
    for my $cap ( action_keys() ) {
        my $u = $ACTION_INFO{$cap}{unlocks} || {};
        $surface{$cap} = { map { $_ => 1 } grep { @{ $u->{$_} || [] } } keys %{$u} };
    }
    return \%surface;
}

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
    { id => 'install-theme', title => 'Install and activate a theme',
        requires => ['manage_themes'],
        steps    => [
            'PUT the theme files under lazysite/layouts/<layout>/themes/<name>/ over WebDAV (or use the MCP write_file tool on those paths)',
            'call activate_theme (MCP) or POST action=theme-activate (control API)',
        ],
    },
    { id => 'author-layout', title => 'Author and activate a layout',
        requires => ['manage_layouts'],
        steps    => [
            'PUT layout files (view.tt, components) under lazysite/layouts/<name>/ over WebDAV',
            'call activate_layout (MCP) or POST action=layout-activate (control API)',
        ],
    },
    { id => 'switch-layout', title => 'Switch the site to a different layout',
        requires => ['manage_layouts'],
        steps    => [
            'call list_layout_catalogue (MCP) or GET action=layouts-manifest (control API) to see what is available and installed',
            # SM348: this said "it installs AND activates the new layout in one
            # step". SM314 corrected the TOOL to say installing does not
            # activate, and left this - so the document an agent reads FIRST
            # contradicted the tool it was describing, and an agent following
            # this sequence would install a layout, believe the site had
            # switched, and find it unchanged.
            #
            # Two steps now, because it is two operations. SM176's reasoning
            # holds: activating is the part that changes what visitors see, so
            # it is always asked for explicitly.
            'call install_layout (MCP) or POST action=layout-install (control API) - this places the layout on the site and changes NOTHING a visitor sees',
            'call activate_layout (MCP) or POST action=layout-activate (control API) - this is the step that switches the live site. The response says whether the layout renders the site navigation and page body (SM337); a layout that renders no [% nav %] is activated anyway and warns, because a showcase layout is a legitimate choice',
            'ONLY THEN, if the old layout is no longer wanted: delete_layout / layout-delete. Deleting the ACTIVE layout is always refused - install/activate the replacement first, never delete first',
        ],
    },
    { id => 'restore-from-history', title => 'Undo a content change (restore a recorded version)',
        requires => ['manage_content'],
        steps    => [
            'call list_versions (MCP) or GET action=git-history (control API) for the file - needs the site\'s Content history plugin enabled',
            'call view_version / git-show to confirm the version (content + diff against the current file)',
            'call restore_version / git-restore - the historic content is saved back through the normal save path and the restore itself becomes the newest version, so nothing is lost',
        ],
    },
    { id => 'publish-page', title => 'Publish a page',
        requires => ['manage_content'],
        steps    => [
            'create the page with the MCP create_page tool, or PUT the .md over WebDAV in the content namespace',
            'optionally preview_page (MCP) to confirm the render before it goes live',
        ],
    },
    { id => 'build-from-figma', title => 'Build or restyle a site from a Figma design',
        requires => [ 'manage_themes', 'manage_layouts', 'manage_content' ],
        steps => [ 'Read /docs/integrations/figma for the extraction + translation sequence',
            'Connect the Figma MCP server alongside the lazysite connection; run whoami on both',
            'Extract tokens/structure/screenshots via the Figma MCP (get_metadata, get_variable_defs, get_screenshot)',
            'Map design tokens onto the layout vocabulary (theme_tokens) and rebuild rhythm/scale in CSS',
            'Adapt the nearest layout (copy-and-stage) or scaffold a theme (create_theme)',
            'Verify with preview_page before activating' ] },
    { id => 'wire-form', title => 'Wire a form to a handler',
        requires => ['manage_forms'],
        steps    => [
            'call bind_form (MCP), or PUT lazysite/forms/<name>.conf over WebDAV, naming an operator-defined handler',
        ],
    },
    { id => 'migrate-site', title => 'Migrate a site (package one domain and apply it elsewhere)',
        requires => ['manage_domains'],
        steps    => [
            'ON THE SOURCE: call site_backup (MCP) or POST action=site-backup-create (control API) with the domain host - this writes a portable package (lazysite-site-<host>-<stamp>.tar.gz) holding that domain\'s content + nav + its theme/layout + a manifest. It excludes plugins, instance settings and secrets, so it is safe to hand over',
            'MOVE THE PACKAGE to the target instance if different: GET action=backup-download to fetch it, then POST action=site-backup-upload (multipart) on the target to import it into that instance\'s backups area. Same-instance moves skip this - the package is already there',
            'BEFORE APPLYING, make sure the target domain exists (register it with domain-add if needed) and, if you want a rollback point, take a backup - apply overwrites the target content root',
            'ON THE TARGET: call site_apply (MCP) or POST action=site-backup-apply (control API) with the package name and the target host (omit host to apply to the default site; pass clean:true to clear the target content first). This copies the content in, installs the bundled theme/layout if the target lacks it, places the nav, and sets the target domain\'s presentation. The control-API action also takes a safety snapshot automatically',
            'verify with a domain preview (domain-preview) or by loading the target host',
        ],
    },
);

# SM225: the documentation index. A partner told to "call this first" learns the
# capability model and nothing about the ~30 documentation pages the site
# publishes, so it reasons from the tool surface alone and reinvents documented
# behaviour (or concludes a feature is absent). The index is DERIVED, not curated:
# a scan of {DOCROOT}/docs reading each page's own `title:` / `subtitle:` front
# matter, so a site that adds or removes a doc reports the truth instead of a
# hard-coded list going stale. Briefings are listed first because an agent should
# read those before designing anything; everything else is reference.
#
# Top-level pages only. Subtrees (docs/features/, docs/integrations/) are reached
# from the pages that cite them, and enumerating them here would bury the entry
# points the index exists to surface.
sub _doc_meta {
    my ($path) = @_;
    open my $fh, '<', $path or return;
    my ( $title, $subtitle );
    my $n = 0;
    while ( my $line = <$fh> ) {
        last if ++$n > 20;
        if ( $line =~ /^title\s*:\s*(.+?)\s*$/ )    { $title    = $1 }
        if ( $line =~ /^subtitle\s*:\s*(.+?)\s*$/ ) { $subtitle = $1 }
        last if defined $title && defined $subtitle;
    }
    close $fh;
    for ( $title, $subtitle ) {
        next unless defined;
        s/\A(["'])(.*)\1\z/$2/;    # front matter may quote the value
    }
    return ( $title, $subtitle );
}

sub _scan_docs {
    my ($docroot) = @_;
    return unless defined $docroot && length $docroot;
    my $dir = "$docroot/docs";
    return unless -d $dir;
    opendir my $dh, $dir or return;
    my ( @briefings, @reference );
    for my $f ( sort readdir $dh ) {
        next unless $f =~ /\A([A-Za-z0-9][A-Za-z0-9._-]*)\.md\z/;
        my $slug = $1;
        next unless -f "$dir/$f";
        my ( $title, $subtitle ) = _doc_meta("$dir/$f");
        next unless defined $title && length $title;
        my %entry = ( path => "/docs/$slug", title => $title );
        $entry{answers} = $subtitle if defined $subtitle && length $subtitle;
        push @{ $slug =~ /^ai-briefing-/ ? \@briefings : \@reference }, \%entry;
    }
    closedir $dh;
    return unless @briefings || @reference;
    return {
        note =>
            'The site publishes its own documentation. Read the briefings before '
            . 'designing anything - they answer most questions about what lazysite '
            . 'can do, and a capability you cannot see may be documented rather '
            . 'than absent. Every path below is a public page you can fetch '
            . 'without a credential.',
        briefings => \@briefings,
        reference => \@reference,
    };
}

# SM226: why each entry in `holds` reads the way it does. A false is always the
# same story - the capability exists and was not granted - and saying so is what
# stops a reader treating it as absence. The case worth real explanation is the
# opposite one: a channel capability that IS granted while its site service is
# off, which today renders as a bare true and does nothing. `capabilities` and
# `holds` disagreeing with observable behaviour is exactly the confusion this
# block exists to remove. Needs a docroot to read the killswitches; without one
# the dormancy answer is simply omitted rather than guessed.
sub _holds_why {
    my ( $caps, $docroot ) = @_;
    my %why;
    for my $k (@CAP_KEYS) {
        if ( !$caps->{$k} ) {
            $why{$k} = 'not granted to this account. The capability exists in '
                . 'lazysite - ask the operator to grant it.';
            next;
        }
        next unless $IS_CHANNEL{$k};
        my $svc = $CHANNEL_SERVICE{$k};
        next unless defined $svc;
        next unless defined $docroot && length $docroot;
        next if Lazysite::Util::service_enabled( $docroot, $svc );
        $why{$k} = "granted, but DORMANT: this site's `$svc` service is off, so "
            . 'the channel refuses regardless of the grant. Ask the operator to '
            . 'enable the service.';
    }
    return \%why;
}

# Build the map. Pass caps => { cap => 0|1 } (the caller's resolved grant) and,
# optionally, groups => [...] and account => "name" to include the "holds" block;
# docroot => "..." adds the SM225 documentation index. Omit caps for the static
# model only (e.g. the generated doc).
# SM491: WHICH OF THIS GRANT'S CHANNELS CAN ACTUALLY REACH EACH CAPABILITY.
#
# A capability is a permission; a channel is a door. An account can hold a
# capability whose every door is shut on a different switch - analytics:true
# with mcp:false was the field case - and whoami reported a bare `true`,
# which is not operationally true. The operator saw the grant applied, the
# agent saw the capability held, and neither could use it.
#
# Derived from the `unlocks` map rather than declared, so a capability that
# gains or loses a surface changes this answer without anybody remembering to.
# Returns, per capability the account holds, the channels it is reachable on
# and the channels that would unlock it but are off for this grant.
sub reachability {
    my ($settings) = @_;
    my %out;
    for my $cap (@CAP_KEYS) {
        next unless $settings->{$cap};
        my $u = ( $ACTION_INFO{$cap} || {} )->{unlocks} || {};
        my ( @via, @shut );
        for my $ch (qw(api mcp)) {
            next unless ref $u->{$ch} eq 'ARRAY' && @{ $u->{$ch} };
            if   ( $settings->{$ch} ) { push @via,  $ch }
            else                      { push @shut, $ch }
        }
        # `ui` is the manager itself; webdav carries no capability-gated
        # actions of its own. A capability with NO api/mcp surface is a
        # manager-page capability and reachability is not the question.
        next unless @via || @shut;
        $out{$cap} = { via => \@via, ( @shut ? ( requires => \@shut ) : () ) };
    }
    return \%out;
}

# SM564: a group is judged by its REACH, not its record. Given a capability
# set as the resolver returns it ({ cap => 0|1 }), the effective callable set
# per channel, derived from the same `unlocks` tables describe() publishes:
#
#   { api => { held => 0|1, unlocked => [...], callable => [...] }, ... }
#
# `unlocked` is what the ACTION capabilities held would expose on that
# channel; `callable` is that list when the channel itself is held, and empty
# when it is not. Two rules fall out of the tables rather than being declared
# here: a channel flag alone unlocks nothing (SM570 - a door is not an
# authority), and an action capability without its door reaches nothing.
# SM570 is also why this exists: an account's declared capabilities and what
# it can actually call were found to be different things.
sub reach_for {
    my ($caps) = @_;
    $caps ||= {};
    my %out;
    for my $ch (@CHANNELS) {
        my ( %seen, @unlocked );
        for my $cap ( action_keys() ) {
            next unless $caps->{$cap};
            my $u = ( $ACTION_INFO{$cap} || {} )->{unlocks} || {};
            push @unlocked, grep { !$seen{$_}++ } @{ $u->{$ch} || [] };
        }
        my $held = $caps->{$ch} ? 1 : 0;
        $out{$ch} = {
            held     => $held,
            unlocked => \@unlocked,
            callable => [ $held ? @unlocked : () ],
        };
    }
    return \%out;
}

sub describe {
    my (%opt) = @_;
    my $T     = JSON::PP::true();
    my $F     = JSON::PP::false();

    my %channels;
    $channels{$_} = { enforced => $T, note => $CHANNEL_INFO{$_},
        service => $CHANNEL_SERVICE{$_} } for @CHANNELS;

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

    if ( my $docs = _scan_docs( $opt{docroot} ) ) { $map{docs} = $docs }

    if ( $opt{caps} ) {
        my $caps = $opt{caps};
        # SM226: `capabilities` above is what lazysite OFFERS; `holds` is what THIS
        # account was GRANTED. Readers flatten the two and read a false as absence -
        # a partner tabulated read_submissions:false, concluded submissions could not
        # be read at all, and specified a replacement store. The scope line is prose
        # in the payload deliberately: the consumer is a language model and the
        # misreading is a language misreading.
        $map{holds} = {
            ( defined $opt{account} ? ( account => $opt{account} ) : () ),
            ( $opt{groups}          ? ( groups  => $opt{groups} )  : () ),
            scope =>
                'What THIS account has been granted. A false value means "not '
                . 'granted to this account", never "not available in lazysite" - see '
                . '"capabilities" for what the platform offers, and ask the operator '
                . 'for a grant. See "why" for the reason each false is false.',
            capabilities => { map { $_ => ( $caps->{$_} ? $T : $F ) } @CAP_KEYS },
            why          => _holds_why( $caps, $opt{docroot} ),
        };
    }

    return \%map;
}

1;
