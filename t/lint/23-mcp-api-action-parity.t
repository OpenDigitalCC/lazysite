#!/usr/bin/perl
# SM239: ACTION-LEVEL parity between the control API and the MCP connector.
#
# The two remote channels drifted apart one action at a time with nothing
# recording whether a gap was deliberate - SM238 found the whole domain CRUD on
# the API and absent from MCP, under the same capability, which nobody had
# decided. The first cut of this guard compared capability-level SHAPE, which was
# cheap and would NOT have caught SM238: manage_domains read as "paired" because
# it had entries on both channels while the domain verbs were missing from one.
#
# This is the pairing that cut deferred. It needs a name map, because twins are
# spelled differently on the two channels (form-submissions <->
# read_form_submissions), and it needs a reason per one-sided action rather than
# a count. "Undecided" is an honest reason and recording it is the point: a gap
# nobody has looked at should read differently from a gap someone chose.
#
# It also pins the map itself. Building it surfaced that THIRTEEN real
# control-API actions appeared in no `unlocks` list at all, so
# describe_capabilities was under-reporting what each capability gives. A parity
# guard reading an incomplete map measures nothing, so completeness is checked
# first.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper             qw(repo_root);
use Lazysite::Capabilities qw(describe action_keys);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $api_src = slurp("$root/lazysite-manager-api.pl");
my $mcp_src = slurp("$root/lazysite-mcp.pl");

