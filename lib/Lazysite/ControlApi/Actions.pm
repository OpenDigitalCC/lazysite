package Lazysite::ControlApi::Actions;

# SM350: the control API's action reference, as data.
#
# WHAT WAS MISSING. MCP has tools/list, with a JSON Schema per tool. The control
# API is an enforced, first-class channel - describe-capabilities declares it as
# one - and had no equivalent and no documentation page. Across 23 reference docs
# and 7 briefings, a search for its action names returned one incidental mention.
# So the only way to learn what an action takes was to read the CGI, which a
# token client cannot do, or to try it and read the error.
#
# WHY THIS IS A DECLARATION AND NOT A DISPATCH TABLE. The filing asked for the
# reference to be GENERATED from the dispatch table rather than hand-written,
# citing three defects already caused by hand-maintained lists. It is right, and
# there is no dispatch table to generate from: the control API dispatches through
# a 108-branch if/elsif chain. SM237 met the same wall, wrote %KNOWN_ACTION as a
# literal, said plainly that the chain "is the underlying issue and it deserves
# its own request", and pinned the literal to the chain with t/lint/22 so drift
# is impossible.
#
# This takes the same treatment one step further. The table below was EXTRACTED
# from the chain rather than typed, and t/lint/58 re-extracts it and fails on any
# difference - action set, capabilities and parameters alike. So it is a fourth
# list, and it is a fourth list that cannot drift, which is the property the
# filing actually wanted. Replacing the chain with a real table remains the right
# fix and remains its own piece of work.
#
# THE THREE CAPABILITY STATES, which are the useful part of this document:
#
#   caps => ['manage_themes','manage_layouts']   any ONE of these is enough
#   caps => []                                   any authenticated caller
#                                                (introspection: whoami,
#                                                describe-capabilities)
#   caps => undef                                NOT reachable with a token.
#                                                Cookie-only - the manager UI
#                                                calls it and an agent cannot.
#
# The third state is the one a caller cannot discover any other way, and it is
# the reason SM237 needed %KNOWN_ACTION at all: without it the token gate could
# not tell "exists, but cookie-only" from "no such action", and reported both as
# the former.
#
# `required => 1` MARKS A PARAMETER THE ACTION REFUSES TO RUN WITHOUT, and
# the dispatcher answers its absence before the branch is reached, in one
# sentence naming the parameter and where it goes (SM773). It is marked only
# where the handler ALREADY refuses an absent value, so hoisting the check
# changes the message and never the behaviour - and the set grows by evidence,
# never by guessing which parameters an action could do without. A `note`
# carries what the generated sentence cannot know - that an empty value MEANS
# something here, which is the difference between "false" and "no answer" and
# the reason this check asks whether a parameter was SENT rather than whether
# it is true. An unmarked
# parameter is not "optional"; it is one nobody has established either way.
#
# WHERE A PARAMETER IS READ FROM is recorded because the two channels are not
# interchangeable in the chain. `query` is the query string, `body` is the JSON
# request body, and `query_or_body` means the branch accepts either - which is
# real, not a hedge: several actions read the query string and fall back to the
# body, and a caller sending only one of them needs to know which.

use strict;
use warnings;

# THE GATE ITSELF (SM662 / A1), moved here verbatim from the sub in
# lazysite-manager-api.pl that used to declare it - comments and all, because the
# reasoning per entry is the most valuable thing in the table.
#
# An arrayref is ANY-OF. 'ALWAYS' means no capability is needed. An action ABSENT
# from this table is not reachable with a token at all, which is the cookie-only
# state, and the reason this table is shorter than %ACTION below.
#
# %ACTION's `caps` are DERIVED from this at load, so the published reference
# cannot disagree with the gate that decides.

