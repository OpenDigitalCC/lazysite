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
my ($need_block) = $api_src =~ /my \%need = \((.*?)\n    \);/s;
my @api_live = $need_block =~ /'([a-z0-9_-]+)'\s*=>\s*sub/g;
my @mcp_live = $mcp_src =~ /^    ([a-z_]+)\s*=>\s*\{/mg;
cmp_ok( scalar @api_live, '>=', 40, 'the control-API action table was parsed' );
cmp_ok( scalar @mcp_live, '>=', 40, 'the MCP tool table was parsed' );

# Introspection is capability-free by design, so it has no `unlocks` home.
my %INTROSPECTION = map { $_ => 1 }
    qw(whoami describe-capabilities describe_capabilities);

# The ACL actions are gated by the WEBDAV CHANNEL capability rather than an
# action capability, so they legitimately have no action-capability home; the
# channel's own description names them instead.
my %CHANNEL_GATED = map { $_ => 1 } qw(acl-get acl-set acl-remove);

# --- 1. the map must be COMPLETE, or everything below measures nothing -------
my $map = describe();
my ( %api_cap, %mcp_cap );
for my $c ( action_keys() ) {
    my $u = $map->{capabilities}{$c}{unlocks} || {};
    $api_cap{$_} = $c for @{ $u->{api} || [] };
    $mcp_cap{$_} = $c for @{ $u->{mcp} || [] };
}
for my $a ( sort @api_live ) {
    next if $INTROSPECTION{$a} || $CHANNEL_GATED{$a};
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
    'analyse_visitors'    => 'analyse_visitors',
    'domains-list'        => 'list_domains',
    'domain-set'          => 'domain_set',
    'domain-preview'      => 'preview_domain',
    'site-backup-create'  => 'site_backup',
    'site-backup-apply'   => 'site_apply',
    'form-submissions'    => 'read_form_submissions',
    'form-list'           => 'form_list',
    'git-history'         => 'list_versions',
    'git-history-summary' => 'list_content_history',
    'git-show'            => 'view_version',
    'git-restore'         => 'restore_version',
    'layout-activate'     => 'activate_layout',
    'layout-install'      => 'install_layout',
    'layout-delete'       => 'delete_layout',
    'layouts-manifest'    => 'list_layout_catalogue',
    'theme-activate'      => 'activate_theme',
    # SM262: paired, but NOT identical - the MCP tool is always restricted to
    # themes the caller created, while the API action restricts only for token
    # clients and leaves the manager UI's cookie session unrestricted. Same
    # action, two channels, one of which can have a human behind it.
    'theme-delete'        => 'delete_theme',
    'themes-list-all'     => 'list_themes',
    'nav-read'            => 'read_nav',
    'nav-save'            => 'set_nav',
    'pages'               => 'list_pages',
);
for my $a ( sort keys %PAIR ) {
    ok( ( grep { $_ eq $a } @api_live ), "paired API action '$a' still exists" );
    ok( ( grep { $_ eq $PAIR{$a} } @mcp_live ),
        "paired MCP tool '$PAIR{$a}' still exists" );
}

# --- 3. one-sided actions, each with a recorded reason -----------------------
my %API_ONLY = (
    'audit'       => 'undecided - an agent cannot read the audit trail over MCP',
    'config-read' => 'undecided - no MCP twin for site configuration',
    'config-set'  => 'undecided - as config-read',
    'git-init'    => 'undecided - enabling content history is a site-configuration act',
    'git-status'  => 'undecided - the MCP side exposes versions, not repo state',
    'aliases-list'      => 'undecided',
    'lang-status'       => 'undecided',
    'domain-add'    => 'deliberate (SM238) - creating a domain has DNS and certificate consequences beyond this instance',
    'domain-remove' => 'deliberate (SM238) - destructive and instance-level',
    'domain-check'  => 'deliberate (SM238) - an outbound probe; held with add/remove',
    'theme-list'          => 'superseded by themes-list-all, which is paired',
    'themes-for-layout'   => 'undecided',
    'layouts-available'   => 'undecided - list_layout_catalogue covers the repo, not the installed set',
    # SM263: settled, so it stops being re-asked. A token client needing the
    # bytes uses WebDAV; the control API and MCP are for structured actions.
    'site-backup-download' => 'deliberate (SM263) - streams bytes; WebDAV is the file channel for a token client, and an action API is the wrong shape for a byte stream',
    'site-backup-upload'   => 'deliberate - as site-backup-download',
    'site-backup-delete'   => 'undecided',
    'site-backup-inspect'  => 'undecided',
    'site-export-primary'  => 'undecided',
    'preview-grant'        => 'deliberate - mints a browser preview cookie; meaningless to a connector',
    'artifact-manifest'       => 'undecided',
    'artifact-validate'       => 'undecided',
    'artifact-backups-delete' => 'undecided',
    'bad-url-blocks'          => 'undecided',
    'bad-url-unblock'         => 'undecided',
);
my %MCP_ONLY = (
    'submit_feedback' => 'deliberate - an agent-to-operator channel with no API caller',
    'upload_file'     => 'deliberate (SM240) - the API channel has WebDAV for bulk bytes',
    'theme_tokens'       => 'undecided',
    'create_theme'       => 'undecided',
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
    next if $INTROSPECTION{$a} || $CHANNEL_GATED{$a} || $paired_api{$a};
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

done_testing();
