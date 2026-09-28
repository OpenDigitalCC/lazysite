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
    'domain-set'      => [qw(manage_domains)],
    'remap-list'      => [qw(manage_domains)],                 # SM802
    'remap-save'      => [qw(manage_domains)],
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
    'form-list'        => [qw(read_submissions)],
    'form-delete'      => [qw(manage_forms)],       # SM632: the inverse of bind_form
        # SM842: handler CRUD on the token channel too, reversing SM799's
        # cookie-only rule - the release manager's ruling that the destination
        # decides, on every surface. See the cookie table for the door.
    'handler-list'      => [qw(manage_forms manage_data manage_connectors)],
    'handler-save'      => [qw(manage_forms manage_data manage_connectors)],
    'handler-delete'    => [qw(manage_forms manage_data manage_connectors)],
    'schedule-list'     => [qw(manage_forms manage_data manage_connectors)],
    'schedule-save'     => [qw(manage_forms manage_data manage_connectors)],
    'schedule-delete'   => [qw(manage_forms manage_data manage_connectors)],
    'form-targets-read' => [qw(manage_forms manage_data manage_connectors)],
    'form-targets-save' => [qw(manage_forms)],
    'form-uploads-save' => [qw(manage_forms)],
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
    # nothing else - enforced in action_theme_delete, which this branch asks
    # for by setting $RESTRICT_THEME_DELETE below. Without this an agent
    # accumulated an experiment per attempt and only the operator could clear
    # them. The manager UI over a cookie session does not take this path and
    # keeps the unrestricted delete: a human at the console is the case the
    # UI-only rule was protecting, and it still is.
    'theme-delete'            => [qw(manage_themes)],
    'artifact-backups-delete' => [qw(purge)],
    # SM105: navigation is a token-client action gated by manage_nav (which
    # inherits manage_content / webdav), so a WebDAV/API partner can read and
    # write the site nav without the MCP connector or raw WebDAV to lazysite/.
    # SM568: reading the navigation is a content read as much as a nav
    # editor's; manage_content admits it, as it does the MCP twin read_nav.
    'nav-read' => [qw(manage_content manage_nav)],
    'nav-save' => [qw(manage_nav)],
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
our %ACTION = (
    'acl-get'    => { params => [ { name => 'path', in => 'query' } ] },
    'acl-remove' => { params => [ { name => 'path', in => 'query' } ] },
    'acl-set' => { params => [ { name => 'path', in => 'query_or_body' }, { name => 'read', in => 'body' }, { name => 'write', in => 'body' }, { name => 'owner', in => 'body' }, { name => 'draft', in => 'body' } ] },
    'actions-list' => { params => [] },
    # SM576 part 1: the brief store's own capability. A read takes EITHER
    # (the three-state note above: any ONE of the listed caps is enough), so a
    # long-standing manage_content grant keeps reading; a write takes
    # manage_briefs alone.
    'brief-read' => { params => [ { name => 'path', in => 'query', required => 1 } ] },
    'brief-append' => { params => [ { name => 'path', in => 'query', required => 1 }, { name => 'entry', in => 'body', required => 1 } ] },
    'briefs-migrate' => { params => [] },
    'briefs-list'    => { params => [] },
    'brief-delete'   => { params => [ { name => 'path', in => 'query' } ] },
    'aliases-list' => { params => [ { name => 'host', in => 'query' }, { name => 'path', in => 'query' } ] },
    'analyse_visitors' => { params => [ { name => 'window', in => 'query' }, { name => 'day', in => 'query' }, { name => 'month', in => 'query' }, { name => 'index', in => 'query' }, { name => 'trails', in => 'query' } ] },
    'artifact-backups-delete' => { params => [ { name => 'path', in => 'query' } ] },
    'artifact-manifest'       => { params => [] },
    'artifact-validate'       => { params => [] },
    'audit' => { params => [ { name => 'user', in => 'query' }, { name => 'target', in => 'query' }, { name => 'start', in => 'query' }, { name => 'end', in => 'query' }, { name => 'page', in => 'query' }, { name => 'per_page', in => 'query' } ] },
    'backup-create'   => { params => [ { name => 'scope', in => 'query' } ] },
    'backup-delete'   => { params => [ { name => 'name',  in => 'query_or_body' } ] },
    'backup-download' => { params => [ { name => 'name',  in => 'query' } ] },
    'backup-list'     => { params => [] },
    # SM874: `replace` is the undo-of-apply mode - the target folder is cleared
    # before the snapshot is written back, so files a package ADDED are removed
    # too. Absent or false keeps the historic overlay behaviour.
    'backup-restore' => { params =>
            [ { name => 'name', in => 'query' }, { name => 'replace', in => 'query' } ] },
    'bad-url-blocks'  => { params => [] },
    'bad-url-block'   => { params => [ { name => 'ip', in => 'query' } ] },
    'bad-url-unblock' => { params => [ { name => 'ip', in => 'query' } ] },
    'cache-invalidate' => { params => [ { name => 'path', in => 'query' }, { name => 'host', in => 'query' } ] },
    'cache-list'       => { params => [] },
    'channel-services' => { params => [] },
    'config-read'      => { params => [] },
    'config-set' => { params => [ { name => 'key', in => 'query_or_body', required => 1 }, { name => 'value', in => 'query_or_body' } ] },
    'copy' => { params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
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
    'data-migrate' => { params => [ { name => 'table', in => 'query' } ] },
    'data-rebuild' => { params => [ { name => 'table', in => 'query_or_body' }, { name => 'confirm_lost', in => 'body' } ] },
    'data-row-delete' => { params => [ { name => 'table', in => 'query_or_body' }, { name => 'key', in => 'query_or_body' } ] },
    'data-row-save' => { params => [ { name => 'table', in => 'query_or_body' }, { name => 'key', in => 'query_or_body' }, { name => 'row', in => 'body' } ] },
    'data-rows' => { params => [ { name => 'table', in => 'query' }, { name => 'order_by', in => 'query' }, { name => 'order', in => 'query' }, { name => 'limit', in => 'query' }, { name => 'offset', in => 'query' } ] },
    'data-table'        => { params => [ { name => 'table', in => 'query' } ] },
    'data-table-source' => { params => [ { name => 'table', in => 'query' } ] },
    'data-migrate-plan' => { params => [ { name => 'table', in => 'query' } ] },
    # SM687: a table's access rule. Gated on manage_content, matching a file's
    # rule rather than inventing a separate policy for tables - reaching the
    # Data page needs manage_data too, so in practice a person holds both.
    'data-table-acl-get' => { params => [ { name => 'table', in => 'query' } ] },
    'data-table-acl-set' => { params => [ { name => 'table', in => 'query_or_body' },
            { name => 'owner', in => 'body' },
            { name => 'read',  in => 'body' },
            { name => 'write', in => 'body' } ] },
    'data-table-acl-remove' => { params => [ { name => 'table', in => 'query' } ] },
    'data-table-save' => { params => [ { name => 'table', in => 'query_or_body' }, { name => 'descriptor', in => 'body' } ] },
    'data-import' => { params => [ { name => 'table', in => 'query' }, { name => 'apply', in => 'query' } ] },
    'data-export' => { params => [ { name => 'table', in => 'query' }, { name => 'format', in => 'query' } ] },
    'data-table-drop' => { params => [ { name => 'table', in => 'query_or_body' }, { name => 'confirm', in => 'body' } ] },
    'data-tables'               => { params => [] },
    'data-safety-exports'       => { params => [] },
    'data-safety-export-delete' => { params => [ { name => 'file', in => 'query_or_body' } ] },
    'data-safety-export-read' => { params => [ { name => 'file', in => 'query' } ] },
    'data-safety-export-restore' => { params => [ { name => 'file', in => 'query_or_body' }, { name => 'apply', in => 'query_or_body' } ] },
    'delete'                => { params => [ { name => 'path', in => 'query' } ] },
    'describe-capabilities' => { params => [] },

    # SM778: resolve logins the caller ALREADY HOLDS to display names. No
    # capability beyond being signed in, because it answers only for the logins
    # it is given: it is not a listing of accounts and must never become one.
    'display-names' => { params => [ { name => 'logins', in => 'query_or_body', required => 1, note => 'an array of logins in the body, or a comma-separated list in the query' } ] },
    'domain-add' => { params => [ { name => 'host', in => 'body' }, { name => 'content_root', in => 'body' }, { name => 'site_url', in => 'body' }, { name => 'site_name', in => 'body' }, { name => 'theme', in => 'body' }, { name => 'layout', in => 'body' }, { name => 'nav_file', in => 'body' }, { name => 'search_default', in => 'body' }, { name => 'lang', in => 'body' }, { name => 'lang_group', in => 'body' }, { name => 'seed', in => 'body' } ] },
    'domain-check'   => { params => [ { name => 'host', in => 'query' } ] },
    'domain-preview' => { params => [ { name => 'host', in => 'query' } ] },
    'domain-remove' => { params => [ { name => 'host', in => 'body' }, { name => 'purge', in => 'body' } ] },
    'domain-set' => { params => [ { name => 'host', in => 'body' }, { name => 'key', in => 'body' }, { name => 'value', in => 'body' } ] },
    # SM802: the URL remapper - per-host rules, operator-only.
    'remap-list' => { params => [] },
    'remap-save' => { params => [ { name => 'host', in => 'body', required => 1 }, { name => 'rules', in => 'body', required => 1 } ] },
# N13-04: the audit trail's switch - audit_switch AND manage_config (the second checked in the dispatch).
    'audit-trail-set' => { params => [ { name => 'state', in => 'body', required => 1 }, { name => 'reason', in => 'body' } ] },
    'domains-list'      => { params => [] },
    'file-download'     => { params => [ { name => 'path', in => 'query' } ] },
    'file-upload'       => { params => [ { name => 'path', in => 'query' } ] },
    'file-zip-download' => { params => [] },
    # SM652: read_submissions ONLY, on both channels - form-list returns
    # row_count, which is a read of submission EXISTENCE.
    'form-list' => { params => [] },
    'form-submission-confirm' => { params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    'form-submission-delete' => { params => [ { name => 'file', in => 'query_or_body' }, { name => 'id', in => 'body' } ] },
    # SM652: manage_forms is definition-only now; reading a submission needs
    # the least-privilege capability built for it.
    # SM862: `form` is the one to reach for - it is what the MCP twin and
    # form-targets-read take - and `file` stays for a store named by path.
    # Neither is marked required: exactly one is needed, and the action answers
    # for that by name rather than letting the path validator call an absence a
    # malformed value.
    'form-submissions' => {
        params => [
            { name => 'form', in => 'query',
                note => 'the form\'s name; its store is resolved from the handler it binds to' },
            { name => 'file', in => 'query',
                note => 'the path to a .jsonl store, when naming one directly; `form` is preferred' },
        ],
    },
    'form-submissions-delete-bulk' => { params => [ { name => 'file', in => 'query_or_body' }, { name => 'ids', in => 'body' } ] },
    # SM842: a form's targets name handlers and nothing else, on the token
    # channel as on every other.
    'form-targets-read' => { params => [ { name => 'form', in => 'query', required => 1 } ] },
    'form-targets-save' => { params => [ { name => 'form', in => 'query_or_body', required => 1 }, { name => 'handlers', in => 'body', note => 'a list of handler ids; `targets` as [{handler: id}] is read the same way' }, { name => 'targets', in => 'body' } ] },
    'form-uploads-save' => { params => [ { name => 'form', in => 'query_or_body', required => 1 }, { name => 'uploads', in => 'body', note => 'on turns file uploads on for this form; off removes every upload_* key. A JSON boolean, 1/0, or "true"/"on"/"yes"' }, { name => 'max_kb', in => 'body', note => 'per FILE, default 5120' }, { name => 'max_files', in => 'body', note => 'per submission, default 5' }, { name => 'accept', in => 'body', note => 'file EXTENSIONS, comma-separated - `png, jpg, pdf`. Not a media type: the page grammar\'s accept: rule is the media-type one' } ] },
    'git-history' => { params => [ { name => 'path', in => 'query' }, { name => 'limit', in => 'query' } ] },
    # SM664: reachable with either - the overview sits on the Plugin Config
    # page, whose audience holds manage_config, and is a reporting read.
    'git-history-summary' => { params => [] },
    'git-init'            => { params => [] },
    'git-restore' => { params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-show' => { params => [ { name => 'path', in => 'query' }, { name => 'sha', in => 'query' } ] },
    'git-status' => { params => [] },
    # SM632: the inverse of bind_form. Gated on manage_forms for a token, and
    # confirmation names the form - a destructive verb taking only an id is one
    # an agent fires by having the wrong id.
    'form-delete' => { # Exactly data-table-drop's shape: the OBJECT may come either way, the
            # CONFIRMATION is body-only. Declaring `form` as body-only was wrong -
            # the dispatch reads `$req->{form} // $params{form}` - and t/lint/58
            # extracts the branch rather than trusting this table, so it said so.
        params => [ { name => 'form', in => 'query_or_body' },
            { name => 'confirm', in => 'body' } ] },
    # SM842: handler CRUD reaches the token channel, reversing SM799's
    # cookie-only rule. Any of the three destination capabilities opens the
    # door; the handler's type then decides (Lazysite::Handlers::cap_for_type).
    'handler-delete' => { params => [ { name => 'id', in => 'body', required => 1 } ] },
    'handler-list'   => { params => [] },
    'handler-save' => { params => [ { name => 'id', in => 'body', required => 1 }, { name => 'type', in => 'body', required => 1, note => 'smtp, file, table or connector; handler-list returns each type\'s fields' }, { name => 'name', in => 'body', required => 1 }, { name => 'enabled', in => 'body' } ] },
    'schedule-list' => { params => [] },
    'schedule-save' => { params => [ { name => 'id', in => 'body', required => 1 }, { name => 'handler', in => 'body', required => 1 }, { name => 'every', in => 'body', required => 1, note => 'seconds, at least 300' }, { name => 'payload', in => 'body', note => 'a flat object of fixed fields' }, { name => 'enabled', in => 'body' } ] },
    'schedule-delete' => { params => [ { name => 'id', in => 'body', required => 1 } ] },
    'key-revoke'      => { params => [] },
    'keys-list'       => { params => [] },
    'lang-status'     => { params => [ { name => 'group', in => 'query' } ] },
    'layout-activate' => { params => [ { name => 'path', in => 'query' }, { name => 'layout', in => 'query' } ] },
    # SM911 LD2: `layout` is the spelling its siblings take and the one a partner
    # tries; `path` is what the dispatcher had always passed, and stays.
    'layout-delete' => { params => [ { name => 'layout', in => 'query' }, { name => 'path', in => 'query' } ] },
    'layout-install'           => { params => [] },
    'layouts-available'        => { params => [] },
    'layouts-install'          => { params => [] },
    'layouts-manifest'         => { params => [] },
    'layouts-release-contents' => { params => [ { name => 'tag', in => 'query' } ] },
    'layouts-releases'         => { params => [] },
    'layouts-repo-get'         => { params => [] },
    'layouts-repo-set'         => { params => [ { name => 'value', in => 'body' } ] },
    'list'                     => { params => [ { name => 'path',  in => 'query' } ] },
    'lock'                     => { params => [ { name => 'path',  in => 'query' } ] },
    'migrate-to-local'         => { params => [ { name => 'path',  in => 'query' } ] },
    'mkdir'                    => { params => [ { name => 'path',  in => 'query' } ] },
    'move' => { params => [ { name => 'path', in => 'query' }, { name => 'to', in => 'query' } ] },
    'nav-read' => { params => [ { name => 'host', in => 'query' } ] },    # SM568
    'nav-save' => { params => [ { name => 'items', in => 'body' }, { name => 'host', in => 'query_or_body' } ] },
    'notices'      => { params => [] },
    'notices-seen' => { params => [] },
    # SM732: the PDF render, which SM706 shipped with no caller at all.
    # manage_content because converting a page is reading it in another format -
    # the plugin's own reasoning, and the reason it declares no capability.
    'page-pdf' => { params => [ { name => 'path', in => 'query' } ] },
    'pages'    => { params => [] },                                      # SM568
    'plugin-action' => { params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'action_id', in => 'body' }, { name => 'params', in => 'body' } ] },
    'plugin-disable' => { params => [ { name => 'script', in => 'body' } ] },
    'plugin-enable'  => { params => [ { name => 'script', in => 'body' } ] },
    'plugin-list'    => { params => [] },
    'plugin-read' => { params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' } ] },
    'plugin-save' => { params => [ { name => 'plugin', in => 'query' }, { name => 'script', in => 'body' }, { name => 'values', in => 'body' } ] },
    'preview'               => { params => [ { name => 'path', in => 'query' } ] },
    'preview-clear'         => { params => [] },
    'preview-grant'         => { params => [] },
    'preview-public'        => { params => [ { name => 'path', in => 'query' } ] },
    'principals'            => { params => [] },
    'protected-sections'    => { params => [ { name => 'path',   in => 'query' } ] },
    'read'                  => { params => [ { name => 'path',   in => 'query' } ] },
    'recent-changes'        => { params => [ { name => 'window', in => 'query' } ] },
    'regenerate-registries' => { params => [] },
    'renew-lock'            => { params => [ { name => 'path', in => 'query' } ] },
    'rotate-auth-secret'    => { params => [] },
    'save' => { params => [ { name => 'path', in => 'query' }, { name => 'content', in => 'body' }, { name => 'mtime', in => 'body' } ] },
    'session-revoke'    => { params => [] },
    'sessions-list'     => { params => [] },
    'site-backup-apply' => { params => [] },
    'site-backup-create' => { params => [ { name => 'host', in => 'query_or_body' }, { name => 'data_tables', in => 'body' } ] },
    'site-backup-delete' => { params => [ { name => 'name', in => 'query_or_body', required => 1 } ] },
    'site-backup-download' => { params => [ { name => 'name', in => 'query_or_body' } ] },
    'site-backup-inspect' => { params => [ { name => 'name', in => 'query' }, { name => 'host', in => 'query' } ] },
    'site-backup-upload'  => { params => [] },
    'site-export-primary' => { params => [ { name => 'data_tables', in => 'body' } ] },
    'theme-activate' => { params => [ { name => 'path', in => 'query' }, { name => 'theme', in => 'query' } ] },
    'theme-copy' => { params => [ { name => 'path', in => 'query', required => 1 }, { name => 'new_name', in => 'body', required => 1 }, { name => 'layout', in => 'body' } ] },
    'theme-delete'      => { params => [ { name => 'path', in => 'query' } ] },
    'theme-list'        => { params => [] },
    'theme-upload'      => { params => [ { name => 'filename', in => 'query' } ] },
    'themes-for-layout' => { params => [ { name => 'layout', in => 'query' } ] },
    'themes-list-all'   => { params => [] },
    'unlock'            => { params => [ { name => 'path', in => 'query' } ] },
    'user-revoke'       => { params => [] },
    'users'             => { params => [] },
    'version'           => { params => [] },
    # SM671: `plugins=0` omits the plugin catalogue, which is 82% of the answer
    # on a bare site. Opt-out rather than opt-in, so an existing client reading
    # `plugins` keeps seeing it.
    # SM579: connectors. connector-call's caps are undef because the CONNECTOR
    # gates it (callers groups or manage_connectors) - see Connectors::may_call.
    'connector-list' => { params => [] },
    'connector-save' => { params => [ { name => 'id', in => 'body' }, { name => 'connector', in => 'body' } ] },
    'connector-secret-set' => { params => [ { name => 'id', in => 'body', required => 1 }, { name => 'secret', in => 'body', required => 1 } ] },
    'connector-delete' => { params => [ { name => 'id', in => 'body', required => 1 } ] },
    # SM781: caps => [] - NO capability, not "cookie-only". undef here means
    # the cookie channel alone serves the action, and connector-call is
    # served on every channel (gate 'ALWAYS'); the field found it working and
    # missing from actions-list, and SM779's map would have marked it
    # cookie_only. The connector gates it (Connectors::may_call).
    'connector-call' => { params => [ { name => 'id', in => 'body' }, { name => 'payload', in => 'body' }, { name => 'row', in => 'body', note => 'a row key: the connector\'s row_map decides which of its columns are sent' } ] },
    'connector-calls' => { params => [ { name => 'connector', in => 'query' }, { name => 'state', in => 'query' }, { name => 'limit', in => 'query' } ] },
    'start-page' => { params => [ { name => 'username', in => 'query' } ] },
    'start-page-set' => { params => [ { name => 'username', in => 'body' }, { name => 'value', in => 'body', required => 1, note => 'an empty string clears the start page' } ] },
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

1;