our %GATE = (
    'artifact-manifest' => [qw(manage_themes manage_layouts)],
    'artifact-validate' => [qw(manage_themes manage_layouts)],
    'theme-activate'    => [qw(manage_themes)],

    # SM749: the first step of copy-edit-activate, on the channel whose
    # refusal names it. A copy changes nothing live.
    'theme-copy'      => [qw(manage_themes)],
    'layout-activate' => [qw(manage_layouts)],
    'preview-grant'   => [qw(manage_themes manage_layouts)],
    'config-set'      => [qw(manage_config)],
    'config-read'     => [qw(manage_config)],                  # SM122: read a safe subset
        # SM579: configuring a connector is authority over where data goes.
        # connector-call is gated by the CONNECTOR (its callers groups, or
        # manage_connectors) inside Connectors::may_call, so any logged-in
        # manager may reach the action and the connector decides.
    'connector-list'       => [qw(manage_connectors)],
    'connector-save'       => [qw(manage_connectors)],
    'connector-secret-set' => [qw(manage_connectors)],
    'connector-delete'     => [qw(manage_connectors)],
    'connector-calls'      => [qw(manage_connectors)],
    # SM160: domain management + the portable site-package family are the
    # manage_domains capability (carved out of manage_config), so an
    # orchestrating control panel drives the lazysite side of a deploy
    # with a manage_domains token, same as the CLI/UI.
    # SM447: token clients are the point of the data plugin - an agent
    # populating a table is the primary use, not an afterthought.
    'page-pdf'                   => [qw(manage_content)],
    'data-tables'                => [qw(manage_data)],
    'data-table'                 => [qw(manage_data)],
    'data-rows'                  => [qw(manage_data)],
    'data-migrate'               => [qw(manage_data)],
    'data-row-save'              => [qw(manage_data write_data)],
    'data-table-save'            => [qw(manage_data)],
    'data-table-acl-get'         => [qw(manage_content)],           # SM687
    'data-table-acl-set'         => [qw(manage_content)],           # SM687
    'data-table-acl-remove'      => [qw(manage_content)],           # SM687
    'data-rebuild'               => [qw(manage_data)],
    'data-export'                => [qw(manage_data)],
    'data-import'                => [qw(manage_data)],
    'data-table-source'          => [qw(manage_data)],
    'data-migrate-plan'          => [qw(manage_data)],
    'data-table-drop'            => [qw(housekeeping)],
    'data-safety-exports'        => [qw(manage_data)],
    'data-safety-export-delete'  => [qw(purge)],
    'data-safety-export-read'    => [qw(manage_data)],
    'data-safety-export-restore' => [qw(manage_data)],
    # SM576 part 1: see %COOKIE_CAP above - the write half moves to
    # manage_briefs, the read half accepts either.
    'brief-read'      => [qw(manage_content manage_briefs)],
    'brief-append'    => [qw(manage_briefs)],
    'briefs-migrate'  => [qw(manage_briefs)],
    'briefs-list'     => [qw(manage_content manage_briefs)],
    'brief-delete'    => [qw(purge)],
    'data-row-delete' => [qw(manage_data write_data)],
    'domains-list'    => [qw(manage_domains)],                 # read-only domains view
    'domain-add'      => [qw(manage_domains)],
    # SM217: the same authority as domain-add, because it IS a domain-add -
    # one that reads the shared content root rather than being told it.
    'domain-alias-add' => [qw(manage_domains)],
    'domain-set'       => [qw(manage_domains)],
    'remap-list'       => [qw(manage_domains)],    # SM802
    'remap-save'       => [qw(manage_domains)],
    'audit-trail-set' => [qw(audit_switch)],  # N13-04: AND manage_config, in the dispatch
    'domain-remove'   => [qw(manage_domains)],
    'domain-preview' => [qw(manage_domains)], # SM155: pre-DNS render
    'domain-check'   => [qw(manage_domains)], # SM156: live config check
    'lang-status'    => [qw(manage_content)], # SM179 P6: set coverage (translation agent)
        # SM301: the twin of MCP's regenerate_registries. Same capability, and
        # now the same availability - the account that holds manage_content can
        # reach it whichever door it was granted.
    'regenerate-registries' => [qw(manage_content)],
    # SM281 item 3: the notice store as a READ surface.
    #
    # `notifications` unlocked a manager page and had no remote surface at
    # all - the bell reads the store, and MCP and the control API could
    # not. That is an SM239 parity gap on its own, and it is the half that
    # makes the agent door real: SM231 recorded, from observation rather
    # than speculation, that remote agents had been EDITING THE BRIEFING
    # DOCUMENT to talk to each other, because it was the only durable,
    # shared, writable place they both had.
    #
    # Read only. Writing is emission, which SM231 built and which routes by
    # type; a remote writer is item 2's addressing question and is not
    # answered by making the store readable.
    #
    # SM918: the MCP twin (`read_notices`) now exists and takes this same
    # capability, so the two doors agree about who may read the bell - the
    # capability is the gate, not the channel. One reader serves both:
    # Lazysite::Manager::Notices.
    #
    # AND `notices-seen` IS DELIBERATELY ABSENT FROM THIS MAP - it is
    # cookie-only, and that is the decision rather than an omission. It writes a
    # per-principal read cursor whose only consumer is a HUMAN's unread badge in
    # the manager header. An agent has no badge, and a read cursor per partner is
    # the first half of an inbox, which is not what notifications are for;
    # notices stay simple. Machine-to-machine messaging is SM646's XMPP
    # connectors, not a mailbox grown quietly on the side of this store.
    # t/lint/23 points here rather than recording a reason of its own, because
    # %API_ONLY may only name actions this gate carries.
    'notices' => [qw(notifications)],
    # SM282: seeing what a VISITOR gets for a path you can already read.
    # It renders anonymously, so it can never show more than the public
    # sees - manage_content is the grant that makes the question yours to
    # ask, not a grant to see anything new.
    'preview-public'       => [qw(manage_content)],
    'site-backup-create'   => [qw(manage_domains)],    # SM158
    'site-backup-upload'   => [qw(manage_domains)],
    'site-backup-apply'    => [qw(manage_domains)],
    'site-backup-inspect'  => [qw(manage_domains)],    # SM183
    'site-backup-delete'   => [qw(manage_domains)],    # SM183
    'site-backup-download' => [qw(manage_domains)],    # SM193
    'site-export-primary'  => [qw(manage_content)],    # SM185
        # SM187: agents read form submissions with a least-privilege read_submissions
        # SM652: read_submissions ONLY, on both channels - see the
        # declaration table above. manage_forms is definition-only now, so
        # the sysop parity note that stood here no longer applies.
    'form-submissions' => [qw(read_submissions)],
    'form-submission'  => [qw(read_submissions)],    # SM938 D5: one row of the same
    'form-list'        => [qw(read_submissions)],
    # SM924: DELETING a submission is reachable on this channel now, and only
    # with a grant of its own. SM214 held it back - a destructive act on
    # personal data, often on the only copy - and that reasoning is why the
    # capability is OFF BY DEFAULT rather than why the door stays shut: a
    # partner that could read every submission could delete none, so an agent's
    # own test rows could be cleared only by a person.
    #
    # delete_submissions ALONE, not read_submissions as well. A caller that can
    # delete without reading is a strange shape but a coherent one, and demanding
    # a second grant the ruling did not ask for would be this file deciding
    # policy. The capability's own text says what it permits: ANY submission on
    # the site, because a stored row records no author to narrow it to.
    'form-submission-delete'       => [qw(delete_submissions)],
    'form-submissions-delete-bulk' => [qw(delete_submissions)],
    'form-delete' => [qw(manage_forms)],    # SM632: the inverse of bind_form
        # SM842: handler CRUD on the token channel too, reversing SM799's
        # cookie-only rule - the release manager's ruling that the destination
        # decides, on every surface. See the cookie table for the door.
    'handler-list' => [qw(manage_forms manage_data manage_connectors manage_notifications)], # SM1010 R5
    'handler-save' => [qw(manage_forms manage_data manage_connectors manage_notifications)], # SM1010 R5
    'handler-delete' => [qw(manage_forms manage_data manage_connectors manage_notifications)], # SM1010 R5
    'schedule-list'     => [qw(manage_forms manage_data manage_connectors)],
    'schedule-save'     => [qw(manage_forms manage_data manage_connectors)],
    'schedule-delete'   => [qw(manage_forms manage_data manage_connectors)],
    'form-targets-read' => [qw(manage_forms manage_data manage_connectors)],
    'form-targets-save' => [qw(manage_forms)],
    'form-uploads-save' => [qw(manage_forms)],
    'form-notify-save'  => [qw(manage_forms)],     # SM938 D4: the form's own notify: line
    'bad-url-blocks'    => [qw(manage_config)],    # SM128: blocked-IP list
    'bad-url-block'     => [qw(manage_config)],    # SM704: block by hand
    'bad-url-unblock'   => [qw(manage_config)],
    # SM097: page-URL list for the nav editor. SM568: a content read too,
    # so manage_content admits it - as it does the MCP twin list_pages.
    'pages' => [qw(manage_content manage_nav)],
    # SM123: a theme/layout manager may list what is installed (was previously
    # unavailable to token clients, so they activated each in turn to discover).
    'theme-list'        => [qw(manage_themes manage_layouts)],
    'themes-for-layout' => [qw(manage_themes manage_layouts)],
    'themes-list-all'   => [qw(manage_themes manage_layouts)],
    'layouts-available' => [qw(manage_themes manage_layouts)],
    'layouts-manifest'  => [qw(manage_themes manage_layouts)],
    # SM: a layouts manager may install/remove layouts on demand from the repo.
    'layout-install' => [qw(manage_layouts)],
    'layout-delete'  => [qw(manage_layouts)],
    # SM262: a caller that can create a theme may remove one IT created, and
    # nothing else - enforced in action_theme_delete, which the dispatcher asks
    # for when the caller is a token client ($token_auth). Without this an agent
    # accumulated an experiment per attempt and only the operator could clear
    # them. The manager UI over a cookie session does not take this path and
    # keeps the unrestricted delete: a human at the console is the case the
    # UI-only rule was protecting, and it still is.
    'theme-delete'            => [qw(manage_themes)],
    'artifact-backups-delete' => [qw(purge)],
    # SM105: navigation is a token-client action gated by manage_nav (which
    # inherits manage_content / webdav), so a WebDAV/API partner can read and
    # write the site nav without the MCP connector or raw WebDAV to lazysite/.
    # SM943 ruling 2 (2026-10-09): the STRUCTURED nav read needs no capability
    # beyond the surface's base access - the nav is public - and is the same on
    # both surfaces (read_nav). Its reach is still the caller's own domains
    # (SM976, Manager::Nav). Writing stays manage_nav, as does a WebDAV GET of
    # the raw nav.conf; manage_content grants nothing nav-specific.
    'nav-read' => 'ALWAYS',
    'nav-save' => [qw(manage_nav)],
    # SM1050 (inbox 2026-10-12, P-1..P-3), ruled "Yes, within the delegation
    # limit": a partner provisioning a site's roles lists the groups and
    # creates one, giving it only capabilities it holds (Manager::Groups).
    'groups-list' => [qw(manage_users)],
    'group-set'   => [qw(manage_users)],
    # SM1053: a partner stages an account import for the operator to apply.
    'accounts-import-stage' => [qw(manage_users)],
    # SM134 follow-ups: the alias-redirect map is content-derived - a content
    # partner may list it (read-only; aliases are front-matter-authored).
    'aliases-list' => [qw(manage_content)],
    # SM085: content history. Reads and restore follow the content grant
    # (restore routes through the normal save path); enabling/initialising
    # the repo is a site-configuration act.
    'git-status'          => [qw(manage_content)],
    'git-history'         => [qw(manage_content)],
    'git-history-summary' => [qw(manage_content manage_config)],    # SM199, SM664
    'git-show'            => [qw(manage_content)],
    'git-restore'         => [qw(manage_content)],
    'git-init'            => [qw(manage_config)],
    'whoami' => 'ALWAYS',    # any authenticated token may introspect its own grant
    'describe-capabilities' => 'ALWAYS',    # SM126: introspection - the capability map
    'actions-list'          => 'ALWAYS',    # SM350: introspection - the action reference
        # SM778: resolving logins the caller ALREADY HAS to display names.
        # It answers only for the logins it is given and never lists
        # accounts, so it discloses nothing a caller holding those logins
        # cannot already see - which is why it needs no capability, and
        # why it must never grow a "list them all" mode.
    'display-names' => 'ALWAYS',
    # SM579: any authenticated token may REACH connector-call; the
    # connector then decides (callers groups, or manage_connectors) and
    # refuses by name. The capability tables above hold the configuring
    # actions.
    'connector-call' => 'ALWAYS',
    # Visitor-log analysis over the control API (token clients), same grant as
    # the MCP analyse_visitors tool - so an API-channel agent gets analytics too.
    'analyse_visitors' => [qw(analytics)],
    # The audit trail is its own capability, separate from visitor analytics.
    'audit' => [qw(audit)],
    # SM074: a publishing partner manages ACLs on the content it owns.
    # SM431: and so does a manage_content grant - the MCP twins
    # (get_permissions / set_permissions) sat under manage_content while
    # these needed webdav, so a token that could CREATE gated content
    # could not inspect or set the rule governing it through this door.
    # Per-file authorization (ownership, SM464's read split) is unchanged
    # inside the actions; this is only which grants reach them.
    # SM570: manage_content ONLY. `webdav` is a channel enablement, never
    # an authority - a webdav-only grant cannot PUT content, so it must not
    # read, set or remove the rules that govern content. A themes partner
    # holding webdav for theme uploads reached all three; t/lint/86 now
    # forbids any channel capability in a token gate.
    'acl-get'    => [qw(manage_content)],
    'acl-set'    => [qw(manage_content)],
    'acl-remove' => [qw(manage_content)],
);