# The live surfaces: %need keys are the token-callable actions, %TOOLS keys the
# MCP tools.
my ($need_block) = $api_src    =~ /my \%need = \((.*?)\n    \);/s;
my @api_live     = $need_block =~ /'([a-z0-9_-]+)'\s*=>\s*sub/g;
my @mcp_live     = $mcp_src    =~ /^    ([a-z_]+)\s*=>\s*\{/mg;
cmp_ok( scalar @api_live, '>=', 40, 'the control-API action table was parsed' );
cmp_ok( scalar @mcp_live, '>=', 40, 'the MCP tool table was parsed' );

# Introspection is capability-free by design, so it has no `unlocks` home.
# SM350 adds actions-list: the control API's answer to tools/list. Capability-free
# for the same reason as the other two - an agent needs the reference BEFORE it
# knows what it may call, so gating it would put the answer behind the question.
# It is API-only by definition rather than by omission: MCP already has
# tools/list, and this is that.
my %INTROSPECTION = map { $_ => 1 }
    qw(whoami describe-capabilities describe_capabilities actions-list);

# SM431 removed the CHANNEL_GATED exemption that lived here: the ACL actions
# now have an action-capability home (manage_content, matching their MCP
# twins), so the completeness check below covers them like everything else.

# --- 1. the map must be COMPLETE, or everything below measures nothing -------
my $map = describe();
my ( %api_cap,  %mcp_cap );
my ( %api_caps, %mcp_caps );    # SM567: the SET, for the twin comparison
for my $c ( action_keys() ) {
    my $u = $map->{capabilities}{$c}{unlocks} || {};
    $api_cap{$_}      = $c for @{ $u->{api} || [] };
    $mcp_cap{$_}      = $c for @{ $u->{mcp} || [] };
    $api_caps{$_}{$c} = 1  for @{ $u->{api} || [] };
    $mcp_caps{$_}{$c} = 1  for @{ $u->{mcp} || [] };
}

# SM567: twins that sit under DIFFERENT capabilities on the two channels,
# each with the reason - the same discipline as %API_ONLY. A twin listed
# here is a recorded decision or a filed question, never an oversight.
my %TWIN_DIFFERS = (
    # SM568: reading the navigation and the page list needs manage_nav on the
    # API and manage_content over MCP - reads are weaker on one channel, and
    # nobody decided that. Filed; the lint records the question until it is
    # answered, so the class stays guarded for every other twin.
    'nav-read' => 'SM568: manage_nav (API) vs manage_content (MCP) - undecided, filed',
    'pages'    => 'SM568: manage_nav (API) vs manage_content (MCP) - undecided, filed',
);
for my $a ( sort @api_live ) {
    next if $INTROSPECTION{$a};
    ok( $api_cap{$a}, "control-API action '$a' is declared under a capability" )
        or diag( "  '$a' is callable but appears in no unlocks list, so "
            . 'describe_capabilities under-reports what its capability gives.' );
}
for my $t ( sort @mcp_live ) {
    next if $INTROSPECTION{$t};
    ok( $mcp_cap{$t}, "MCP tool '$t' is declared under a capability" );
}

# --- 2. the twins, by name ---------------------------------------------------
my %PAIR = (
    'analyse_visitors' => 'analyse_visitors',
    # SM301: was an MCP-only entry whose recorded reason was "the API path can
    # add one when someone asks for it". A live site asked, having taken its own
    # sitemap.xml down by deleting the generated file for want of this.
    'regenerate-registries' => 'regenerate_registries',
    'domains-list'          => 'list_domains',
    'domain-set'            => 'domain_set',
    'domain-preview'        => 'preview_domain',
    'site-backup-create'    => 'site_backup',
    'site-backup-apply'     => 'site_apply',
    'form-submissions'      => 'read_form_submissions',
    'form-list'             => 'form_list',
    'git-history'           => 'list_versions',
    'git-history-summary'   => 'list_content_history',
    'git-show'              => 'view_version',
    'git-restore'           => 'restore_version',
    'layout-activate'       => 'activate_layout',
    'layout-install'        => 'install_layout',
    'layout-delete'         => 'delete_layout',
    'layouts-manifest'      => 'list_layout_catalogue',
    'theme-activate'        => 'activate_theme',
    # SM262: paired, but NOT identical - the MCP tool is always restricted to
    # themes the caller created, while the API action restricts only for token
    # clients and leaves the manager UI's cookie session unrestricted. Same
    # action, two channels, one of which can have a human behind it.
    'theme-delete'    => 'delete_theme',
    'themes-list-all' => 'list_themes',
    'nav-read'        => 'read_nav',

    # SM447: the data tables. Both channels, one implementation - each pair
    # routes through Lazysite::Manager::Data, so a difference between them
    # would have to be introduced deliberately.
    'data-tables'     => 'list_data_tables',
    'data-table'      => 'describe_data_table',
    'data-table-save' => 'save_data_table',

    # SM466: the existing preview-public action, given an MCP door so the field
    # can confirm what a visitor receives without stepping outside the grant.
    'preview-public'  => 'preview_public_page',
    'data-rows'       => 'read_data_rows',
    'data-migrate'    => 'migrate_data_table',
    'data-rebuild'    => 'rebuild_data_table',
    'data-table-drop' => 'drop_data_table',
    'data-row-save'   => 'save_data_row',
    'data-row-delete' => 'delete_data_row',
    # SM512: the safety exports, listed and cleared - the SM508 pattern for tables.
    'data-safety-exports'        => 'list_data_safety_exports',
    'data-safety-export-delete'  => 'delete_data_safety_export',
    'data-safety-export-read'    => 'read_data_safety_export',
    'data-safety-export-restore' => 'restore_data_safety_export',
    'nav-save'                   => 'set_nav',
    'pages'                      => 'list_pages',
    # SM431: the permissions twins, recorded as twins. acl-remove has no
    # named MCP twin (set_permissions with empty lists clears a rule) and
    # passes the completeness check under manage_content like the others.
    'acl-get' => 'get_permissions',
    'acl-set' => 'set_permissions',
    # SM245: the brief store's twins.
    'brief-read'   => 'read_brief',
    'brief-append' => 'append_brief',
    # SM508: the lifecycle's discovery and cleanup halves.
    'briefs-list'  => 'list_briefs',
    'brief-delete' => 'delete_brief',
);
for my $a ( sort keys %PAIR ) {
    ok( ( grep { $_ eq $a } @api_live ), "paired API action '$a' still exists" );
    ok( ( grep { $_ eq $PAIR{$a} } @mcp_live ),
        "paired MCP tool '$PAIR{$a}' still exists" );

    # SM567 (the operator's four-surface check, API-to-MCP column): twins sit
    # under the SAME capability. SM570 was two tables disagreeing about WHO
    # while both looked authoritative; a twin under a different capability on
    # the other channel is that defect wearing the other hat.
    next if $TWIN_DIFFERS{$a};

    # An MCP tool declares ONE capability; the API may accept EITHER of two
    # (manage_forms or read_submissions for a submission read; manage_layouts
    # or manage_themes for a catalogue) - decided either-ofs, not drift. So
    # the rule is: the MCP capability must be one the API accepts for the same
    # operation. A twin whose MCP capability the API does not accept at all is
    # the SM570 shape wearing the other hat.
    my @mcp_only = grep { !$api_caps{$a}{$_} } sort keys %{ $mcp_caps{ $PAIR{$a} } || {} };
    is_deeply( \@mcp_only, [],
        "twins '$a' / '$PAIR{$a}': the MCP capability is one the API accepts" )
        or diag( "MCP unlocks '$PAIR{$a}' under @mcp_only; the API unlocks '$a' under "
            . join( ',', sort keys %{ $api_caps{$a} || {} } ) );
}

# --- 3. one-sided actions, each with a recorded reason -----------------------
my %API_ONLY = (
    # SM431: acl-get/acl-set are paired with the permissions tools; acl-remove
    # has no named twin because set_permissions with empty read/write lists
    # clears a rule - a twin would be a second spelling of the same operation.
    'acl-remove' => 'set_permissions with empty lists is the MCP spelling',
    # SM245: the sidecar migration is an operator's one-shot, reached from the
    # Plugin Manager; an agent has no standing to run it.
    'briefs-migrate' => 'a one-shot operator migration, driven from the Plugin Manager',
    # SM282: an operator-facing check - "what does a VISITOR get for this
    # path" - answered in the panel where the draft section is managed. An
    # agent has no equivalent question: it can already fetch the path
    # anonymously itself, which is all this does.
    # SM281 item 3: the read surface exists now and is API-only for a reason
    # that is a decision rather than an omission. An MCP twin would be the
    # agent door SM231 described - polled, not pushed - and it wants item 2's
    # addressing first, or every agent reads every operator notice.
    'notices' => 'undecided - an MCP twin wants per-notice addressing (SM281 item 2) first',
    # DM-2: a browser download, and deliberately not a tool. It streams bytes
    # with Content-Disposition, which is an affordance for a person clicking a
    # button. An agent has read_data_rows for the rows and site_backup for the
    # exact typed export, so an MCP twin would hand back a file it has nowhere
    # to put.
    'data-export' => 'a file download for a person; an agent has read_data_rows and site_backup',
    'data-import' => 'a file upload from a person; an agent has save_data_row and can loop',
    'data-table-source' => 'the descriptor as TEXT for a human editor; an agent gets the parsed shape from describe_data_table',
    'data-migrate-plan' => 'a preview for a person deciding; an agent calls migrate_data_table and reads its reply',
    'audit'        => 'undecided - an agent cannot read the audit trail over MCP',
    'config-read'  => 'undecided - no MCP twin for site configuration',
    'config-set'   => 'undecided - as config-read',
    'git-init'     => 'undecided - enabling content history is a site-configuration act',
    'git-status'   => 'undecided - the MCP side exposes versions, not repo state',
    'aliases-list' => 'undecided',
    'lang-status'  => 'undecided',
    'domain-add' => 'deliberate (SM238) - creating a domain has DNS and certificate consequences beyond this instance',
    'domain-remove'     => 'deliberate (SM238) - destructive and instance-level',
    'domain-check'      => 'deliberate (SM238) - an outbound probe; held with add/remove',
    'theme-list'        => 'superseded by themes-list-all, which is paired',
    'themes-for-layout' => 'undecided',
    'layouts-available' => 'undecided - list_layout_catalogue covers the repo, not the installed set',
    # SM263: settled, so it stops being re-asked. A token client needing the
    # bytes uses WebDAV; the control API and MCP are for structured actions.
    'site-backup-download' => 'deliberate (SM263) - streams bytes; WebDAV is the file channel for a token client, and an action API is the wrong shape for a byte stream',
    'site-backup-upload'  => 'deliberate - as site-backup-download',
    'site-backup-delete'  => 'undecided',
    'site-backup-inspect' => 'undecided',
    'site-export-primary' => 'undecided',
    'preview-grant' => 'deliberate - mints a browser preview cookie; meaningless to a connector',
    'artifact-manifest'       => 'undecided',
    'artifact-validate'       => 'undecided',
    'artifact-backups-delete' => 'undecided',
    'bad-url-blocks'          => 'undecided',
    'bad-url-unblock'         => 'undecided',
);
my %MCP_ONLY = (
    'submit_feedback' => 'deliberate - an agent-to-operator channel with no API caller',
    'upload_file'     => 'deliberate (SM240) - the API channel has WebDAV for bulk bytes',
    'theme_tokens'    => 'undecided',
    'create_theme'    => 'undecided',
    # SM262: create_theme's counterpart now exists; see the %PAIR entry.
    'list_form_handlers' => 'undecided',
    'bind_form'          => 'undecided',
    'audit_site'         => 'undecided',
    'create_form'        => 'undecided',
    'validate_page'      => 'undecided',
    'preview_page'       => 'undecided',
    'page_status'        => 'undecided',
    'read_page'          => 'undecided',
    'invalidate_cache'   => 'undecided',
);

# Content FILE operations pair with WebDAV, not with a control-API action - the
# API channel does file work over /dav. Listing them as one-sided would be a
# dozen false positives and would train a reader to ignore this list.
my %DAV_PAIRED = map { $_ => 1 } qw(
    list_files read_file write_file replace_text copy_file move_file delete_file
    create_page delete_page rename_page search_files get_permissions set_permissions
);

my %paired_api = map { $_ => 1 } keys %PAIR;
my %paired_mcp = map { $_ => 1 } values %PAIR;

for my $a ( sort @api_live ) {
    next if $INTROSPECTION{$a} || $paired_api{$a};
    ok( $API_ONLY{$a}, "API-only action '$a' has a recorded reason" )
        or diag( "  '$a' has no MCP twin and no entry in \%API_ONLY. Decide "
            . 'whether MCP needs it, then record the answer - "undecided" is '
            . 'allowed and is better than silence.' );
}
for my $t ( sort @mcp_live ) {
    next if $INTROSPECTION{$t} || $paired_mcp{$t} || $DAV_PAIRED{$t};
    ok( $MCP_ONLY{$t}, "MCP-only tool '$t' has a recorded reason" );
}

# --- 4. no stale entries -----------------------------------------------------
# A reason recorded for something since paired or removed reads as a live
# decision, which is worse than no entry.
my %api_live_h = map { $_ => 1 } @api_live;
my %mcp_live_h = map { $_ => 1 } @mcp_live;
for my $a ( sort keys %API_ONLY ) {
    ok( $api_live_h{$a},  "API-only entry '$a' still names a real action" );
    ok( !$paired_api{$a}, "API-only entry '$a' is not also listed as paired" );
}
for my $t ( sort keys %MCP_ONLY ) {
    ok( $mcp_live_h{$t},  "MCP-only entry '$t' still names a real tool" );
    ok( !$paired_mcp{$t}, "MCP-only entry '$t' is not also listed as paired" );
}

subtest 'SM567: the recorded twin differences are still twins, and still differ' => sub {
    for my $a ( sort keys %TWIN_DIFFERS ) {
        ok( $PAIR{$a}, "'$a' is a recorded pair" );
        my @mcp_only = grep { !$api_caps{$a}{$_} } sort keys %{ $mcp_caps{ $PAIR{$a} } || {} };
        ok( @mcp_only, "'$a' still differs - remove it from %TWIN_DIFFERS when it is decided" );
    }
};

done_testing();
