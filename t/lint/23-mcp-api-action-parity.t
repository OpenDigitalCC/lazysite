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
use TestHelper             qw(repo_root gate_caps);
use Lazysite::Capabilities qw(describe action_keys);
use Lazysite::ControlApi::Actions ();

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $api_src = slurp("$root/lazysite-manager-api.pl");
my $mcp_src = slurp("$root/lazysite-mcp.pl");

# The live surfaces: %need keys are the token-callable actions, %TOOLS keys the
# MCP tools.
# SM662: the gate is declarative, so the live action list is simply its keys -
# no regex over a sub body, and nothing to get subtly wrong.
my @api_live = sort keys %{ { gate_caps($api_src) } };
my @mcp_live = $mcp_src =~ /^    ([a-z_]+)\s*=>\s*\{/mg;
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
# SM579: connector-call is reachable by any authenticated caller; the
# CONNECTOR gates it (callers groups, or manage_connectors) and refuses by
# name. It has no capability home by design, and no MCP twin yet (phase 2).
# SM579 phase 2: the MCP twin is gated the same way, by the connector, so it
# has no capability home for the same reason its API half has none.
my %CONNECTOR_GATED = map { $_ => 1 } qw(connector-call connector_call);
# SM778: display-names / display_names have no capability home for the same
# kind of reason as the introspection actions, but it is a DIFFERENT reason
# and is written out rather than folded into that set. They disclose nothing a
# caller does not already hold: they resolve the logins they are GIVEN, one
# call at a time, and are not a listing - so there is no capability that could
# sensibly own them, and describe_capabilities does not under-report by
# leaving them out. If either ever grows a way to enumerate accounts, it needs
# a capability and this exemption goes.
# SM943 ruling 2 (2026-10-09): the structured nav read, nav-read / read_nav,
# needs no capability beyond the surface's base access - the nav is public -
# and reaches only the caller's own domains (SM976). No capability owns it.
my %NO_CAPABILITY_HOME = map { $_ => 1 } qw(display-names display_names nav-read read_nav);

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
# SM568 was the first entry (nav-read and pages: manage_nav on the API,
# manage_content over MCP) and was decided - the API accepts either - so the
# map is empty until the next twin that differs on purpose.
my %TWIN_DIFFERS = ();
for my $a ( sort @api_live ) {
    next if $INTROSPECTION{$a};
    next if $CONNECTOR_GATED{$a};
    next if $NO_CAPABILITY_HOME{$a};
    ok( $api_cap{$a}, "control-API action '$a' is declared under a capability" )
        or diag( "  '$a' is callable but appears in no unlocks list, so "
            . 'describe_capabilities under-reports what its capability gives.' );
}
for my $t ( sort @mcp_live ) {
    next if $INTROSPECTION{$t};
    next if $NO_CAPABILITY_HOME{$t};
    # SM579 phase 2: the connector-gated exemption applied to the API half
    # only, because until now nothing on this side was gated that way. A twin
    # whose gate is the CONNECTOR has no capability home on either surface,
    # and the map does not under-report by omitting it.
    next if $CONNECTOR_GATED{$t};
    ok( $mcp_cap{$t}, "MCP tool '$t' is declared under a capability" );
}

# --- 2. the twins, by name ---------------------------------------------------
# SM943 stage 2: the twin is DATA on the action now - `mcp => 'tool'` on its
# entry in Lazysite::ControlApi::Actions - and this lint's own %PAIR, which was
# the only map between the two channels, is gone. The history each pair carried
# moved onto the action beside it, tagged [mcp]. One tool per action is refused
# at load otherwise.
my %PAIR = Lazysite::ControlApi::Actions::mcp_twins();
cmp_ok( scalar keys %PAIR, '>=', 40, 'the declared twins were read' );
for my $a ( sort keys %PAIR ) {
    # SM943: the action exists by construction (the twin is a field on it). What
    # can still be wrong is the door: a twin of a cookie-only action would give
    # a token over MCP what the same token is refused on the control API.
    ok( ( grep { $_ eq $a } @api_live ),
        "the action '$a' with an MCP twin is reachable with a token" );
    # SM943 stage 3: that the twin names a real tool is part of the declaration's
    # completeness check (t/unit/lib/200), with every other field an entry must
    # carry; the copy that stood here went.

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
    # SM1053: staging an account import is the partner's half of a human's act
    # (SM268); undecided whether MCP needs it - the report's partner used the API.
    'accounts-import-stage' => 'SM1053: undecided - staging accounts for the operator; the partner that asked used the control API',
    # SM924: the submission deletes are reachable on the control API, under a
    # capability of their own that is off by default, and have NO MCP twin.
    #
    # That is a decision and not a gap. The ruling asked for a grant, not a new
    # tool surface: an MCP tool is a second place to document, gate and test a
    # destructive act on personal data, and no report has asked for one. The
    # capability is what was missing - a partner that could read every submission
    # could delete none, so an agent's own test rows could only be cleared by a
    # person - and the capability is now there on the channel the agent already
    # uses to read them.
    'form-submission-delete' =>
        'SM924: a grant was what was missing, not a tool. Deleting personal data '
        . 'over MCP would be a second surface for it and nothing has asked',
    'form-submissions-delete-bulk' =>
        'SM924: as form-submission-delete, and more so - a bulk delete of personal '
        . 'data gets one surface, not two',
    # SM579 phase 1: connectors are configured by an operator over the control
    # API and the (coming) manager page. Whether an AGENT may configure where
    # site data goes, or cause a call, is a phase-2 question to answer once
    # the modes have been proved on edge - recorded rather than left silent.
    # SM579 phase 2 DECIDED these, and the decision is a refusal rather
    # than a gap. "The operator writes connectors; an author references one by
    # name and can never supply a URL" is this filing's whole SSRF answer: an
    # agent that could save a connector could point the site at an internal
    # address, and one that could set a secret could replace a credential it
    # may not read. Those are human acts, and the manager page shipped in the
    # same phase is where they happen.
    'connector-save' => 'SM579 phase 2: writing a destination is an operator act at a human surface',
    'connector-secret-set' => 'SM579 phase 2: setting a credential is an operator act at a human surface',
    'connector-delete' => 'SM579 phase 2: removing a destination is an operator act at a human surface',
    # The two READS have a duller reason: both are gated on manage_connectors,
    # so an agent that may only CALL cannot reach either. When an agent needs
    # to discover which connectors it may call, that is a read designed for
    # the purpose - not manage_connectors handed to an agent so it can browse.
    'connector-list' => 'SM579 phase 2: gated on manage_connectors, which a calling agent does not hold',
    'connector-calls' => 'SM579 phase 2: gated on manage_connectors, which a calling agent does not hold',
    # SM747 CU: the Odoo connection user's key is a credential - set and cleared
    # by an operator, on SM579's reasoning for a connector's secret. The two
    # reads are the operator's view of the connection; what an AGENT gets is
    # slice E's: every operation as a tool (R5), under the default or its own
    # account (Q2).
    'odoo-secret-set'   => 'SM747 CU: setting a credential is an operator act at a human surface',
    'odoo-secret-clear' => 'SM747 CU: removing a credential is an operator act at a human surface',
    'odoo-status'       => 'SM747 CU: the operator\'s view of the connection; the agent\'s surface is slice E',
    'odoo-calls'        => 'SM747 CU: the operator\'s call record; the agent\'s surface is slice E',

    # SM802: operator-only by ruling. A remap rule sends visitors to another
    # host - the authority SM579 kept off MCP for connector destinations, by the
    # ruling's own analogy. The listing goes with the save.
    'remap-list' => 'SM802: operator-only by ruling - the authority SM579 kept off MCP for connector destinations',
    'remap-save' => 'SM802: operator-only by ruling - a rule sends visitors to another host, as a connector destination does',
    # N13-04: switching the audit trail off is an operator act by ruling, and an
    # agent must not be able to switch off the record of what it does.
    'audit-trail-set' => 'N13-04: an agent must not be able to switch off the record of what it does',
    # SM842: one form's handler list. list_handlers returns every binding
    # already (used_by on each handler), so a twin would be a second read of
    # the same fact.
    'form-targets-read' => 'SM842: list_handlers carries every binding as used_by',

    # SM431: acl-get/acl-set are paired with the permissions tools; acl-remove
    # has no named twin because set_permissions with empty read/write lists
    # clears a rule - a twin would be a second spelling of the same operation.
    'acl-remove' => 'set_permissions with empty lists is the MCP spelling',
    # SM732: the PDF render. UNDECIDED for MCP, recorded rather than left
    # silent. The action STREAMS a binary body, and MCP has no established
    # convention here for returning one - a twin would have to invent one (a
    # path the caller then fetches by another route, or a base64 blob), and
    # inventing an MCP binary convention while merely supplying a missing
    # caller is how one omission becomes two decisions. An agent composing a
    # document is SM706's own use case, so this should probably exist; it
    # wants deciding on its merits rather than as a side effect.
    'page-pdf' => 'undecided: MCP has no convention for returning a binary body',

    # SM687: a table's access rule. UNDECIDED for MCP, recorded rather than
    # left silent. get_permissions/set_permissions take a PATH, and a table is
    # addressed by NAME - so an MCP twin means either overloading those tools
    # with a second address form or adding table-specific ones, and that choice
    # belongs with SM611, which may change what a table's rule is keyed on
    # altogether. Deciding now would likely be deciding twice.
    'data-table-acl-get' => 'undecided pending SM611: a table is addressed by name, not path',
    'data-table-acl-set' => 'undecided pending SM611: a table is addressed by name, not path',
    'data-table-acl-remove' => 'undecided pending SM611: a table is addressed by name, not path',
    # SM245: the sidecar migration is an operator's one-shot, reached from the
    # Plugin Manager; an agent has no standing to run it.
    'briefs-migrate' => 'a one-shot operator migration, driven from the Plugin Manager',
    # SM282: an operator-facing check - "what does a VISITOR get for this
    # path" - answered in the panel where the draft section is managed. An
    # agent has no equivalent question: it can already fetch the path
    # anonymously itself, which is all this does.
    # SM918: `notices` is PAIRED now - see %PAIR. The deferral that stood here
    # waited on SM281 item 2's addressing, which shipped with SM485 on
    # 2026-09-29, and the ruling that followed was full parity with the
    # capability as the gate. It is the same reader behind both doors.
    #
    # `notices-seen` gets NO entry here, and its absence from this map is not an
    # oversight. %API_ONLY may only name actions in @api_live - the keys of the
    # declarative gate - and notices-seen is not capability-gated at all: it is
    # cookie-only, absent from ControlApi::Actions' token map. A reason recorded
    # here for an action the gate does not carry would fail subtest 4 by its own
    # rule, that a reason for something removed reads as a live decision.
    #
    # The decision itself lives where the omission does, in
    # Lazysite::ControlApi::Actions beside `notices`: the seen-marker is a
    # per-principal read cursor whose only consumer is a HUMAN's unread badge, an
    # agent has no badge, and a cursor per partner is the first half of an inbox.
    # Machine-to-machine messaging is SM646's XMPP connectors, not a mailbox
    # grown on the side of this store.
    # DM-2: a browser download, and deliberately not a tool. It streams bytes
    # with Content-Disposition, which is an affordance for a person clicking a
    # button. An agent has read_data_rows for the rows and site_backup for the
    # exact typed export, so an MCP twin would hand back a file it has nowhere
    # to put.
    'data-export' => 'a file download for a person; an agent has read_data_rows and site_backup',
    'data-import' => 'a file upload from a person; an agent has save_data_row and can loop',
    'audit'        => 'undecided - an agent cannot read the audit trail over MCP',
    'config-read'  => 'undecided - no MCP twin for site configuration',
    'config-set'   => 'undecided - as config-read',
    'git-init'     => 'undecided - enabling content history is a site-configuration act',
    'git-status'   => 'undecided - the MCP side exposes versions, not repo state',
    'aliases-list' => 'undecided',
    'lang-status'  => 'undecided',
    'domain-add' => 'deliberate (SM238) - creating a domain has DNS and certificate consequences beyond this instance',
    'domain-alias-add' =>
        q{deliberate (SM217) - it IS a domain-add, held with add/remove for SM238's reason},
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
    'bad-url-block'           => 'undecided',
    'bad-url-unblock'         => 'undecided',
);
my %MCP_ONLY = (
    'submit_feedback' => 'deliberate - an agent-to-operator channel with no API caller',
    'upload_file'     => 'deliberate (SM240) - the API channel has WebDAV for bulk bytes',
    'theme_tokens'    => 'undecided',
    'create_theme'    => 'undecided',
    # SM262: create_theme's counterpart now exists; see the %PAIR entry.
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
    pass('no twin differences are recorded') unless keys %TWIN_DIFFERS;
    for my $a ( sort keys %TWIN_DIFFERS ) {
        ok( $PAIR{$a}, "'$a' is a recorded pair" );
        my @mcp_only = grep { !$api_caps{$a}{$_} } sort keys %{ $mcp_caps{ $PAIR{$a} } || {} };
        ok( @mcp_only, "'$a' still differs - remove it from %TWIN_DIFFERS when it is decided" );
    }
};

# --- 4. destruction is a mutation ---------------------------------------------
# SM572: the control API declares its destructive actions in %DESTRUCTIVE (by
# action name, beside %MUTATING) and MCP declares destructive hints in
# %ANNOTATE (by tool name, beside readOnly and openWorld hints the API has no
# use for). Two spellings of one fact, which this section used to keep equal
# twin by twin - SM572 found site-backup-apply and site_apply disagreeing. Since
# SM943 stage 2 there is one spelling: a twin's row is derived from the action.
# What remains here is the rule the fact obeys.
{
    # SM943: both are DERIVED from Lazysite::ControlApi::Actions now, so the
    # declaration is what is read. That the CGI builds %DESTRUCTIVE and
    # %CHANGES_ACCESS from it is asserted with the other eight tables in
    # t/unit/lib/200 (subtest 1); the copies of that here went in stage 3.
    my %api_destr = Lazysite::ControlApi::Actions::destructive();
    cmp_ok( scalar keys %api_destr, '>=', 10, '%DESTRUCTIVE parsed non-trivially' );
    # Once a relationship between two hand-kept tables; now two fields on one
    # entry, and still a rule: nothing is destroyed by a GET.
    my %api_mut = Lazysite::ControlApi::Actions::mutating();
    my @not_mut = sort grep { !$api_mut{$_} } keys %api_destr;
    is( "@not_mut", '', 'every destructive action is a mutating one' );

    # SM943 stage 2: THE COMPARISON THAT STOOD HERE IS TRUE BY CONSTRUCTION, and
    # is removed rather than kept as a check that cannot fail. It read %ANNOTATE's
    # second slot out of lazysite-mcp.pl and required it to equal the twin's
    # %DESTRUCTIVE. A twin's row is now derived from the action's own entry
    # (Lazysite::ControlApi::Actions::mcp_annotations), so there is one spelling
    # of the fact and nothing to disagree.
}

# --- 5. the exposure axis is its own ----------------------------------------
# SM587: the second axis, kept honest exactly as the destructive pair is. The
# control API declares %CHANGES_ACCESS by action name; MCP declares the same
# fact in the FOURTH slot of %ANNOTATE and publishes it as changesAccessHint.
# Two spellings of one fact meant two places to forget; since SM943 stage 2 a
# twin's fourth slot is derived from the action, so what remains here is that
# the two axes stay independent.
{
    my %api_ca = Lazysite::ControlApi::Actions::changes_access();
    cmp_ok( scalar keys %api_ca, '>=', 3, '%CHANGES_ACCESS parsed non-trivially' );

    # The two axes are INDEPENDENT, and an implementation that quietly made one
    # imply the other would pass every other assertion in this file. acl-remove
    # is the case the operator ruled on: it changes access and is not
    # destructive.
    my %api_destr = Lazysite::ControlApi::Actions::destructive();
    ok( $api_ca{'acl-remove'}, 'acl-remove carries the exposure flag' );
    ok( !$api_destr{'acl-remove'},
        'acl-remove is NOT destructive - the rule can be re-set, so a copy survives' );
    ok( $api_destr{'brief-delete'}, 'brief-delete is destructive' );
    ok( !$api_ca{'brief-delete'},
        'brief-delete does not change who can see things - the axes are independent' );

    # SM943 stage 2: the twin comparison that stood here - %ANNOTATE's fourth
    # slot against the twin's %CHANGES_ACCESS - is true by construction for the
    # same reason as the destructive one above, and is removed with it.
}

# --- 6. the two trails decide from one declaration ---------------------------
# SM943 RULING 1 (2026-10-09): "Audit is useful to see when a person or agent has
# made material behaviour changes, authentication events and errors. General
# site activity is of less interest and creates noise. Surfaces should be
# consistent. Drop all 17." The seventeen were MCP reads this trail recorded
# while the API trail skipped their twins - one act, recorded on one door and
# not the other, kept in step by nobody.
#
# So each trail's decision is read from what its CGI does, and for every twin
# the two must agree: audited on both trails or on neither. The API's %skip is
# unaudited() (t/unit/lib/200 holds the CGI to that); MCP's is the rule written
# in lazysite-mcp.pl, which must be the read-only rule with no names in it -
# a named exception there is exactly how the seventeen were kept.
{
    my %ann  = Lazysite::ControlApi::Actions::mcp_annotations();
    my %skip = Lazysite::ControlApi::Actions::unaudited();

    my @rule = $mcp_src =~ /^my %READ\s*=\s*([^;]*);/mg;
    is_deeply( \@rule, ['map { $_ => 1 } grep { $ANNOTATE{$_}[0] } keys %ANNOTATE'],
        'MCP skips exactly the read-only tools - no tool is named' );
    my @writes = $mcp_src =~ /(\$READ\{[^}]*\}\s*(?:=(?!=)|\|\|=|\/\/=)|delete\s+\$READ\{)/g;
    is( "@writes", '', 'and nothing else writes to the skip set' );

    # A twin recorded here is audited on one trail and not the other ON PURPOSE,
    # with the reason - the %TWIN_DIFFERS discipline. Reads may not be recorded:
    # the ruling is that a read is not audited on any surface.
    my %AUDIT_DIFFERS = (
        'regenerate-registries' => 'a write, outside ruling 1: declared unaudited '
            . 'on the API (`audited => 0`, with cache-invalidate) while MCP audits '
            . 'every write tool',
    );
    for my $a ( sort keys %PAIR ) {
        my $t   = $PAIR{$a};
        my $api = $skip{$a}   ? 'skips' : 'audits';
        my $mcp = $ann{$t}[0] ? 'skips' : 'audits';
        if ( $AUDIT_DIFFERS{$a} ) {
            ok( $ann{$t}[0] ? 0 : 1, "'$a' recorded as differing is a write" );
            isnt( $mcp, $api, "'$a' still differs - remove it from %AUDIT_DIFFERS when decided" );
            next;
        }
        is( $mcp, $api, "twins '$a' / '$t': both trails " . ( $api eq 'skips' ? 'skip' : 'audit' ) . ' it' )
            or diag( "The API trail ${api} '$a' and the MCP trail ${mcp} '$t'. One act "
                . 'is audited on both doors or on neither (SM943 ruling 1).' );
    }

    # A read's REFUSAL or ERROR is recorded on both, by the same test of the
    # result. Behaviour is proved in t/unit/mcp/28 and t/unit/manager/206; this
    # pins that each CGI still states the rule they prove.
    like( $mcp_src, qr/if \( !\$READ\{\$name\} \|\| !\$aok \) \{/,
        'MCP records a read whose answer is a refusal or an error' );
    like( $api_src, qr/!\$skip\{\$aud_action\} \|\| \( \$AUDIT_FAILED && !\$MUTATING\{\$aud_action\} \)/,
        'the control API records a read whose answer is a refusal or an error' );
    like( $api_src, qr/eq 'POST' \|\| \$AUDIT_FAILED \)/,
        '...over GET as well, which is how a token client reads' );
}

done_testing();