# action => { caps, params => [ { name, in } ] }
#
# `caps` IS DERIVED from %GATE above, at the foot of this file - do not declare it
# here. `params` is still EXTRACTED FROM THE CHAIN by hand, because the control API
# dispatches through a 150-branch if/elsif and there is nothing to generate
# parameters from; t/lint/58 re-extracts them from the branches and fails on any
# difference. So a parameter change belongs in lazysite-manager-api.pl and then
# here, and a capability change belongs in %GATE alone.
#
# Replacing the chain with a real table of handlers is what would let `params` be
# declared rather than copied, and it remains its own piece of work.
#
# SM943: EVERY OTHER PER-ACTION FACT THE MANAGER API KEEPS IS DECLARED HERE TOO,
# once, and lazysite-manager-api.pl builds its tables from it through the
# functions at the foot of this file. A field is written only where it differs
# from its default, so most entries stay short:
#
#   mutates => 1               POST-only on both channels (%MUTATING)
#   destructive => 1           no copy survives the call (%DESTRUCTIVE; SM587)
#   changes_access => 1        moves the read boundary (%CHANGES_ACCESS; SM587)
#   audited => 0 | 1           DEFAULT: audited exactly when it mutates. Written
#                              only for the exceptions (the audit %skip list)
#   scoped => 1                the path a dav_scope confines (%SCOPED_ACTION)
#   instance_wide => 1         SM976 R1: it changes a setting, registry or shared
#                              library the whole instance reads, so a
#                              domain-confined caller is refused it before
#                              dispatch, on both doors (MCP's twin too, unless it
#                              was given a host). The closed list t/lint/218
#                              holds every mutating action to
#   file_surface => 'read'|'write'
#                              the carve-out gate's mode (%file_surface)
#   cookie_cap => 'a|b' | 'a+b'
#                              the cookie channel's capability, where it says
#                              something of its own (%COOKIE_CAP): `|` any, `+` all
#   cookie_gates_itself => why the action decides for itself on the cookie
#                              channel (%COOKIE_GATES_ITSELF)
#   cookie_only_reason => why a token client may not call it (%COOKIE_ONLY_REASON)
#   content_write => 1         SM1057 (ruled "Require manage_content"): writes site
#                              content by path, so the cookie channel asks
#                              manage_content before the file's rule (%CONTENT_WRITE)
#   self => 1                  SM1043: the subject is ALWAYS the signed-in caller.
#                              No capability, cookie-only (never in %GATE), and no
#                              parameter may name an account - refused at load
#                              below and by t/lint/246
#   mcp => 'tool_name'         SM943 stage 2: the action's MCP twin - the tool that
#                              does the same thing through the other door. The
#                              twin's readOnly, destructive and changesAccess hints
#                              are DERIVED from this entry (mcp_annotations), so
#                              the two doors cannot describe one act differently
#   mcp_open_world => 1        the twin's openWorldHint: the call publishes to or
#                              changes the live site. MCP's own axis, with no
#                              meaning on the control API, so it is declared
#                              rather than derived - and only beside `mcp`
#
# A comment tagged [field] on an entry is the reason that stood beside it in the
# CGI table it came from. A key not in that list is refused at load, so a
# misspelt field cannot quietly mean its default.
our %ACTION = (
    # [mcp] SM431: the permissions twins, recorded as twins. acl-remove has no
    # named MCP twin (set_permissions with empty lists clears a rule) and
    # passes the completeness check under manage_content like the others.
    # SM1053 (P-5), ruled 2026-10-12, "Operator-run import": a partner stages an
    # account import (no passwords); the operator reviews the dry run and applies
    # it in the manager. Account creation stays a human-at-a-browser act (SM268).
    'accounts-import-apply' => { mutates => 1, cookie_cap => 'manage_users', cookie_only_reason => 'it creates accounts, and SM268 ruled minting credentials a human-at-a-browser act: the operator reviews the dry run and applies it', params => [ { name => 'id', in => 'body' }, { name => 'confirm', in => 'body' } ] },
    'accounts-import-list' => { cookie_cap => 'manage_users', cookie_only_reason => 'the review half of an import, the operator\'s in the manager (SM268)', params => [] },
    'accounts-import-plan' => { cookie_cap => 'manage_users', cookie_only_reason => 'the review half of an import, the operator\'s in the manager (SM268)', params => [ { name => 'id', in => 'query' } ] },
    'accounts-import-stage' => { mutates => 1, cookie_cap => 'manage_users', params => [ { name => 'accounts', in => 'body' }, { name => 'csv', in => 'body' } ] },
    'acl-get' => { mcp => 'get_permissions', scoped => 1, file_surface => 'read', cookie_gates_itself => 'the owner reads their rule, manage_users reads any (SM464, Files::action_acl_get)', params => [ { name => 'path', in => 'query' } ] },
    # [changes_access] see acl-set: one rule, set or cleared.
    'acl-remove' => { mutates => 1, changes_access => 1, scoped => 1, file_surface => 'write', cookie_gates_itself => 'only the owner of a file may remove its rule (Files::action_acl_remove)', params => [ { name => 'path', in => 'query' } ] },
# [changes_access] acl-set / acl-remove   set or clear the rule that decides who may read a
#                          path. acl-set is also the draft/publish pair the
#                          filing names - there is no separate publish verb;
#                          setting `draft` gates the path and clearing it
#                          publishes, so one action carries both directions.
# [mcp] set_permissions: SM587: acl-set's twin - it moves the read boundary
    'acl-set' => { mcp => 'set_permissions', mutates => 1, changes_access => 1, scoped => 1, file_surface => 'write', cookie_gates_itself => 'only the owner of a file may change its rule (Files::action_acl_set)', params => [ { name => 'path', in => 'query_or_body' }, { name => 'read', in => 'body' }, { name => 'write', in => 'body' }, { name => 'owner', in => 'body' }, { name => 'draft', in => 'body' }, { name => 'paths', in => 'body', note => 'SM1052: a list of paths given the one rule, instead of path' } ] },
    'actions-list' => { params => [] },
    # SM576 part 1: the brief store's own capability. A read takes EITHER
    # (the three-state note above: any ONE of the listed caps is enough), so a
    # long-standing manage_content grant keeps reading; a write takes
    # manage_briefs alone.
    # [cookie_cap] SM245: the brief store. SM576 part 1 splits it: WRITING a brief needs
    # manage_briefs (the plugin-declared capability), READING one is
    # admitted by either, so an existing manage_content grant keeps the
    # reads it has always had and loses only the write.
    # [mcp] SM245: the brief store's twins.
    'brief-read' => { mcp => 'read_brief', cookie_cap => 'manage_content|manage_briefs', params => [ { name => 'path', in => 'query', required => 1 } ] },
    # [mcp] append_brief: writes the engine store, changes nothing live
    'brief-append' => { mcp => 'append_brief', mutates => 1, cookie_cap => 'manage_briefs', params => [ { name => 'path', in => 'query', required => 1 }, { name => 'entry', in => 'body', required => 1 } ] },
    'briefs-migrate' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_briefs', params => [] },
    # [mcp] SM508: the lifecycle's discovery and cleanup halves.
    'briefs-list' => { mcp => 'list_briefs', cookie_cap => 'manage_content|manage_briefs', params => [] },
    # [cookie_cap] SM591: no copy survives
    # [mcp] delete_brief: destroys a record; changes nothing live
    'brief-delete' => { mcp => 'delete_brief', mutates => 1, destructive => 1, cookie_cap => 'purge', params => [ { name => 'path', in => 'query' } ] },
    'aliases-list' => { params => [ { name => 'host', in => 'query' }, { name => 'path', in => 'query' } ] },
    'analyse_visitors' => { mcp => 'analyse_visitors', cookie_cap => 'analytics', params => [ { name => 'window', in => 'query' }, { name => 'day', in => 'query' }, { name => 'month', in => 'query' }, { name => 'index', in => 'query' }, { name => 'trails', in => 'query' }, { name => 'host', in => 'query' }, { name => 'by_host', in => 'query' } ] },
    # [cookie_cap] SM591: no copy survives
    'artifact-backups-delete' => { instance_wide => 1, mutates => 1, destructive => 1, cookie_cap => 'purge', params => [ { name => 'path', in => 'query' } ] },
    'artifact-manifest'       => { params => [] },
    'artifact-validate'       => { params => [] },
    'audit' => { cookie_gates_itself => 'create_sub_users without audit gets a scoped view (SM173), not a refusal', params => [ { name => 'user', in => 'query' }, { name => 'target', in => 'query' }, { name => 'start', in => 'query' }, { name => 'end', in => 'query' }, { name => 'page', in => 'query' }, { name => 'per_page', in => 'query' } ] },
    'backup-create' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'scope', in => 'query' } ] },
    # [cookie_cap] SM268 03-F11: removing a snapshot is the same authority as taking or
    # restoring one.
    # SM591 + SM577: the backups store is INSTANCE-wide (package_create
    # writes any configured domain's archive into the local _backups_dir),
    # so this reaches archives of other sites on the same instance. Still
    # cookie-only - SM591 changes WHICH grant reaches it, not whether a
    # token can.
    'backup-delete' => { instance_wide => 1, mutates => 1, destructive => 1, cookie_cap => 'purge', params => [ { name => 'name', in => 'query_or_body' } ] },
    'backup-download' => { audited => 1, cookie_cap => 'manage_config', params => [ { name => 'name', in => 'query' } ] },
    'backup-list' => { cookie_cap => 'manage_config', params => [] },
    # SM874: `replace` is the undo-of-apply mode - the target folder is cleared
    # before the snapshot is written back, so files a package ADDED are removed
    # too. Absent or false keeps the historic overlay behaviour.
    'backup-restore' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params =>
            [ { name => 'name', in => 'query' }, { name => 'replace', in => 'query' } ] },
    'bad-url-blocks' => { cookie_cap => 'manage_config', params => [] },
    'bad-url-block' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'ip', in => 'query' } ] },
    'bad-url-unblock' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'ip', in => 'query' } ] },
    'cache-invalidate' => { mutates => 1, audited => 0, scoped => 1, params => [ { name => 'path', in => 'query' }, { name => 'host', in => 'query' } ] },
    'cache-list'       => { params => [] },
    'channel-services' => { params => [] },
    'config-read'      => { cookie_cap => 'manage_config', params => [] },
    'config-set' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'key', in => 'query_or_body', required => 1 }, { name => 'value', in => 'query_or_body' } ] },
    'copy' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
    'csrf-token' => { params => [] },

    # SM447: the data tables. EXTRACTED from the dispatch chain, like every
    # entry here - t/lint/58 re-extracts and fails on any difference, so this
    # is a fourth list that cannot drift.
    #
    # NOTE `in => 'query'` throughout: this field records HOW THE CHAIN READS
    # the parameter (%params, populated from either source), not which HTTP
    # method is allowed. The three writers are POST-forced via %MUTATING and
    # t/lint/14 asserts it.
    #
    # `row` is a JSON OBJECT in one parameter rather than loose fields,
    # deliberately: a descriptor may declare a field called `table` or `key`,
    # and flattening the row into the query would make the site's own data
    # collide with the action's own parameters.
    # [mcp] migrate_data_table: applies the safe changes to the live table
    'data-migrate' => { mcp => 'migrate_data_table', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' } ] },
    # [mcp] rebuild_data_table: drops columns, by named confirmation
    'data-rebuild' => { mcp => 'rebuild_data_table', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query_or_body' }, { name => 'confirm_lost', in => 'body' } ] },
    'data-row-delete' => { mcp => 'delete_data_row', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_data|write_data', params => [ { name => 'table', in => 'query_or_body' }, { name => 'key', in => 'query_or_body' } ] },
    # [cookie_cap] SM682: either capability reaches a ROW write; the descriptor's
    # writable_by then decides, and means different things to the two.
    'data-row-save' => { mcp => 'save_data_row', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_data|write_data', params => [ { name => 'table', in => 'query_or_body' }, { name => 'key', in => 'query_or_body' }, { name => 'row', in => 'body' } ] },
    'data-rows' => { mcp => 'read_data_rows', cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' }, { name => 'order_by', in => 'query' }, { name => 'order', in => 'query' }, { name => 'limit', in => 'query' }, { name => 'offset', in => 'query' } ] },
    'data-table' => { mcp => 'describe_data_table', cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' } ] },
    # [mcp] SM566: the safety step and the descriptor as text. Both were API-only
    # with reasons written when the plugin was new; an agent could migrate a
    # table without previewing what the migration would refuse.
    'data-table-source' => { mcp => 'read_data_table_source', cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' } ] },
    'data-migrate-plan' => { mcp => 'plan_data_migration', cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' } ] },
    # SM687: a table's access rule. Gated on manage_content, matching a file's
    # rule rather than inventing a separate policy for tables - reaching the
    # Data page needs manage_data too, so in practice a person holds both.
    # [cookie_cap] SM687: who may read a table is an access rule, so it takes the
    # capability that governs access rules - the same one a file's rule
    # takes - rather than manage_data alone. Reaching the Data page needs
    # manage_data too, so in practice a person holds both.
    'data-table-acl-get' => { cookie_cap => 'manage_content', params => [ { name => 'table', in => 'query' } ] },
    'data-table-acl-set' => { mutates => 1, cookie_cap => 'manage_content', params => [ { name => 'table', in => 'query_or_body' },
            { name => 'owner', in => 'body' },
            { name => 'read',  in => 'body' },
            { name => 'write', in => 'body' } ] },
    'data-table-acl-remove' => { mutates => 1, cookie_cap => 'manage_content', params => [ { name => 'table', in => 'query' } ] },
    # [mcp] save_data_table: a descriptor's public flag decides what the site serves
    'data-table-save' => { mcp => 'save_data_table', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query_or_body' }, { name => 'descriptor', in => 'body' } ] },
    'data-import' => { mutates => 1, cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' }, { name => 'apply', in => 'query' } ] },
    'data-export' => { audited => 1, cookie_cap => 'manage_data', params => [ { name => 'table', in => 'query' }, { name => 'format', in => 'query' } ] },
    # [cookie_cap] SM591: the lateral tiers. The module capability carries the working
    # verbs; destroying inside the module is its own grant, assigned by
    # SM587's copy test - a drop mints a safety export, so it is the
    # recoverable tier; deleting that export is what makes the drop
    # permanent, so it is the irreversible one.
    'data-table-drop' => { mcp => 'drop_data_table', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'housekeeping', params => [ { name => 'table', in => 'query_or_body' }, { name => 'confirm', in => 'body' } ] },
    # [cookie_cap] SM160: domains + the portable site-package family are their own
    # capability (manage_domains), carved out of the broad manage_config.
    # SM447: the data plugin's capability. Reads and writes alike -
    # unlike content, a table row has no per-file ACL to self-authorize
    # against, so the capability IS the gate.
    # [mcp] SM447: the data tables. Both channels, one implementation - each pair
    # routes through Lazysite::Manager::Data, so a difference between them
    # would have to be introduced deliberately.
    'data-tables' => { mcp => 'list_data_tables', cookie_cap => 'manage_data', params => [] },
    # [mcp] SM512: the safety exports, listed and cleared - the SM508 pattern for tables.
    'data-safety-exports' => { mcp => 'list_data_safety_exports', cookie_cap => 'manage_data', params => [] },
    # [mcp] delete_data_safety_export: destroys the only copy of dropped rows
    'data-safety-export-delete' => { mcp => 'delete_data_safety_export', mutates => 1, destructive => 1, cookie_cap => 'purge', params => [ { name => 'file', in => 'query_or_body' } ] },
    'data-safety-export-read' => { mcp => 'read_data_safety_export', cookie_cap => 'manage_data', params => [ { name => 'file', in => 'query' } ] },
    # [mcp] restore_data_safety_export: writes rows into a live table
    'data-safety-export-restore' => { mcp => 'restore_data_safety_export', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_data', params => [ { name => 'file', in => 'query_or_body' }, { name => 'apply', in => 'query_or_body' } ] },
    'delete' => { mutates => 1, content_write => 1, destructive => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'describe-capabilities' => { params => [] },

    # SM778: resolve logins the caller ALREADY HOLDS to display names. No
    # capability beyond being signed in, because it answers only for the logins
    # it is given: it is not a listing of accounts and must never become one.
    # [mcp] SM778: added to both surfaces at once, which is the point - the site that
    # needed it is a token client, and the manager screens that carry names are
    # cookie-only.
    # [mcp] display_names: SM778: a read, and it touches nothing
    'display-names' => { mcp => 'display_names', params => [ { name => 'logins', in => 'query_or_body', required => 1, note => 'an array of logins in the body, or a comma-separated list in the query' } ] },
    # SM217: no content_root parameter, deliberately - the whole point is that the
    # shared root is READ from the canonical domain. A caller that could supply
    # it could supply the wrong one, which is the hand-copying mistake this
    # action exists to remove.
    'domain-alias-add' => { mutates => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'body' }, { name => 'alias_of', in => 'body' }, { name => 'site_url', in => 'body' }, { name => 'site_name', in => 'body' }, { name => 'theme', in => 'body' }, { name => 'layout', in => 'body' }, { name => 'nav_file', in => 'body' }, { name => 'search_default', in => 'body' }, { name => 'lang', in => 'body' }, { name => 'lang_group', in => 'body' } ] },
    'domain-add' => { mutates => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'body' }, { name => 'content_root', in => 'body' }, { name => 'site_url', in => 'body' }, { name => 'site_name', in => 'body' }, { name => 'theme', in => 'body' }, { name => 'layout', in => 'body' }, { name => 'nav_file', in => 'body' }, { name => 'search_default', in => 'body' }, { name => 'lang', in => 'body' }, { name => 'lang_group', in => 'body' }, { name => 'allowed_groups', in => 'body' }, { name => 'seed', in => 'body' } ] },
    'domain-check' => { cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'query' } ] },
    'domain-preview' => { mcp => 'preview_domain', cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'query' } ] },
    'domain-remove' => { mutates => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'body' }, { name => 'purge', in => 'body' } ] },
 # [changes_access] domain-set             writes a domain's `allowed_groups` - the domain
 #                          access model itself, which is what decides which
 #                          groups reach that domain's content. SM647: it was
 #                          absent, so the one flag a caller can consult said
 #                          `false` about the action in this group that moves
 #                          the broadest boundary.
 # [mcp] domain_set: SM647: the fourth slot. domain_set writes allowed_groups - the domain
 # access model - so it moves the read boundary as surely as set_permissions
 # does, and the twin table on the control API says so now too.
    'domain-set' => { mcp => 'domain_set', mcp_open_world => 1, mutates => 1, changes_access => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'body' }, { name => 'key', in => 'body' }, { name => 'value', in => 'body' } ] },
    # SM802: the URL remapper - per-host rules, operator-only.
    # [cookie_cap] SM802
    'remap-list' => { cookie_cap => 'manage_domains', params => [] },
    # [cookie_cap] SM802
    'remap-save' => { mutates => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'body', required => 1 }, { name => 'rules', in => 'body', required => 1 } ] },
# N13-04: the audit trail's switch - audit_switch AND manage_config (the second checked in the dispatch).
# [cookie_cap] N13-04: AND manage_config, in the dispatch
    'audit-trail-set' => { instance_wide => 1, mutates => 1, audited => 0, cookie_cap => 'audit_switch', params => [ { name => 'state', in => 'body', required => 1 }, { name => 'reason', in => 'body' } ] },
    'domains-list' => { mcp => 'list_domains', cookie_cap => 'manage_domains', params => [] },
    # [file_surface] SM517: the two download verbs reached the same files through a
    # different door. Neither was here, so a manage_content-only account
    # on a secured site was refused `read` of the submission store and
    # nav.conf and then downloaded both - the SM418 defect in its
    # read-side form. The zip is gated over every requested path below.
    'file-download' => { audited => 1, scoped => 1, file_surface => 'read', params => [ { name => 'path', in => 'query' } ] },
    # [file_surface] SM418: the DISPATCHED action name, which is 'file-upload'. Keyed
    # 'upload' this lookup was always undef, so the carve-out gate never
    # ran for a single upload - an unscoped manage_content account could
    # upload onto lazysite/nav.conf without manage_nav, and into the form
    # submission store, which are the exact bypasses SM268 H4 closed on
    # every other verb.
    'file-upload' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'file-zip-download' => { audited => 1, scoped => 1, file_surface => 'read', params => [] },
    # SM652: read_submissions ONLY, on both channels - form-list returns
    # row_count, which is a read of submission EXISTENCE.
    # [cookie_cap] SM214: names + submission COUNTS
    # SM979: OR approve_accounts, which the dispatcher shows only the forms that
    # declare account_email (Manager::Plugins::account_request_store).
    'form-list' => { mcp => 'form_list', cookie_cap => 'read_submissions|approve_accounts', params => [] },
    # [cookie_cap] SM216, SM660
    'form-submission-confirm' => { mutates => 1, cookie_cap => 'manage_forms+read_submissions', params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    # [cookie_cap] SM660: BOTH capabilities. SM652 narrowed the submission READS to
    # read_submissions and left these three behind, so a grant could delete
    # a submission row and clear a quarantine flag while being unable to
    # read either - destroying personal data it may not see, often the only
    # copy. You may not destroy what you may not see.
    #
    # No control starts refusing: reaching these buttons means opening the
    # submissions viewer, which needs form-submissions, which SM652 already
    # gated on read_submissions. Anyone who can see a row holds it. What
    # this closes is the direct call that never read anything.
    # [cookie_cap] SM187, SM660
    'form-submission-delete' => { mutates => 1, destructive => 1, cookie_cap => 'manage_forms+read_submissions', params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    # SM652: manage_forms is definition-only now; reading a submission needs
    # the least-privilege capability built for it.
    # SM862: `form` is the one to reach for - it is what the MCP twin and
    # form-targets-read take - and `file` stays for a store named by path.
    # Neither is marked required: exactly one is needed, and the action answers
    # for that by name rather than letting the path validator call an absence a
    # malformed value.
    # [cookie_cap] SM938 D5: one of them, by id
    # [mcp] read_form_submission: SM938 D5
    # SM979: OR approve_accounts, for a row of an account-request form only.
    'form-submission' => { mcp => 'read_form_submission', cookie_cap => 'read_submissions|approve_accounts', params => [ { name => 'file', in => 'query', required => 1, note => 'the store the row is in, as a submission notice\'s link and the table give it' }, { name => 'id', in => 'query', required => 1, note => '16 hex characters: the row\'s id' } ] },
    # [cookie_cap] SM652: read_submissions ONLY, so the two channels agree about who may
    # read a submission. MCP has required it for both since it was written;
    # the control API also accepted manage_forms, and the divergence was
    # documented on the surface that does NOT implement it, in the
    # description of the other tool. An operator's expectation was set by
    # whichever surface they happened to read.
    #
    # form-list is included because it returns row_count - whether a form
    # has submissions and how many - which is a read of submission
    # EXISTENCE even though it carries no content. MCP treats it that way
    # and always has.
    # [cookie_cap] SM182/SM187: PII submissions (GET)
    # SM979: OR approve_accounts - an account request is what approving reads,
    # so a holder reads the store of a form that declares account_email and
    # no other. The dispatcher confines it (account_request_store).
    'form-submissions' => { mcp => 'read_form_submissions', cookie_cap => 'read_submissions|approve_accounts',
        params => [
            { name => 'form', in => 'query',
                note => 'the form\'s name; its store is resolved from the handler it binds to' },
            { name => 'file', in => 'query',
                note => 'the path to a .jsonl store, when naming one directly; `form` is preferred' },
        ],
    },
    # SM858: approve an account from a stored submission. It reads the row and
    # creates an account. A delegate holding create_sub_users may not, as on
    # the Users API. No %GATE line: cookie-only, see the reason.
    #
    # SM979 (ruled 2026-10-11, "New approve capability"): approve_accounts is
    # enough. It was manage_users AND read_submissions, and manage_users is the
    # operator - it passes every gate on this channel - so the group made to
    # approve requests held the whole manager. manage_users stays accepted, so
    # a group that approved before still does.
    'form-submission-approve' => { mutates => 1, changes_access => 1,
        cookie_cap => 'approve_accounts|manage_users',
        cookie_only_reason => 'it creates an account for a person nobody has met, and SM268 ruled minting credentials a human-at-a-browser act - an operator looks at the submission and decides',
        params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    # [cookie_cap] SM187, SM660
    'form-submissions-delete-bulk' => { mutates => 1, destructive => 1, cookie_cap => 'manage_forms+read_submissions', params => [ { name => 'file', in => 'query_or_body' }, { name => 'ids', in => 'body' } ] },
    # SM842: a form's targets name handlers and nothing else, on the token
    # channel as on every other.
    'form-targets-read' => { cookie_cap => 'manage_forms|manage_data|manage_connectors', params => [ { name => 'form', in => 'query', required => 1 } ] },
    # [mcp] SM842: the handler contract on both surfaces at once - handler CRUD
    # reversed SM799's cookie-only rule, and bind_form stopped being MCP-only
    # now that form-targets-save takes handler ids and nothing else.
    'form-targets-save' => { mcp => 'bind_form', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_forms', params => [ { name => 'form', in => 'query_or_body', required => 1 }, { name => 'handlers', in => 'body', note => 'a list of handler ids; `targets` as [{handler: id}] is read the same way' }, { name => 'targets', in => 'body' } ] },
# [mcp] SM905 U5: on both surfaces at once, because the caller it was built for is
# an agent - the edge walk hit the wall it removes while working over the API.
# [mcp] set_form_uploads: SM905 U5: a save, and not destructive - `uploads: false` removes the
# upload_* keys, but another call puts them back, and the rule above is
# explicit that a flag is a property of the action, never of an argument.
    'form-uploads-save' => { mcp => 'set_form_uploads', mcp_open_world => 1, mutates => 1, params => [ { name => 'form', in => 'query_or_body', required => 1 }, { name => 'uploads', in => 'body', note => 'on turns file uploads on for this form; off removes every upload_* key. A JSON boolean, 1/0, or "true"/"on"/"yes"' }, { name => 'max_kb', in => 'body', note => 'per FILE, default 5120' }, { name => 'max_files', in => 'body', note => 'per submission, default 5' }, { name => 'accept', in => 'body', note => 'file EXTENSIONS, comma-separated - `png, jpg, pdf`. Not a media type: the page grammar\'s accept: rule is the media-type one' } ] },
    # [mcp] set_form_notify: SM938 D4: a save; another call puts it back
    'form-notify-save' => { mcp => 'set_form_notify', mcp_open_world => 1, mutates => 1, params => [ { name => 'form', in => 'query_or_body', required => 1 }, { name => 'notify', in => 'body', required => 1, note => 'off (no notice), on (one line) or full (the notice carries the submission). The reply carries `announces`: where a submission notice now goes, and what stops it where it does not' } ] },
    'git-history' => { mcp => 'list_versions', scoped => 1, file_surface => 'read', cookie_cap => 'manage_content', params => [ { name => 'path', in => 'query' }, { name => 'limit', in => 'query' } ] },
    # SM664: reachable with either - the overview sits on the Plugin Config
    # page, whose audience holds manage_config, and is a reporting read.
    # [cookie_cap] SM664: the overview moved to the content-history plugin's row on the
    # Plugin Config page, whose audience holds manage_config. Either
    # capability reads it - a reporting read reachable from either the app
    # that writes the content or the page that configures the plugin.
    # [cookie_cap] SM199, SM664
    'git-history-summary' => { mcp => 'list_content_history', cookie_cap => 'manage_content|manage_config', params => [] },
    'git-init' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [] },
    'git-restore' => { mcp => 'restore_version', mcp_open_world => 1, mutates => 1, scoped => 1, file_surface => 'write', cookie_cap => 'manage_content', params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-show' => { mcp => 'view_version', scoped => 1, file_surface => 'read', cookie_cap => 'manage_content', params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-status' => { scoped => 1, cookie_cap => 'manage_content', params => [] },
    # [mcp] SM1050: list_groups / set_group, the twins, built on one module
    # (Lazysite::Manager::Groups) so the doors cannot disagree.
    'group-set' => { mcp => 'set_group', mutates => 1, cookie_cap => 'manage_users', params => [ { name => 'group', in => 'body', required => 1 }, { name => 'caps', in => 'body' } ] },
    'groups-list' => { mcp => 'list_groups', cookie_cap => 'manage_users', params => [] },
    # SM632: the inverse of bind_form. Gated on manage_forms for a token, and
    # confirmation names the form - a destructive verb taking only an id is one
    # an agent fires by having the wrong id.
# [mcp] SM632: the inverse of bind_form, added to both surfaces at once. bind_form
# is MCP-only by long standing (the API writes the conf directly), so the
# DESTROY is the first half of that pair to exist on both - which is the
# right way round: a create with no undo is what left a registration on a
# live site that nobody with a token could remove.
# [mcp] delete_form: SM632: destroys a registration; the twin form-delete is in %DESTRUCTIVE.
# Not idempotent in the third slot's sense - a second call finds nothing to
# remove and says so, which is a different answer, not the same one again.
    'form-delete' => { mcp => 'delete_form', mutates => 1, destructive => 1, cookie_cap => 'manage_forms', # Exactly data-table-drop's shape: the OBJECT may come either way, the
            # CONFIRMATION is body-only. Declaring `form` as body-only was wrong -
            # the dispatch reads `$req->{form} // $params{form}` - and t/lint/58
            # extracts the branch rather than trusting this table, so it said so.
        params => [ { name => 'form', in => 'query_or_body' },
            { name => 'confirm', in => 'body' } ] },
    # SM842: handler CRUD reaches the token channel, reversing SM799's
    # cookie-only rule. Any of the three destination capabilities opens the
    # door; the handler's type then decides (Lazysite::Handlers::cap_for_type).
    # [mcp] delete_handler: refused while in use, so nothing live changes
    # SM1051 (P-4), ruled 2026-10-12, "Domain-scoped handlers": no longer
    # instance_wide - a handler may carry `domain:`, and the branch asks the
    # domain rule (Manager::Common::handler_reach_refusal): a confined caller
    # saves and deletes only its own domains' handlers; an instance handler (no
    # domain) is still refused to it, as instance_wide refused it.
    'handler-delete' => { mcp => 'delete_handler', mutates => 1, destructive => 1, cookie_cap => 'manage_forms|manage_data|manage_connectors|manage_notifications', params => [ { name => 'id', in => 'body', required => 1 } ] },
    # [cookie_cap] SM842: the door to the handler actions opens for any of the three
    # destination capabilities; Lazysite::Handlers then decides by the
    # handler's type (a table handler needs manage_data, a connector
    # handler manage_connectors, email and file manage_forms). Binding a
    # form to a handler that exists is manage_forms alone.
    'handler-list' => { mcp => 'list_handlers', cookie_cap => 'manage_forms|manage_data|manage_connectors|manage_notifications', params => [] },
    # [mcp] save_handler: a bound handler's destination is live delivery
    'handler-save' => { mcp => 'save_handler', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_forms|manage_data|manage_connectors|manage_notifications', params => [ { name => 'id', in => 'body', required => 1 }, { name => 'type', in => 'body', required => 1, note => 'smtp, file, table or connector; handler-list returns each type\'s fields' }, { name => 'name', in => 'body', required => 1 }, { name => 'enabled', in => 'body' }, { name => 'domain', in => 'body', note => 'SM1051: a configured domain the handler belongs to; omit for an instance handler' } ] },
    'schedule-list' => { mcp => 'list_schedule', cookie_cap => 'manage_forms|manage_data|manage_connectors', params => [] },
    # [mcp] save_schedule: what the timer calls
    'schedule-save' => { instance_wide => 1, mcp => 'save_schedule', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_forms|manage_data|manage_connectors', params => [ { name => 'id', in => 'body', required => 1 }, { name => 'handler', in => 'body', required => 1 }, { name => 'every', in => 'body', required => 1, note => 'seconds, at least 300' }, { name => 'payload', in => 'body', note => 'a flat object of fixed fields' }, { name => 'enabled', in => 'body' } ] },
    'schedule-delete' => { instance_wide => 1, mcp => 'delete_schedule', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_forms|manage_data|manage_connectors', params => [ { name => 'id', in => 'body', required => 1 } ] },
    'key-revoke' => { mutates => 1, params => [] },
    'keys-list'       => { params => [] },
    # [cookie_cap] SM179 P6: read-only set coverage (a translation agent's cap)
    'lang-status' => { cookie_cap => 'manage_content', params => [ { name => 'group', in => 'query' } ] },
    # SM920: `layout` ALONE. `path` was the generic spelling and took precedence
    # over it, so a caller sending both had the specific one dropped in silence.
    'layout-activate' => { instance_wide => 1, mcp => 'activate_layout', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_layouts', params => [ { name => 'layout', in => 'query', required => 1 }, { name => 'theme', in => 'query' }, { name => 'host', in => 'query', note => 'SM976 F4: a configured domain to bind the layout to, instead of the instance' } ] },
    # SM911 LD2: `layout` is the spelling its siblings take and the one a partner
    # tries; `path` is what the dispatcher had always passed, and stays.
    'layout-delete' => { instance_wide => 1, mcp => 'delete_layout', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_layouts', params => [ { name => 'layout', in => 'query' }, { name => 'path', in => 'query' } ] },
    'layout-install' => { instance_wide => 1, mcp => 'install_layout', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_layouts', params => [] },
    'layouts-available' => { params => [] },
    'layouts-install' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_layouts', params => [] },
    'layouts-manifest'         => { mcp    => 'list_layout_catalogue', params => [] },
    'layouts-release-contents' => { params => [ { name => 'tag', in => 'query' } ] },
    'layouts-releases'         => { params => [] },
    'layouts-repo-get'         => { params => [] },
    'layouts-repo-set' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_layouts', params => [ { name => 'value', in => 'body' } ] },
    'list' => { scoped => 1, file_surface => 'read', params => [ { name => 'path', in => 'query' } ] },
    'lock' => { mutates => 1, content_write => 1, audited => 0, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'migrate-to-local' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'mkdir' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'move' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
    'nav-read' => { mcp => 'read_nav', params => [ { name => 'host', in => 'query' } ] }, # SM568
    'nav-save' => { mcp => 'set_nav', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_nav', params => [ { name => 'items', in => 'body' }, { name => 'host', in => 'query_or_body' } ] },
    # [mcp] SM918: the notice bell, read by both doors through one reader
    # (Lazysite::Manager::Notices). Same capability either side - `notifications`
    # - because the ruling was that the capability is the gate and not the
    # channel. Its `notices-seen` half is one-sided on purpose; the reason is
    # recorded above rather than left as "undecided".
    # [mcp] read_notices: SM918: reads the bell; writes nothing, not even a cursor
    'notices'      => { mcp => 'read_notices', params => [] },
    'notices-seen' => { mutates => 1, # SM938 D3: one notice, or dismiss it; neither = all
        params => [ { name => 'id', in => 'query' }, { name => 'dismiss', in => 'query' } ] },
    # SM732: the PDF render, which SM706 shipped with no caller at all.
    # manage_content because converting a page is reading it in another format -
    # the plugin's own reasoning, and the reason it declares no capability.
    # [scoped] SM978 (ruled 2026-10-10, "Scope it + composed parts"): path-scoped
    # as preview is, so a caller confined to one domain is refused another's page
    # before the plugin loads; read on the file surface for the same reason.
    'page-pdf' => { mutates => 1, scoped => 1, file_surface => 'read', cookie_cap => 'manage_content', params => [ { name => 'path', in => 'query' } ] },
    'pages' => { mcp => 'list_pages', params => [] },    # SM568
    'plugin-action' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'action_id', in => 'body' }, { name => 'params', in => 'body' } ] },
    'plugin-disable' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'script', in => 'body' } ] },
    'plugin-enable' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'script', in => 'body' } ] },
    'plugin-list'    => { params => [] },
    'plugin-read' => { cookie_cap => 'manage_config', params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' } ] },
    'plugin-save' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'values', in => 'body' } ] },
    'preview' => { scoped => 1, file_surface => 'read', params => [ { name => 'path', in => 'query' } ] },
    'preview-clear' => { mutates => 1, audited => 0, cookie_cap => 'manage_themes|manage_layouts', params => [] },
# [changes_access deliberately unset] SM649: preview-grant and preview-clear are NOT here, and were. The comment
# that justified them said a preview "lets somebody read a page"; it does not.
# check_preview() returns { layout, theme } and overrides how a page is
# RENDERED - a preview cookie does not bypass `auth: required`, an ACL or a
# draft, which t/integration/52 now proves rather than asserts. Over-flagging
# points a reviewer at a door that is not there and spends the credibility of
# the flag, which is part of why domain-set's absence was easy to miss: the
# same table was wrong in both directions at once.
    'preview-grant' => { mutates => 1, audited => 0, cookie_cap => 'manage_themes|manage_layouts', params => [] },
    # [mcp] SM466: the existing preview-public action, given an MCP door so the field
    # can confirm what a visitor receives without stepping outside the grant.
    'preview-public' => { mcp => 'preview_public_page', params => [ { name => 'path', in => 'query' } ] },
    # [cookie_cap] F3 audit: the account/group roster backs the ACL "grant to whom" picker
    # (Files, manage_content) and the domain-groups picker (Domains,
    # manage_domains). Gate it to those callers so a user with no
    # grant-related capability cannot enumerate every username/group.
    'principals' => { cookie_cap => 'manage_content|manage_domains', params => [] },
    # [cookie_cap] SM267: the Protected sections list names ACL prefixes and their read
    # lists, which is the same disclosure acl-get carries per file - so it
    # takes the same capability, and the response is scope-filtered on top.
    'protected-sections' => { cookie_cap => 'manage_content', params => [ { name => 'path', in => 'query' } ] },
    'read' => { scoped => 1, file_surface => 'read', params => [ { name => 'path', in => 'query' } ] },
    'recent-changes'        => { params => [ { name => 'window', in => 'query' } ] },
    # [mcp] SM301: was an MCP-only entry whose recorded reason was "the API path can
    # add one when someone asks for it". A live site asked, having taken its own
    # sitemap.xml down by deleting the generated file for want of this.
    'regenerate-registries' => { mcp => 'regenerate_registries', mcp_open_world => 1, mutates => 1, audited => 0, params => [] },
    'renew-lock' => { mutates => 1, content_write => 1, audited => 0, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'rotate-auth-secret' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_config', cookie_only_reason => 'rotating the signing secret invalidates every live session, including the caller\'s own, so it is done by a human who can see what breaks', params => [] },
    'save' => { mutates => 1, content_write => 1, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' }, { name => 'content', in => 'body' }, { name => 'mtime', in => 'body' } ] },
    'session-revoke' => { mutates => 1, params => [] },
    'sessions-list'     => { params => [] },
# [destructive] SM572 follow-through: site-backup-apply REPLACES the live content tree with
# the package's - MCP has always annotated its twin (site_apply) as
# destructive, and the two tables disagreed until the twin check compared them.
# [mcp] site_apply: overwrites the live content tree
    'site-backup-apply' => { mcp => 'site_apply', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_domains', params => [] },
    # [mcp] site_backup: writes an archive; changes nothing live
    'site-backup-create' => { mcp => 'site_backup', mutates => 1, cookie_cap => 'manage_domains', params => [ { name => 'host', in => 'query_or_body' }, { name => 'data_tables', in => 'body' } ] },
    # [cookie_cap] SM183: remove a package
    'site-backup-delete' => { mutates => 1, destructive => 1, cookie_cap => 'manage_domains', params => [ { name => 'name', in => 'query_or_body', required => 1 } ] },
    # [cookie_cap] SM193: token-client package download
    'site-backup-download' => { audited => 1, cookie_cap => 'manage_domains', params => [ { name => 'name', in => 'query_or_body' } ] },
    # [cookie_cap] SM183: read a package manifest (no apply)
    'site-backup-inspect' => { cookie_cap => 'manage_domains', params => [ { name => 'name', in => 'query' }, { name => 'host', in => 'query' } ] },
    'site-backup-upload' => { mutates => 1, cookie_cap => 'manage_domains', params => [] },
    # [cookie_cap] SM185: package the DEFAULT site (no domains feature needed)
    'site-export-primary' => { mutates => 1, cookie_cap => 'manage_content', params => [ { name => 'data_tables', in => 'body' } ] },
    # SM920: `theme` ALONE, for the same reason layout-activate takes `layout`.
    'theme-activate' => { instance_wide => 1, mcp => 'activate_theme', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_themes', params => [ { name => 'theme', in => 'query', required => 1 }, { name => 'host', in => 'query', note => 'SM976 F4: a configured domain to bind the theme to, instead of the instance' } ] },
    # [mcp] copy_theme: SM749: a copy changes nothing live
    'theme-copy' => { mcp => 'copy_theme', mcp_open_world => 1, mutates => 1, cookie_cap => 'manage_themes', params => [ { name => 'path', in => 'query', required => 1 }, { name => 'new_name', in => 'body', required => 1 }, { name => 'layout', in => 'body' } ] },
    # [mcp] SM262: paired, but NOT identical - the MCP tool is always restricted to
    # themes the caller created, while the API action restricts only for token
    # clients and leaves the manager UI's cookie session unrestricted. Same
    # action, two channels, one of which can have a human behind it.
    'theme-delete' => { mcp => 'delete_theme', mcp_open_world => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_themes', params => [ { name => 'path', in => 'query' } ] },
    'theme-list'        => { params => [] },
    'theme-upload' => { mutates => 1, cookie_cap => 'manage_themes', params => [ { name => 'filename', in => 'query' } ] },
    'themes-for-layout' => { params => [ { name => 'layout', in => 'query' } ] },
    'themes-list-all'   => { mcp    => 'list_themes', params => [] },
    'unlock' => { mutates => 1, content_write => 1, audited => 0, scoped => 1, file_surface => 'write', params => [ { name => 'path', in => 'query' } ] },
    'user-revoke' => { mutates => 1, params => [] },
    # [cookie_cap] SEC-2026-07 (C1): the account-management action requires a user-mgmt
    # capability to be reached at all - a content-only account could
    # previously reset any password (incl. the admin's). A delegated
    # sub-manager (create_sub_users) is then confined to its own sub-tree by
    # the actor logic in the users tool.
    'users' => { audited => 1, cookie_cap => 'manage_users|create_sub_users|delegate_sub_user_creation', params => [] },
    'version'           => { params => [] },
    # SM671: `plugins=0` omits the plugin catalogue, which is 82% of the answer
    # on a bare site. Opt-out rather than opt-in, so an existing client reading
    # `plugins` keeps seeing it.
    # SM579: connectors. connector-call's caps are undef because the CONNECTOR
    # gates it (callers groups or manage_connectors) - see Connectors::may_call.
    # [cookie_cap] SM579: see the cookie table; connector-call is gated by the connector.
    'connector-list' => { cookie_cap => 'manage_connectors', params => [] },
    'connector-save' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_connectors', params => [ { name => 'id', in => 'body' }, { name => 'connector', in => 'body' } ] },
    'connector-secret-set' => { instance_wide => 1, mutates => 1, cookie_cap => 'manage_connectors', params => [ { name => 'id', in => 'body', required => 1 }, { name => 'secret', in => 'body', required => 1 } ] },
    'connector-delete' => { instance_wide => 1, mutates => 1, destructive => 1, cookie_cap => 'manage_connectors', params => [ { name => 'id', in => 'body', required => 1 } ] },
    # SM781: caps => [] - NO capability, not "cookie-only". undef here means
    # the cookie channel alone serves the action, and connector-call is
    # served on every channel (gate 'ALWAYS'); the field found it working and
    # missing from actions-list, and SM779's map would have marked it
    # cookie_only. The connector gates it (Connectors::may_call).
# [mcp] SM579 phase 2: calling gets a twin because it IS mode 2 - an
# authenticated caller, gated by the connector itself. Configuring does
# not; see %API_ONLY.
# [mcp] connector_call: SM579: openWorld, and the only tool here that is. A connector call
# leaves this instance; that is the whole point of it, and the hint says so.
    'connector-call' => { mcp => 'connector_call', mcp_open_world => 1, mutates => 1, params => [ { name => 'id', in => 'body' }, { name => 'payload', in => 'body' }, { name => 'row', in => 'body', note => 'a row key: the connector\'s row_map decides which of its columns are sent' } ] },
    'connector-calls' => { cookie_cap => 'manage_connectors', params => [ { name => 'connector', in => 'query' }, { name => 'state', in => 'query' }, { name => 'limit', in => 'query' } ] },
    # SM1043 (SM1034 phase 1a): the member's own account. `self` - the subject
    # is the signed-in caller and nothing else, no parameter names an account
    # (t/lint/246), and no capability is needed or granted. Cookie-only: these
    # are a person's own credentials and sessions, the state SM918 ruled out of
    # the token door. Lazysite::Manager::Account.
    'me' => { self => 1, cookie_only_reason => 'it describes the signed-in person\'s own account', params => [] },
    'me-password' => { self => 1, mutates => 1, cookie_only_reason => 'a person changes their own password in their own session, re-authenticated with the current one', params => [ { name => 'current_password', in => 'body' }, { name => 'new_password', in => 'body', required => 1 } ] },
    'me-sessions' => { self => 1, cookie_only_reason => 'it lists the signed-in person\'s own sessions', params => [] },
    'me-session-revoke' => { self => 1, mutates => 1, cookie_only_reason => 'a person ends one of their own sessions', params => [ { name => 'sid', in => 'body', required => 1, note => 'one of your own session ids, from me-sessions' } ] },
    'me-sign-out-everywhere' => { self => 1, mutates => 1, cookie_only_reason => 'a person ends every session of their own account', params => [] },
    # SM1034 phase 1b (SM1010 R2): the member's own bell - only the notices
    # addressed to the caller, never a broadcast; no capability.
    'me-notices' => { self => 1, cookie_only_reason => 'it is the signed-in person\'s own bell', params => [] },
    'me-notices-seen' => { self => 1, mutates => 1, cookie_only_reason => 'it is the signed-in person\'s own read state, which SM918 kept off the token door', params => [ { name => 'id', in => 'body', note => 'one of your notices, from me-notices; without it, all are marked read' }, { name => 'dismiss', in => 'body' } ] },
    # SM1042 (SM1034 phase 1c, ruled "Self-enrol only"): the member's own two-
    # factor. The secret and the recovery codes go to the account they protect
    # and nowhere else; a manager can only reset (users mfa-disable).
    'me-2fa-enrol' => { self => 1, mutates => 1, cookie_only_reason => 'a person sets up their own second factor and sees its secret once', params => [ { name => 'current_password', in => 'body' } ] },
    'me-2fa-confirm' => { self => 1, mutates => 1, cookie_only_reason => 'a person turns on their own second factor with a code from their app', params => [ { name => 'code', in => 'body' } ] },
    'me-2fa-disable' => { self => 1, mutates => 1, cookie_only_reason => 'a person turns off their own second factor, with the password and a current code', params => [ { name => 'current_password', in => 'body' }, { name => 'code', in => 'body' } ] },
    'me-recovery-codes' => { self => 1, mutates => 1, cookie_only_reason => 'a person replaces their own recovery codes, with the password and a current code', params => [ { name => 'current_password', in => 'body' }, { name => 'code', in => 'body' } ] },
    'start-page' => { params => [ { name => 'username', in => 'query' } ] },
    'start-page-set' => { mutates => 1, params => [ { name => 'username', in => 'body' }, { name => 'value', in => 'body', required => 1, note => 'an empty string clears the start page' } ] },
    'whoami' => { params => [ { name => 'plugins', in => 'query' } ] },
);

# CAPS ARE DERIVED, NOT DECLARED TWICE. The three states come straight from
# %GATE: an entry with capabilities is any-of, 'ALWAYS' is any authenticated
# caller, and an action absent from the gate is cookie-only.
#
# A gate entry for an action nothing publishes is a fault and says so here rather
# than being dropped quietly - that asymmetry is exactly how the last five
# omissions reached the field.
for my $name ( keys %GATE ) {
    die "Lazysite::ControlApi::Actions: the gate names '$name', which %ACTION "
        . "does not publish - one of the two is wrong\n"
        unless exists $ACTION{$name};
}
for my $name ( keys %ACTION ) {
    my $g = $GATE{$name};
    $ACTION{$name}{caps}
        = !defined $g ? undef
        : ref $g      ? [ @{$g} ]
        :               [];
}

# The actions this caller may use, in the shape describe_capabilities uses for
# its own lists. Subsets by grant exactly as tools/list does (SM210), so an
# account is never shown an action it cannot call - a reference listing
# everything would be a list of things to try and be refused.
#
# A COOKIE-ONLY action is omitted for a token caller and included for a cookie
# session, because that is precisely what its availability depends on.
sub actions_for {
    my ( $caps, %opt ) = @_;
    $caps ||= {};
    my @out;
    for my $name ( sort keys %ACTION ) {
        my $spec        = $ACTION{$name};
        my $caps_needed = $spec->{caps};

        my $available;
        if    ( !defined $caps_needed ) { $available = $opt{cookie} ? 1 : 0 }
        elsif ( !@$caps_needed )        { $available = 1 }
        else { $available = ( grep { $caps->{$_} } @$caps_needed ) ? 1 : 0 }
        next unless $available;

        push @out, {
            action => $name,
            params => [ map { { %$_ } } @{ $spec->{params} } ],
            ( defined $caps_needed
                ? ( capabilities => [@$caps_needed] )
                : ( cookie_only => 1 ) ),
        };
    }
    return \@out;
}

# SM662 / A1: THE TABLE THAT DECIDES IS THE TABLE THAT IS PUBLISHED.
#
# The control API's token gate carried its OWN copy of this - %need_caps, a
# hundred lines inside a sub in lazysite-manager-api.pl - and this module was
# documented as an extraction of it. Two tables, one enforcing and one publishing,
# is the shape SM687 measured at nine registration points to add one action, and
# the shape that made every one of the last five omissions show up as a failing
# gate rather than as something a reader could see.
#
# They agreed exactly when they were collapsed: 102 gated actions, 54 cookie-only,
# zero disagreements, captured before the move and asserted by
# t/unit/manager/198 so the collapse can be shown to have changed no decision.
#
# The shape is the gate's, not this module's, because the gate is the caller:
#
#   'action' => [qw(a b)]   any ONE of these capabilities opens it
#   'action' => 'ALWAYS'    any authenticated caller
#   absent                  not reachable with a token (cookie-only)
#
# So `caps => undef` here means "omit", which is what made the CGI's table shorter
# than this one and is the difference a reader had to hold in their head.
sub need_caps {
    my %need;
    for my $name ( keys %ACTION ) {
        my $caps = $ACTION{$name}{caps};
        next unless defined $caps;    # cookie-only: the gate never lists it
        $need{$name} = @{$caps} ? [ @{$caps} ] : 'ALWAYS';
    }
    return \%need;
}

# SM943: THE MANAGER API'S TABLES, DERIVED. Each returns a list of pairs in the
# exact shape of the literal it replaced, so `my %MUTATING = mutating();` leaves
# every consumer in the CGI unchanged. t/unit/lib/200 proved them equal to the
# hand-kept literals before those were removed.
my %FIELD = map { $_ => 1 } qw(
    params caps mutates destructive changes_access audited scoped file_surface
    cookie_cap cookie_gates_itself cookie_only_reason mcp mcp_open_world
    instance_wide content_write self
);
for my $name ( sort keys %ACTION ) {
    my $spec = $ACTION{$name};
    for my $k ( sort keys %{$spec} ) {
        die "Lazysite::ControlApi::Actions: '$name' declares '$k', which is not a "
            . "field - a misspelt field would silently mean its default\n"
            unless $FIELD{$k};
    }
    my $fs = $spec->{file_surface};
    die "Lazysite::ControlApi::Actions: '$name' file_surface must be read or write\n"
        if defined $fs && $fs !~ /\A(?:read|write)\z/;
    my $cc = $spec->{cookie_cap};
    die "Lazysite::ControlApi::Actions: '$name' cookie_cap mixes | and +\n"
        if defined $cc && $cc =~ /\|/ && $cc =~ /\+/;
    my $t = $spec->{mcp};
    die "Lazysite::ControlApi::Actions: '$name' mcp must name one tool\n"
        if defined $t && $t !~ /\A[a-z][a-z_]*\z/;
    die "Lazysite::ControlApi::Actions: '$name' declares mcp_open_world with no mcp twin\n"
        if exists $spec->{mcp_open_world} && !defined $t;

    # SM1043: a self action acts on the caller alone - so no token reaches it, no
    # capability opens it, no MCP twin serves it, it writes no site content and
    # touches no file or instance setting, and no parameter names anyone. The
    # manager API lets self actions past the `ui` gate (SM1057) on the strength
    # of these checks, so each one is a wall, not a style rule.
    if ( $spec->{self} ) {
        die "Lazysite::ControlApi::Actions: self action '$name' is in the token gate\n"
            if exists $GATE{$name};
        die "Lazysite::ControlApi::Actions: self action '$name' declares $_\n"
            for grep { exists $spec->{$_} } qw(cookie_cap cookie_gates_itself mcp scoped content_write file_surface instance_wide);
        for my $p ( @{ $spec->{params} || [] } ) {
            die "Lazysite::ControlApi::Actions: self action '$name' takes '$p->{name}', "
                . "which names an account - the subject of a self action is the caller\n"
                if self_param_names_account( $p->{name} );
        }
    }
}

# SM1043: does a parameter name look like it names an account? Shared with
# t/lint/246, so the load-time refusal and the lint read one rule.
sub self_param_names_account {
    my ($n) = @_;
    return ( ( $n // '' ) =~ /(?:user|account|login|name|actor|principal|owner|member|who)/i ) ? 1 : 0;
}

# One tool is the twin of one action: two actions naming the same tool would give
# it two sets of hints, and the later one would win in silence.
{
    my %twin_of;
    for my $name ( sort keys %ACTION ) {
        my $t = $ACTION{$name}{mcp} // next;
        die "Lazysite::ControlApi::Actions: '$name' and '$twin_of{$t}' both name "
            . "the MCP twin '$t'\n"
            if exists $twin_of{$t};
        $twin_of{$t} = $name;
    }
}

sub _flagged { my ($k) = @_; return map { $_ => 1 } grep { $ACTION{$_}{$k} } sort keys %ACTION }

sub _valued {
    my ($k) = @_;
    return map { $_ => $ACTION{$_}{$k} } grep { defined $ACTION{$_}{$k} } sort keys %ACTION;
}

sub known_actions       { return map { $_ => 1 } sort keys %ACTION }
sub mutating            { return _flagged('mutates') }
sub destructive         { return _flagged('destructive') }
sub changes_access      { return _flagged('changes_access') }
sub scoped_actions      { return _flagged('scoped') }
sub instance_wide       { return _flagged('instance_wide') }
sub file_surface        { return _valued('file_surface') }
sub cookie_caps         { return _valued('cookie_cap') }
sub cookie_gates_itself { return _valued('cookie_gates_itself') }
sub cookie_only_reasons { return _valued('cookie_only_reason') }
sub content_writes      { return _flagged('content_write') }

# SM1043: the actions whose subject is always the signed-in caller (`self`).
sub self_actions { return _flagged('self') }

# Audited by default exactly when it mutates; `audited` states the exceptions.
sub audited {
    my ($name) = @_;
    my $spec = $ACTION{$name} or return 0;
    return exists $spec->{audited} ? ( $spec->{audited} ? 1 : 0 ) : ( $spec->{mutates} ? 1 : 0 );
}

# The audit trail's %skip: every action that is not audited.
sub unaudited { return map { $_ => 1 } grep { !audited($_) } sort keys %ACTION }

# SM943 stage 2: THE MCP TWINS, DERIVED.
#
# action => tool, for every action with an MCP twin. t/lint/23's pairing reads
# this; it used to keep its own %PAIR.
sub mcp_twins { return _valued('mcp') }

# tool => [ readOnly, destructive, openWorld, changesAccess ] for every twin, in
# the shape of lazysite-mcp.pl's %ANNOTATE, which takes these rows as they are.
# Three of the four hints are facts about the ACT, so they come from the action's
# own entry: a twin is read-only exactly when the action does not mutate, and
# destructive and access-changing exactly when the action is. The fourth,
# openWorld, has no meaning on the control API and is declared beside `mcp`.
sub mcp_annotations {
    my %ann;
    for my $name ( sort keys %ACTION ) {
        my $s = $ACTION{$name};
        my $t = $s->{mcp} // next;
        $ann{$t} = [
            $s->{mutates}        ? 0 : 1,
            $s->{destructive}    ? 1 : 0,
            $s->{mcp_open_world} ? 1 : 0,
            $s->{changes_access} ? 1 : 0,
        ];
    }
    return %ann;
}

1;
