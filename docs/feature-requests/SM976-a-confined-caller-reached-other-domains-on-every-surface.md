---
id: SM976
title: "SM976: A confined caller reached other domains on every surface"
subtitle: "A token, MCP grant, WebDAV account or cookie manager confined to one domain added, aliased, removed, configured, packaged and re-navigated other domains; one rule now answers for every host-addressed action."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-09
raised-by: the developer agent, from the gaps SM975 found and did not change
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-09 \"One rule, fix all\" - a confined caller reaches only its own domains (n312, lint 218). R1-R4 (n314), F1-F4 (n315), n316, n317 (lint 219). Q15h (n321): raw-bytes pages UTF-8. Q15i (n322): walks skip a non-UTF-8 page. Q15j (n325): MCP page reads refuse it; walks say truncated. Q15k (n327): restore and nav read refuse it. t/integration/112, 114-121."
---

# What was wrong

SM975 made a token with no scope reach no domain, and recorded what it found
for scoped callers without changing it. Probed on main 4cd9f808
(tmp/q15b-reach-probe.pl, 228 cells; before and after in
tmp/q15b-reach-probe.before.out and .after.out):

- A token scoped to one domain ran `domain-add` at any content root,
  `domain-alias-add` of any domain and `domain-remove` of any domain.
  `domain-set` let it repoint its own domain's `content_root` at another
  domain's content, which moved its scope there, and set keys on a domain with
  no content root of its own (one serving the primary's content).
- MCP `domain_set` asked neither the scope of a scoped grant nor SM647's
  `manage_users` requirement for `allowed_groups` and `locked_users`. A grant
  scoped to one domain wrote another domain's access groups. `activate_theme`
  and `activate_layout` with a `host` are the same write and asked nothing,
  not even SM975's scope check.
- `_root_outside_grant` exempted every cookie session, so a cookie manager
  scoped to one domain built, downloaded and deleted another domain's site
  package. `site-backup-apply` with no host (the primary) and a `content_root`
  inside the caller's scope rewrote the primary's presentation.
- The navigation: `nav-read`/`nav-save` and `read_nav`/`set_nav` never asked
  about `host`. A grant scoped to one domain read and replaced every other
  domain's navigation, and the primary's. WebDAV (tested as asked): a nav file
  returned allowed before the scope check, so a scoped WebDAV account GOT and
  PUT another domain's nav file and the primary's `lazysite/nav.conf`.
- Listings and reads: `domains-list`/`list_domains` showed a confined caller
  every domain's content root, access groups and address; `domain-preview`,
  `preview_domain`, `domain-check` and `aliases-list` answered for any host.
- The data surface: `data-table-save` let a confined caller bind a table to a
  domain it does not reach - create a table in another domain, or move its own
  there (tmp/q15b-data-probe.pl).

# The ruling

Release manager, 2026-10-09: "One rule, fix all". A domain-confined caller -
token, MCP grant, or scoped (non-operator) cookie manager - reaches only its own
domains on every surface; the unconfined operator is unaffected.

# The rule, built

`Lazysite::Manager::Common::caller_may_reach_domain( host => H | root => R )`,
with `domain_reach_refusal` (the refusal, naming the caller's scope and the
domains it does reach) and `reachable_domains`.

Who is confined
: A token, always. A cookie manager with a scope. Over MCP and WebDAV every
  caller is a grant, passed as `scopes => [...]`. The cookie operator, and a
  cookie manager whose groups bind no domain, are unconfined - an empty scope on
  the cookie channel is no confinement, as for its content paths, and as every
  domain action already treated it.

The answer for a confined caller
: A host the instance does not serve: no. A domain with its own content root:
  yes when the root lies inside one of its scopes, no otherwise, and no for an
  empty scope (SM975). The primary, and a domain with no root of its own (it
  serves the primary's content): the content-path rule SM975 kept - an unbound
  grant reaches the primary site, a scoped one does not. The domain writes and
  site packages keep SM975/SM578's outright refusal of a token naming no scope
  ahead of this.

A navigation file
: Reading needs one domain the file is the navigation of; writing needs every
  one, since a file shared by inheritance changes each site that inherits it.

A new content root
: `domain-add` and `domain-set content_root`: the root must lie inside the
  caller's scope.

# Every host- or root-addressed action, and how it asks

Control API (`lazysite-manager-api.pl`): `domain-add` (content_root),
`domain-alias-add` (alias_of), `domain-set` (host; new content_root),
`domain-remove`, `domain-preview`, `domain-check` and `cache-invalidate` (host)
through `_refuse_unreachable_domain`; `aliases-list` (host, else the domain
owning `path`, else the primary); `domains-list` filters its rows;
`site-backup-create`/`-inspect`/`-download`/`-delete` and `backup-list` through
`_root_outside_grant`/`_package_scope_refusal`, which now hold a scoped cookie
manager too; `site-backup-apply` asks of the target domain and its root;
`site-export-primary` asks of the primary; `remap-save`/`remap-list` through
`Manager::Remap::_remap_host_in_scope`; `nav-read`/`nav-save` in
`Manager::Nav`. MCP (`lazysite-mcp.pl`): `domain_set`, `preview_domain`,
`site_backup`, `site_apply`, `activate_theme`/`activate_layout` with host,
`read_nav`, `set_nav`, `list_domains`. WebDAV (`lazysite-dav.pl`): both
navigation branches of `authorise` through `_nav_reach_deny`. Data:
`data-table-save` checks a descriptor's `domain:` by the data surface's own rule
(below).

`t/lint/218` holds this: every control-API action that takes or reads a host,
content root or alias, every listing and package verb, every MCP tool with a
`host` or `content_root` argument and both WebDAV nav branches ask the rule,
directly or through a sub that does; an exception is a closed list with a
reason.

# Behaviour change

A scoped token, MCP grant, WebDAV account or cookie manager is refused on
another domain, on the primary, on a host the instance does not serve and on a
domain serving the primary's content; its listings show its own domains only.
An unbound token, MCP grant or WebDAV account reaches no domain's navigation;
it still reads the primary's, and writes it unless a domain with a content root
of its own inherits that file. Single-site instances are unaffected. The operator and an unbound cookie
manager are unchanged. A scoped cookie manager's Nav page opens on its first
domain.

# Evidence

- t/integration/112 is the probe as assertions: every cell, the operator and
  the unbound cookie manager served, the confined callers refused outside their
  domains and served inside them, and a single-site instance where an unbound
  grant keeps the primary's nav on all three surfaces.
- t/unit/manager/207 is the predicate's truth table; t/unit/data/66 the table
  binding.
- Before and after on main's probe: 165 cells unchanged (no refusal became a
  success), 63 ok-to-refused, all of them the gaps above
  (tmp/q15b-same-answers.out).
- Sabotage: the predicate answering yes for everyone fails 112 and 207; the data
  check removed fails 66; one action's call removed fails lint 218.

# Found, then ruled

The build above recorded two questions it did not change, and the release
manager's review asked two more. Ruled 2026-10-09:

R1 (security), "Confined = no instance-wide"
: A domain-confined caller (token with a scope, scoped cookie manager, MCP
  grant or WebDAV account confined to some domains) cannot change
  instance-wide settings. They act on their own domains only, through
  host-addressed actions. Operator and unconfined callers unchanged.

R2, "Unbound cookie manager = unconfined"
: A cookie manager whose groups bind no domain is a whole-instance manager.

R3, "Keep for primary"
: Unbound tokens, MCP grants and WebDAV accounts reach the primary via the
  content-path rule (whoami allow: /); other domains need an explicit scope
  (SM975).

R4, "Use the shared rule"
: The data surface calls `caller_may_reach_domain` like every other action;
  lint 218's single exception (`data-table-save`) goes.

What was measured before the rulings: a token scoped to one domain, with
`manage_config`, rewrote the instance's `site_name` through `config-set`
(tmp/q15b-instance-wide-probe.out); and the data surface's own rule (SM593/
SM648) reached a domain's tables when scope and root overlapped in either
direction, gave a domain serving the primary's content to nobody, and confined
a cookie manager bound to no domain to no table.

# The rulings, built (n314)

Who is confined (R1)
: The predicate's own notion, read one way: a caller on a confined channel
  whose scope list is not empty - `Manager::Common::caller_is_confined`.
  Scopes are the content roots of the domains its groups are named on (or
  SM165's deny-all for a locked account), so a non-empty scope binds it to
  some domains, and `caller_may_reach_domain` already refuses it the primary.
  A token, grant or account naming no scope reaches the primary (R3), whose
  settings the instance's are, and keeps them; so do the operator and an
  unbound cookie manager (R2). A cookie manager holding `manage_users` is the
  operator (Acl `_is_operator`) and was never confined.

The instance-wide writes (R1)
: A closed list, `instance_wide => 1` in `Lazysite::ControlApi::Actions`,
  refused by `instance_wide_refusal` before the control API's dispatch and for
  each MCP twin unless the twin takes a `host` and was given one:
  `config-set`, `theme-activate`, `layout-activate`, `layouts-repo-set`,
  `layout-install`, `layouts-install`, `layout-delete`, `plugin-enable`,
  `plugin-disable`, `plugin-save`, `plugin-action`, `audit-trail-set`,
  `git-init`, `bad-url-block`, `bad-url-unblock`, `rotate-auth-secret`,
  `backup-create`, `backup-restore`, `backup-delete`,
  `artifact-backups-delete`, `connector-save`, `connector-secret-set`,
  `connector-delete`, `handler-save`, `handler-delete`, `schedule-save`,
  `schedule-delete`, `briefs-migrate`; over MCP `activate_theme` and
  `activate_layout` without a host, `install_layout`, `delete_layout`,
  `save_handler`, `delete_handler`, `save_schedule`, `delete_schedule`, and
  `create_theme` with `activate`. Decided in their branch: `theme-delete`
  removes only a theme the confined caller created (SM262's rule); `backup-list`
  shows it no instance backup and `backup-download` refuses one (a full backup
  carries every domain's content and the account store).

Not instance-wide, and why (lint 218's closed list)
: `theme-copy`, `theme-upload` and `create_theme` add a theme nothing serves;
  `regenerate-registries` rebuilds derived output; `site-backup-upload` stores
  a package that changes a site only through the host-checked apply;
  `preview-grant`/`-clear`, `notices-seen` and `start-page-set` are the
  caller's own; `connector-call` is decided by the connector; the session, key
  and account-approval verbs need `manage_users`, which makes a cookie caller
  the operator; the briefs and forms verbs address one object (see below).
  The users and groups store is not reachable by a confined caller: the
  `users` action is cookie-only and its instance-level operations need
  `manage_users`; a delegate keeps to its own sub-tree (SEC-2026-07 C1).

The data surface (R2, R4)
: `Manager::Data::_may_reach` and the `domain:` check of `data-table-save` ask
  `caller_may_reach_domain( scopes => ... )`; the control API hands the data
  module `request_domain_confined` as its confinement flag. Narrows: a scope
  inside a domain's root no longer reaches the domain around it; the table
  access-rule verbs and the safety exports (listing, read, restore, delete) ask
  the table's reach - they asked nothing. Widens: an unbound cookie manager
  reaches every table (R2); an unbound token or grant reaches the tables of a
  domain serving the primary's content (R3). Unchanged: a scope reaches the
  domains whose root lies inside it; tables naming no domain are everyone's.

R3
: Built in n312; pinned by name in t/unit/manager/207 (an unbound token and an
  unbound grant reach the primary and the domain serving its content, no
  other).

Evidence (n314)
: t/integration/114 (every instance-wide action, every caller, both doors),
  t/integration/115 (R2 and R4 through the doors), t/unit/data/67 (each data
  case that changed), t/unit/manager/207 (R1's who and R3), t/lint/218
  section 5. The probe tmp/q15c-probe.pl on n313 and n314 (368 cells,
  tmp/q15c-probe.before.out and .after.out): 262 unchanged; 106 changed, every
  one an intended narrowing (instance-wide refusals, the data verbs that asked
  nothing) or one of the R2/R3 widenings above.

# Found in Q15c, for a ruling

- A theme a domain serves is writable by a confined caller. The active-theme
  rule (SM749) protects only the instance's active theme, so a grant scoped to
  one domain wrote into the theme another domain is bound to (MCP
  `write_file` under `lazysite/layouts/.../themes/<theme>/`, measured in
  tmp/q15c-probe.after.out; WebDAV and the cookie file surface consult the same
  rule, read and not run). Recommendation: extend
  `active_artifact_refusal` to every theme and layout the primary or any
  configured domain serves, which is SM749's own reasoning.
- Forms carry no domain, and the form verbs ask no reach. Measured
  (tmp/q15c-forms-briefs-probe.out): a token scoped to one domain listed
  another domain's form (`form-list`) and rewrote its upload settings
  (`form-uploads-save`). The other form verbs address a form by the same bare
  name and were read, not run: `form-targets-save`, `form-notify-save`,
  `form-delete` and the submission verbs. Briefs ask no reach either: the same
  token appended to and read the brief of a page in another domain
  (`brief-append`, `brief-read`). Recommendation: confine a form by the page
  that binds it, and a brief by its path or table, through the same rule.
- A dropped table's safety export carries no domain, so it is reached as an
  untagged table is. Recommendation: record the table's `domain:` in the
  export when it is written.

# Found in Q15c, ruled
The release manager ruled the three findings above, and the Appearance page
they bore on, on 2026-10-09:

F1 (security), "Yes, any served artifact"
: A confined caller may write a theme or layout only if it is unused, or used
  only by domains inside its scope. Extend active_artifact_refusal (or its
  equivalent) to every theme/layout served by the primary or any domain; same
  rule on MCP (write_file etc.), WebDAV, the cookie file editor, theme/layout
  upload/copy/delete - every write path into themes/layouts. Lint 218 covers
  it.

F2 (security), "Confine both"
: Form actions reach only forms bound on pages inside the caller's scope (an
  unbound form counts as the primary's); brief actions reach only briefs for
  paths inside scope, or for tables that pass the data rule. Listings
  filtered. All form-* and brief* actions on API and MCP. Lint 218 covers them
  (remove them from its closed list).

F3, "Record domain"
: New safety exports carry the table's domain and are confined like the
  table; existing exports with no domain are treated as the primary's (a
  scoped caller can't reach them; operator and unbound callers per the
  primary rule can).

F4 (UI), "Activate on its domain"
: For a scoped cookie manager, the Appearance page activates on the manager's
  own domain via host-addressed activation (not domain-set, so no
  manage_domains needed); with several domains it asks which; the operator's
  page unchanged.

# The findings, built (n315)

Who is confined
: As for every domain object: `caller_may_reach_domain`'s caller - a token
  and an MCP grant or WebDAV account always, a cookie manager with a scope.
  The operator and an unbound cookie manager are not asked. An unbound token,
  grant or account reaches the primary (R3) and no domain with a content root
  of its own; for a content path its scope is the whole content.

F1, a served theme or layout
: `Manager::Common::served_artifact_refusal(rel, scopes?)`. Who serves a path
  under `lazysite/layouts/<L>`: for `themes/<T>/...` the sites whose
  effective layout and theme are L and T, otherwise every site using L
  (`Domains::domain_usage`, so a domain inheriting the primary's theme serves
  it too). Refused when any of them is a site the caller does not reach, or the
  usage cannot be read; the refusal names the theme and not the site, and the
  way to work (copy, edit the copy, bind it with host). Status 403.
  SM749's rule still holds the instance's active pair for everyone.
  Write paths, every one into lazysite/layouts:
  - the file choke point, `Manager::Files::_active_artifact_guard` (asked by
    action_save, action_save_binary, action_delete, action_mkdir, action_move
    and action_copy): the cookie file editor and the control API's save,
    delete, mkdir, move, copy, git-restore; MCP write_file, upload_file,
    delete_file, move_file, copy_file, replace_text, restore_version. MCP hands
    it the grant's scopes (`Manager::Files::$CALLER_SCOPES`), since that
    process holds no manager request;
  - the multipart upload, `Manager::Upload::action_file_upload`, per file
    through `Files::artifact_write_guard` - it asked neither rule, and
    replaced files in the instance's active theme;
  - WebDAV, `authorise_layout` in lazysite-dav.pl, with the account's scopes;
  - theme-copy, theme-upload and create_theme write only a theme of a new name
    (an existing one is refused or installed under a dated name), which no
    site serves; theme-delete refuses a theme any site uses, to everyone
    (SM177), and a confined caller deletes only its own (R1); layout-install,
    layouts-install and layout-delete are instance-wide (R1); site-backup-apply
    only adds a layout or theme that is not there.

F2, forms
: `caller_may_reach_form(name)`: the pages binding a form are the Markdown
  pages, public or in the private store, whose front matter says `form: NAME`
  (`form_pages`/`form_bindings`, one walk per listing). Every one must lie
  inside the caller's scope (`caller_may_reach_path`, the content-path rule,
  which refuses a `..` segment and the engine tree); a form no page binds is
  the primary's. Asked before the form is looked at, so another site's form
  and a missing one answer alike. Control API: form-targets-read,
  form-targets-save, form-uploads-save, form-notify-save, form-delete,
  form-submissions (by form or store), form-submission,
  form-submission-delete, form-submission-confirm,
  form-submissions-delete-bulk, form-submission-approve
  (`_refuse_unreachable_form`); form-list filtered. MCP: bind_form,
  set_form_uploads, set_form_notify, delete_form, read_form_submissions,
  read_form_submission (`_form_refusal`), form_list filtered, and create_form
  naming a form that already exists (a registration, a store or a page) - a
  new name is the page's own. WebDAV: `lazysite/forms/<name>.conf`
  (`_form_reach_deny`).

F2, briefs
: `caller_may_reach_brief(path, type/table)`: a page's brief by its path
  (`caller_may_reach_path`); a row's - typed, or a store path under
  `.typed/` - by its table's domain (`caller_may_reach_table`, the data rule:
  a table naming none is everyone's). Control API: brief-read, brief-append,
  brief-delete (the entry it removes: the path when given, else the typed
  reference) through `_refuse_unreachable_brief`; briefs-list filtered. MCP:
  read_brief, append_brief, delete_brief (`_brief_refusal`); list_briefs
  filtered. briefs-migrate is instance-wide (R1).

F3, safety exports
: `Data::Tables::_safety_export` writes `domain` (the table's, '' for none)
  into every drop and rebuild export. `Manager::Data::_export_reach` reaches an
  export by that domain; one without the key is the primary's. The listing,
  read, delete and restore ask it, and restore asks the live table's reach as
  well, since the rows go into the table as declared now.

F4, activation on a domain
: The control API's `theme-activate` and `layout-activate` take `host` (and
  layout-activate `theme`), as MCP's activate_theme and activate_layout do:
  bound through `Domains::domain_set` for that host, asked of the domain rule
  (a token naming no scope is refused, SM975), the instance untouched, and
  exempt from the instance-wide refusal only when given a host. No
  manage_domains: the theme or layout capability, on a domain the caller
  reaches. `themes-list-all` carries `acts_on` - a confined caller's domains -
  and the Appearance page binds there: one domain directly, several by asking
  which, none by saying so; Deactivate (the instance's theme) is not offered.
  The operator's page sends what it always sent.

Evidence (n315)
: t/integration/116 (F1, F2, F4 through every door and caller),
  t/unit/manager/209 (the rules' truth tables), t/unit/manager/208 (the
  Appearance page under node), t/unit/data/68 and 67 (F3), lint 218 sections
  6-7 and lint 114 (the new rule on both write stacks). The probe
  tmp/q15d-probe.pl (tmp/q15c-probe.pl's cells and F1-F4, 816 cells) on n314
  and n315: 667 unchanged, 149 changed, every one a narrowing named above or
  one of these: the host-addressed activations (the ruling's own), and an
  unbound token or grant reaching the legacy exports of domain tables (F3's
  own words). Every new assertion sabotage-verified (tmp/q15d-sabotage.pl, 20
  cases).

Found in Q15d, not changed
: A page saved with `form: NAME` naming a form no page bound before makes that
  form the page's: a scoped caller that writes such a page in its own content
  then reaches the form and its submissions (measured: tmp/q15d-hijack-probe.out,
  a cookie manager scoped to sites/mine refused `leads`, saved
  sites/mine/hook.md naming it, then read its one submission). create_form
  asks; a plain save does not read the front matter for it. Reported for a
  ruling: refusing, at the content-write rules, a page that newly binds a form
  the caller does not reach is one way; it is a new content-write rule, so it
  waits for the ruling.

# Found in Q15d, ruled

The release manager ruled the finding above, and F3's old exports, on
2026-10-09:

Form hijack (security), "Refuse new binding"
: Every content-write surface (cookie file save and the control API's file
  verbs, MCP write_file / create_page / replace_text / upload_file / move_file /
  copy_file / restore_version, WebDAV PUT/MOVE/COPY, page rename,
  site-backup-apply of content, and any other path that writes or moves a page)
  checks the written page's front matter `form:` against the caller's reach
  BEFORE writing; if the page NEWLY names a form the caller cannot reach (via
  caller_may_reach_form, judged as if the page were not yet written - i.e. the
  form's current bindings), the write is refused with a message naming the
  rule. Editing a page that already binds that form is unchanged; removing a
  binding is unchanged. A MOVE/rename that brings a binding page into scope, or
  a copy of a binding page into the caller's scope, is a new binding there.

F3 old exports
: "Leaving the risk for old sites is acceptable, and implementing correctly for
  new. No need to build logic to detect old sites." n315's behaviour stands: an
  export written before F3, with no recorded domain, counts as the primary's.
  No code.

# The ruling, built (n316)

The rule
: `Manager::Common::form_bind_refusal(rel, text, scopes?)`. For a `.md` page
  (the pages the processor renders a form on) and a confined caller - the
  caller `caller_may_reach_form` asks about - every form the new text names
  that the page at that path does not name now is asked of
  `caller_may_reach_form` on its current bindings; one it does not reach
  refuses the write, 403, kind `form-bind-refused`, naming the page, the form
  and the rule. `form_bind_tree_refusal(src, dst, scopes?)` asks it of every
  page a move, copy or package carries, at the path it will have; a page it
  cannot read is refused. The operator and an unbound cookie manager are not
  asked; an unbound token, grant or account reaches every form (R3).

A form that exists nowhere (decided in the build, for review)
: Read to the letter, the ruling refuses a scoped caller every form no page
  binds yet, since such a form counts as the primary's - including a new form
  of its own, so `create_form` with a new name, and a page naming one, would
  fail for every scoped caller. F2 already reads a new name as the page's own
  (create_form asks only of a form that exists). So a form that exists nowhere
  - no `lazysite/forms/NAME.conf`, no submissions in the default store, no page
  binding it; compared without case, as `form_bindings` compares - is not
  refused: it has no settings or submissions for a binding to take, and naming
  it creates it (`form_exists_anywhere`). Every form that exists is judged by
  the rule.

Which form a page names
: `page_form_names`: both readings - the processor's (the last column-0
  `form:` key, its value read past a line break, TT markers and quotes removed,
  then sanitised to `[A-Za-z0-9_-]`, which is what its visitors post to) and
  `form_bindings`' (the first `form: NAME` line, which is what the form rule
  reaches it through). A check reading one could be passed by a page the other
  reads differently; t/unit/manager/210 holds the first to the processor's own
  `parse_yaml_front_matter`.

Every content-write path, and how it asks
: - `Manager::Files::action_save` (Files.pm, before `write_file_checked`): the
    cookie file save and control-API `save`, `git-restore`
    (`action_git_restore` saves through it); MCP `write_file`, `create_page`,
    `replace_text`, `copy_file` (read, then save), `create_form`,
    `restore_version`, and `rename_page`'s link and alias edits - through
    `form_bind_guard`, with MCP's grant scopes (`$Files::CALLER_SCOPES`).
  - `action_save_binary`: MCP `upload_file` - `form_bind_guard` on the bytes.
  - `action_move`: control-API `move`, MCP `move_file` and `rename_page` -
    `form_bind_tree_guard` over the source in both trees (a folder spanning
    the docroot and the private store moves in both, SM518).
  - `action_copy`: control-API `copy` - `form_bind_tree_guard`.
  - `action_migrate_to_local`: the fetched body - `form_bind_guard`.
  - `Manager::Upload::action_file_upload`: per file, `form_bind_guard`.
  - `Manager::SitePackage::package_apply`: control-API `site-backup-apply` and
    MCP `site_apply` (through `apply_and_configure`) - `form_bind_tree_guard`
    over the extracted content before it is copied.
  - WebDAV `do_put` (before the rename into place) and `do_copy_move` (before
    the destination is touched): `form_bind_refusal` /
    `form_bind_tree_refusal` with the account's scopes.
  Closed, with the reason (lint 218 section 8): delete, `delete_file`,
  `delete_page`, WebDAV DELETE (removing a binding is unchanged); mkdir and
  MKCOL (no page); lock, renew-lock, unlock, PROPPATCH (no page text);
  `acl-set`, `acl-remove`, `set_permissions` (a page moves between the docroot
  and the private store, both of which `form_bindings` reads);
  `cache-invalidate`/`invalidate_cache` (rendered output). Instance-wide
  actions (`backup-restore`, `plugin-*`, `schedule-*`) are refused to every
  confined caller with a scope (R1). Bind_form and create_form naming an
  existing form already ask the form rule (F2).

Evidence (n316)
: t/unit/manager/210 (the rule's truth table, the readings against the
  processor's parse, the tree rule, the choke point with a grant's scopes,
  migrate-to-local with a stubbed fetch); t/integration/117 (the Q15d probe as
  assertions - refused now, an already-bound page still edited, the binding
  still removable, the operator unaffected - then the cookie save, move, copy
  and upload, git-restore and restore_version, MCP write_file, upload_file,
  copy_file, replace_text, move_file, rename_page, WebDAV PUT, COPY and MOVE,
  site-backup-apply and site_apply, each with the unbound callers served);
  lint 218 section 8 and lint 114. Every new assertion sabotage-verified
  (tmp/q15e-sabotage.pl, 26 cases).

# Found in Q15e

- The form rule's walker and the processor read a page's form differently.
  `form_bindings` takes the first `form: NAME` line, of a plain name, within
  the first 16 KB; the processor renders the last `form:` key, a value on the
  next line, a name with other characters removed. Measured
  (tmp/q15e-walker-probe.out): a page in another domain whose front matter
  says `form:` with the name on the next line renders and receives the form
  `contact`, and `form_bindings` does not see it, so a caller scoped to a domain
  that also binds `contact` reaches the form, and the other site's submissions
  with it. The reverse also holds: a page in the caller's scope rendering a
  form under such a line does not make the form its own. Not changed: one
  reading for both (`page_form_names` in the walker) narrows the first and
  widens the second, so it waits for a ruling. n316's write rule reads both,
  so no new page of this shape is written by a confined caller.
- MCP `replace_text` cannot be used by a scoped grant on ordinary text: its
  `old` and `new` arguments are scope-checked as content paths, because
  `@PATH_ARGS` lists `old` and `new` for `rename_page` (SM661), so "Path 'title:
  Plain' is outside your assigned scope". Fails closed; not changed (a fix
  widens what a grant can call).

# Found in Q15e, ruled

The release manager ruled n316's decision and both findings above on
2026-10-09:

A form that exists nowhere, "Keep"
: a3686669 "Keep": a form that exists nowhere (no conf, no stored submissions,
  no binding page) is new and a scoped caller may bind it; any form existing
  anywhere is judged by the reach rule. Recorded only; n316's build stands.

Form reading (security), "One reading, processor's"
: `form_bindings` (and anything else deciding which form a page binds, incl.
  `page_form_names`) uses the SAME front-matter parse the processor renders
  with, so "which form a page binds" has one answer everywhere. ADR 0001 forbids
  the processor loading modules, so the processor keeps its own copy; lib's
  reading is a marked copy, and a lint or test pins them equal. The 16 KB
  first-line plain-name reading is removed. Another domain's page with `form:`
  and the name on the next line now counts as binding `contact`, so the scoped
  caller no longer reaches it.

replace_text, "Fix: per-tool path args"
: Each MCP tool declares which of its arguments are content paths; rename_page's
  `old`/`new` stay path-checked; replace_text's `old`/`new` are text. The global
  `@PATH_ARGS` name list is replaced with the per-tool declaration; a lint holds
  every tool that takes a path-like argument to a declaration, and fails a tool
  whose declared path argument is missing from its schema.

# The rulings, built (n317)

One reading, the processor's
: `Manager::Common::page_form(text)` is a marked copy of the processor's reading
  (`lazysite-processor/front-matter.pm`, `parse_yaml_front_matter`: the front
  matter block, the scalar `key: value` loop - the last column-0 `form:` wins,
  its `\s*` reading a value on the next line - `strip_tt_directives`, one pair
  of quotes, the sanitiser), matched with the character semantics the
  processor's `:utf8` read gives. The processor's sanitiser carries the mark
  back. Asked by: `form_bindings` (the whole page, read as the processor's
  `read_file` reads it - the 16 KB first-line reading is gone), `page_form_names`
  (so the write rule asks the one form the page renders), `form_bind_refusal`'s
  current-page and tree reads, MCP `create_form` (the page's existing form, and
  a refusal when its front matter would still render another), the validator
  and `audit_site` (the form a `:::form` page delivers to). Bytes written raw
  (`upload_file`, the multipart upload, WebDAV PUT) are decoded as the processor
  will read them first (`text_as_processor_reads`).

The pin
: `t/lint/219` runs `page_form` and the processor's own parse over 39 texts
  (the shapes a hand-rolled parser gets wrong, a BOM, a no-break space, a
  non-ASCII key, front matter past 16 KB), over the same texts written to a site
  and read back (the processor through `read_file`, the manager through
  `form_bindings`' walk), and over 2,000 seeded generated front matters.

Every case where the answer changed
: `t/unit/manager/211`, each against n316's answer (tmp/q15f-was-check.out), a
  caller scoped to one domain: narrows across domains - N1, another domain's page
  with the name on the next line now binds there (the probe's case); widens
  inside its scope - W1 a second `form:` line, W2 a name the sanitiser
  completes, W3 a trailing comment, W4 a TT marker, W5 front matter past 16 KB,
  W6 a no-break space on a fence, each now binding the caller's page; narrows
  inside its scope - R1 the first of two `form:` lines, R2 a later `form: ''`,
  R3 a closing fence with no newline, R4 an empty value swallowing the line, R5
  a non-ASCII key swallowing it, on which the processor renders no such form.
  The write rule (t/unit/manager/210) now asks only the rendered form: a first
  `form:` line the processor does not render is no binding. The validator reads
  a form on the next line (V1).

Per-tool path arguments
: Each MCP tool that takes a content path declares it on its own definition,
  `path_args => [qw(...)]` in `lazysite-mcp.pl`'s `%TOOLS`, beside `path_aware`;
  `_path_args($tool)` is read by the three passes in `tools/call` (the
  themes/layouts capability override, the SM268 H4 carve-out pass, the SM155
  scope pass). `Manager::Common::@PATH_ARGS` is gone. `replace_text` declares
  `path`; its `old` and `new` are text. `t/lint/91` holds every argument of
  every tool (84) to a declaration or a reasoned exception (`%NOT_A_PATH`, and
  `%NOT_A_PATH_HERE` for a path-shaped name that is not a path on one tool:
  replace_text's old/new, the store `file` of the submission and export tools),
  fails a declared path argument missing from its schema and a path_aware tool
  declaring none, and asserts the three passes read the declaration.

No tool lost a check
: Before, every argument named path, to, from, slug, old or new was checked,
  on every tool; after, each tool's declaration. Per tool, before and after
  (tmp/q15f-path-args-before.out, -after.out): list_files, read_file,
  upload_file, write_file, read_brief, append_brief, delete_brief,
  preview_public_page, get_permissions, delete_file, set_permissions,
  create_form, validate_page, read_page, preview_page, page_status,
  search_files, invalidate_cache, list_versions, view_version,
  restore_version: path / path. copy_file, move_file: to, from / to, from.
  create_page: slug / slug. delete_page: path, slug / path, slug. rename_page:
  old, new / old, new. replace_text: path, old, new / path - the ruling. No
  other tool declares any of the six. An argument a tool does not declare is
  refused as unknown before its handler runs (SM278), so an undeclared name
  reaches no handler; it is now refused by that check rather than the scope
  pass.

Evidence (n317)
: t/integration/118: a grant scoped to sites/alpha replaces text inside its
  scope (including text shaped like a path outside it and like
  `lazysite/nav.conf`), is refused on a file outside it, and rename_page still
  checks old and new; then one call per declared (tool, argument) - 31 - each
  refused outside the scope, and replace_text's old/new not. t/lint/91, t/lint/16.
  Sabotage (tmp/q15f-sabotage-b.out): replace_text declaring old/new again, or
  nothing; rename_page or copy_file dropping one; the declaration read as empty;
  a declared argument the schema lacks; the scope pass back to one list - each
  fails 118, 91, 54 or 16.

Found in Q15f
: MCP `create_form` with an extensionless path (`/about`, as its schema
  describes) on an existing page replaces the page: it reads `/about`, finds
  nothing, and writes a fresh scaffold to `/about.md` (tmp/q15f-create-form-
  probe.out, on main's script). Not confinement; not changed. A `.url` page
  whose remote content names a form renders that form (process_url parses the
  fetched front matter; read, not run), and no walker sees it without
  fetching; not changed.

Q15g results (n318)
: The `create_form` replacement is fixed and filed as [[SM977]].

  **`.url` pages: not confirmed, no gap today.** tmp/q15g-url-form-probe.out
  stubs `Lazysite::Fetch::fetch_url` in-process and renders a `.url` page whose
  fetched text has `form: leads` and a `:::form` block. `process_url` parses
  the fetched front matter (its `form` is `leads`) but never calls
  `convert_fenced_form`. So no form is rendered, `:::form` stays literal text,
  `::: form` becomes `<div class="form">`, and no `leads.rules` is written. The
  same text as a local `.md` page renders the form and writes the rules
  (control). Includes render no forms either. The Q15f note above, "renders
  that form", was wrong. Recommended: pin it. An assertion that a `.url` page
  renders no form would make the rule "a `.url` page binds no form" explicit,
  so that adding `convert_fenced_form` to `process_url` for parity with
  `process_md` fails a test, and that change would then need the walker to
  judge fetched content.

  **Malformed UTF-8: they differ, and the write rule can be bypassed.**
  tmp/q15g-malformed-utf8-probe.out compares 3,078 texts that are not valid
  UTF-8, both hand-picked and from a seeded generator. On these texts:
  - `text_as_processor_reads` plus `page_form` disagrees with the processor's
    lax `:utf8` read on 1,827 of them. On 51 of those, the processor binds a
    form the raw-bytes rule does not read. For example, in
    `titre\xFF:\nform: leads`, the upgraded `\xFF` is `\w`, so the empty key
    swallows the next line.
  - The processor's own parse dies ("Malformed UTF-8 character (fatal)") on
    1,747 of them, and those pages render nothing.

  End to end (tmp/q15g-malformed-hijack-probe.out), a grant scoped to
  sites/alpha saves those bytes through `action_save_binary`, which
  `upload_file`, the multipart upload and WebDAV PUT also use. The rule reads
  no form, so the bytes are written. The processor renders the primary's
  registered, unbound form `orphan` on the page, the walker files it under
  alpha, and alpha now reaches `orphan` and its submissions. The same page as
  valid UTF-8 is refused. This is Q15e's hijack through a raw-bytes door.

  The walker misses no binding the processor makes (0 of 3,078), but it dies
  on 1,707 of these texts. One such page anywhere makes `form_bindings` die
  (tmp/q15g-walker-die-probe.out). Every form verb, and every write of a page
  binding a form, then errors for every confined caller: fail-closed, and a
  denial of service.

  Not changed. Recommended for a ruling:
  - Refuse a raw-bytes write of a `.md` page whose bytes are not valid UTF-8,
    at the three doors. The processor dies on, or misreads, every such page.
  - Have the walker treat a page whose reading dies as binding nothing,
    logged, as the processor renders nothing for it. Pages that reach the disk
    by other means (git, SSH) then cannot stop the rule.

# Found in Q15g, ruled

The release manager ruled the two Q15g findings above on 2026-10-09:

Malformed UTF-8 (security), "Refuse + walker skips"
: Refuse any raw-bytes .md write that is not valid UTF-8 on all three doors
  (action_save_binary → MCP upload_file; the multipart upload; WebDAV PUT - and
  any other raw-bytes path into a .md page you find; inventory with file:line),
  with a message saying so (and how to fix: save as UTF-8). A page whose
  reading dies is treated as binding nothing, and logged, so one bad page
  cannot stop the form walker (form_bindings and any other walker that parses
  every page's front matter - check the scan/registries walkers too: does one
  bad page kill a scan? if so, same rule, report it).

`.url` forms, "Pin with a test"
: A test asserting a .url page renders no form and writes no form rules; its
  failure message names form_bindings/the walker as what must account for .url
  pages first.

# The rulings, built (n321)

The rule
: `Manager::Common::page_bytes_refusal(rel, bytes)`: a `.md` page whose bytes
  are not valid UTF-8 (RFC 3629, strict: no overlong form, no surrogate, nothing
  past U+10FFFF; `invalid_utf8_offset`, through `Encode`) is refused for every
  caller, the operator included, kind `page-encoding-refused`, 415. The error
  names the page and the first invalid byte's offset, and says to save the file
  as UTF-8 and write it again. A file that is not a page is not asked.

Every raw-bytes path into a `.md` page, and how it asks
: - `Manager::Files::action_save_binary` (Files.pm:676, through
    `page_bytes_guard`, before the form rule reads the bytes): MCP `upload_file`
    (lazysite-mcp.pl:3123).
  - `Manager::Upload::action_file_upload`, per file (Upload.pm:317): the
    multipart upload (control API and cookie `file-upload`,
    lazysite-manager-api.pl:2312).
  - WebDAV `do_put` (lazysite-dav.pl:590), on the streamed body before the
    rename into place.
  - `Manager::SitePackage::package_apply` (SitePackage.pm:671, through
    `Files::page_bytes_tree_guard` over the extracted content):
    `site-backup-apply` and MCP `site_apply`. A package is bytes from outside,
    like an upload.
  Considered and not asked, with the reason: the text writes (`action_save` and
  everything through it - write_file, create_page, replace_text, copy_file,
  create_form, git-restore, restore_version, migrate-to-local) encode
  characters on the way out, so they cannot produce such a page; a move, a
  copy (control API, MCP `move_file`, WebDAV COPY/MOVE) carries bytes already on
  the disk and writes no caller's bytes, and the walker now judges such a page
  as the processor does; `backup-restore` puts back the instance's own snapshot
  and is refused to every confined caller (R1); `site-backup-upload` only stores
  a package, which reaches the content through the apply above.

The walkers
: `page_form_or_none(text, rel)` is `page_form` where a reading that dies is no
  form, logged (WARN, `form-rule`, the page's path and why). Asked by
  `form_bindings` and by the write rule for both the new text and the page as it
  stands (`page_form_names`), so a confined caller can still write over such a
  page. Measured over the Q15g probe's 3,091 malformed texts
  (tmp/q15h-malformed-recheck.out): the rule refuses all of them, and refuses
  none of five valid ones; the processor renders a form the walker does not file
  on none.

One bad page killed a scan, so the same rule (tmp/q15h-walkers-probe.before.out, .after.out)
: On n320, one such page under `/blog/` made the processor's `resolve_scan` and
  `scan_pages` die. A site whose `lazysite.conf` names a `scan:` source over
  `/blog/` answered 500 on every page, its home page included, and the sitemap
  answered 500. MCP `list_pages`, `audit_site` and `form_list` answered "Tool
  error" for the whole site. Now each walk leaves the page out and logs it
  (`_scan_page_unreadable` in the processor; `_each_page` with the tool's name
  in MCP); the page itself still answers 500, as the processor renders nothing
  for it. `rename_page`'s link rewrite did not die and is unchanged.

Found, not changed
: MCP `search_files` with such a page in its base answers with no JSON-RPC body
  at all: the matched line is not valid UTF-8 and the encoder dies. It is a
  walk over page text, not front matter, so it is outside the ruling; one page
  makes search unusable over its base. Recommended: the same rule (leave the
  page out, logged). `tools/lazysite-check.pl` walks pages too; not probed.

`.url` pages
: t/unit/processor/94 renders a `.url` page whose fetched text names `form:
  leads` and carries a `:::form` block: no form, no `leads.rules`; the same text
  as a `.md` page renders both (the control). Its failure message says that
  `form_bindings` must account for `.url` pages before they render forms.

Evidence (n321)
: t/integration/120 (the hijack probe as assertions - refused, nothing written,
  the grant still refused `orphan`'s submissions - then every door and the
  operator, a valid page written byte for byte, a `.txt` not asked);
  t/unit/manager/212 (the walk survives the page and finds every other binding,
  the reach and write rules answer, the log line); t/unit/processor/93 (the
  site, the scan page and the sitemap render; both walks log); t/unit/mcp/29
  (list_pages, audit_site, form_list); t/unit/processor/94; lint 114 (the rule
  on both write stacks and every raw-bytes door) and 115 (its refusal's shape).
  Sabotage (tmp/q15h-sabotage.pl, .log), each failing and passing restored by
  cp and cmp: the rule passing everything; each door not asking; the walker,
  its log line, and the write rule's current-page read back to `page_form`;
  each processor walk and each MCP walk without the guard; `process_url`
  converting `:::form` (94).

# Found in Q15h, ruled (Q15i)

The release manager ruled on 2026-10-09, in these words:

"Same rule" for search_files and other page walks
: MCP search_files skips a page that cannot be decoded, logs it, and answers
  for the rest (today it returns no JSON body at all). Then probe every page
  walk in tools/lazysite-check.pl (and any other walker over all pages you find
  in lib/, tools/, plugins/ - inventory with file:line) with one non-UTF-8 page
  present; wherever one bad page breaks the walk (dies, 500, no output, wrong
  totals), apply the same rule (skip + log, the rest answered).

# The ruling, built (n322)

search_files
: `_mcp_search` judges each file before it searches it (`_search_unreadable`,
  lazysite-mcp.pl, strictly through `Manager::Common::invalid_utf8_offset`, the
  rule `page_bytes_refusal` uses): a file that is not valid UTF-8 is left out
  whole, logged (WARN, `search_files`, its path and the first invalid byte's
  offset), and the rest of the base is answered. Every file the search reads is
  judged, not only `.md`: a `.txt` or `.html` that is not UTF-8 left the call
  without a body the same way. `delete_page`'s `still_referenced_in` is this
  search and is answered again.

Every page walk, probed with one page that is not UTF-8 (tmp/q15i-check-probe.out, tmp/q15i-more-probe.before.out, .after.out, tmp/q15i-audit-variants.before.out, tmp/q15i-mcp-probe.after-search.out)
: Broke, and now skip and log:
  - MCP `search_files` (`_mcp_search`, lazysite-mcp.pl:2108; read 2159): no
    JSON-RPC body. Fixed as above (t/unit/mcp/29).
  - The processor's `resolve_scan` excerpt (lazysite-processor/registries.pm:346):
    Q15h guarded the front matter; the excerpt reads the BODY. A page whose
    front matter is UTF-8 and whose body is not made every page listing the
    scan answer 500. Now inside the same skip, logged as "a page whose body
    cannot be read" (t/unit/processor/93).
  - `tools/lazysite-validate.pl` over a list of pages (its loop, :89;
    `Lazysite::Validate::validate_file`, Validate.pm:638): one such file died
    in the checks - exit 255, nothing printed for any file, `--json` included.
    `validate_file` already reports a file it cannot open as an `unreadable`
    issue and carries on; a file that is not UTF-8 is now the same, with the
    offset and how to fix it, and every other file is checked (t/tools/82).
    The one judgement call: in a validator the "log" is the file's own result
    line, counted as an issue, so the run does not exit 0 over a file it did
    not check.

  Already under the rule (Q15h, n321), re-probed: `form_bindings` and
  `form_bind_tree_refusal` (Manager/Common.pm:782, 1067), MCP `list_pages`,
  `audit_site` and `form_list` (`_each_page`, lazysite-mcp.pl:2405), the
  processor's `resolve_scan` front matter and `scan_pages` (registries.pm:302,
  967).

  Survive, unchanged (the walk answers, totals true):
  - `tools/lazysite-check.pl`: its three page-reading walks - content
    provenance (:1250), uncompilable form patterns (:2081), double-escaped db
    templates (:2139) - read bytes with no decoding layer, so no regex dies; the
    page is counted as any other, holding the shapes checked for. Same exit and
    report with and without it, but for the page's own entries (the probe makes
    it hit all three).
  - `plugins/audit.pl` (`collect_audit_results`, :133; `extract_links` :539):
    eight placements of the bad bytes (front matter, body, beside a link, in a
    fence, in a code span, Latin-1 text, a truncated sequence, lone
    continuation bytes) - exit 0 and its JSON each time; the read warns and
    continues.
  - MCP `rename_page` with `update_links` (`_rewrite_links`, lazysite-mcp.pl:3385),
    the link beside the bad bytes included: answers, and rewrites the link in
    that page too.
  - Read as raw bytes, so nothing to die: `Capabilities::_scan_docs`
    (Capabilities.pm:762), `Aliases::reindex_move`/`reindex_copy`
    (Aliases.pm:321, 336), git-sync's alias reindex after a pull
    (plugins/git-sync.pl:538), `Lang::lang_status` (Lang.pm:143),
    `Files::page_bytes_tree_guard` (Files.pm:612, the refusal itself).

  Walks that read names or stat only, and walks over stores that are not
  pages (themes, layouts, forms, briefs, data, logs) were inventoried and are
  outside the question; the repository's own build tools likewise.

Found, not changed
: - MCP `read_page` (and so any single-page read that returns the text) on
    such a page answers with no JSON-RPC body: the encoder dies on the page's
    own text. One page, not a walk - as the processor answers 500 for the page
    itself. Recommended: the same answer as a page it cannot read.
  - Q15h's "a text write cannot produce such a page" holds for a caller's
    text, not for a read-modify-write of a page already not UTF-8:
    `_rewrite_links` and `replace_text` read it through the lax layer and save
    it back with its invalid bytes kept (tmp/q15i-mcp-probe2.after-search.out).
    No new page becomes invalid; recorded so the claim is not read wider.
  - The scan's `read_file` (registries.pm:302, 957) dies on a page it cannot
    open (permissions), outside the guard. Not bytes; outside this ruling.
  - `_each_page` stops after 1,000 pages without saying so, so `list_pages`'
    count and `audit_site`'s pages stop there. Not this ruling.
  - n321's work-plan edit had replaced the Q15g row with a literal `$1`;
    restored (n322).

Evidence (n322)
: t/unit/mcp/29 (search_files answers, without the page, which is logged with
  its offset; a match before the bad byte is not answered), t/unit/processor/93
  (the body case, through the processor and in process), t/tools/82 (a run of
  three files, one not UTF-8: exit 1, JSON, a result per file). Sabotage
  (tmp/q15i-sabotage.sh, .log), each failing and passing restored by cp and
  cmp: the search not judging, judging nothing, logging nothing; the excerpt's
  guard a plain block (the page answers 500 again); the validator not judging.

# Found in Q15i, ruled (Q15j)

The release manager ruled on 2026-10-10, in these words:

Validator exit, "Exit 1"
: n322's behaviour stands (an unreadable file is an issue; the run exits 1).
  Record only.

"Fix both"
: (a) MCP read_page on a non-UTF-8 page returns a proper error naming the
  encoding problem (with the offset and how to fix), like any page it cannot
  read, instead of an empty body; check sibling single-page MCP reads
  (read_file, preview_page, page_status, validate_page, view_version...) for
  the same empty-body failure and give each the same answer (list them).
  (b) MCP's page walk (_each_page: list_pages, audit_site, form_list, and any
  other caller) reports `truncated: true` and the cap in its answer when it
  stops at 1,000 pages, so a count is never silently capped; tool
  descriptions say so.

# The rulings, built (n325)

(a) The answer
: `Manager::Common::page_read_refusal(rel, text, what?, remedy?)`: text read
  through the lax `:utf8` layer holds the file's own bytes, which
  `utf8::encode` hands back, and `invalid_utf8_offset` (the write rule's
  test) finds the first invalid one. The error names the page (or file),
  that it is not valid UTF-8, the offset, that the processor renders nothing
  for it, and how to fix it; kind `page-encoding-refused`, audited as `kind:
  cause - remedy` (lint 115). MCP's `_unreadable_text` asks it of the text a
  handler has already read, so scope, the ACL, a blocked path and not-found
  still answer first and a page the caller may not read is not described.

(a) Every single-page MCP read, probed with a page whose body and one whose
front matter is not UTF-8 (tmp/q15j-single-page-probe.before.out, .after.out)
: Broke, and now give the answer:
  - `read_page`, `read_file` (a `.txt` too): no JSON-RPC body.
  - `view_version`: no body when the recorded version is not UTF-8 ("Version
    1a2b3c4 of the page ..., pick another version") or the current file is,
    which the diff carries ("The current version of the page ..., or restore
    a recorded version").
  - `read_brief`: no body for a store entry that is not UTF-8 ("The brief of
    the page ...", the store entry's path in the remedy).
  - `preview_page`: no body, or the processor's bare 500 (with content history
    on). The page's source is judged when the render is not UTF-8 or answered
    500. HTML that is still not UTF-8 when the page is is named as the
    render's: no file the processor reads was found that does it (an include
    and `nav.conf` answer 500, a layout gets U+FFFD from TT), so it is a net,
    tested with a stub processor.
  - `validate_page`: "Tool error" on a bad body, and `valid: true` on a bad
    front matter.
  - `create_form`: "Tool error".
  - `preview_public_page` answered, "The processor failed to render"; a
    failed render on such a page now names the cause too.
  Answer, unchanged: `page_status`, `get_permissions`, `list_versions`,
  `invalidate_cache` (read no text); `search_files` (Q15i).

(b) The cap
: `_each_page` returns whether a page past `$PAGE_CAP` (1,000) was left
  unwalked. Its callers: `list_pages` and `audit_site` answer `truncated`
  (false, or true with `page_cap`); `rename_page` with `update_links` does
  too, since its link rewrite is the same walk and left the links in pages
  past the cap unrewritten. `form_list` is not a caller: its binding walk
  (`form_bindings`) has no cap. The three descriptions and
  starter/docs/ai-connector-tools.md say so.

Evidence (n325)
: t/unit/mcp/31 (each tool and case above, the offset, the remedy, the audit
  detail; not-found and a blocked path answer first; a UTF-8 page reads as
  before), t/unit/mcp/32 (1,000 pages: truncated false; 1,001: truncated true,
  the cap, 1,000 walked, a link left unrewritten; the descriptions), lint 115,
  lint 114 (the read rule exempt as a read). Sabotage (tmp/q15j-sabotage.pl,
  .log), 19 cases, each failing and passing restored by cp and cmp: the rule
  passing everything or judging decoded text; each tool's guard removed; the
  walk silent at the cap or off by one; each caller's keys dropped; a
  description silent.

Found in Q15j, not changed
: - `restore_version` of a recorded version that is not UTF-8 writes its bytes
    back as they were (tmp/q15j-single-page-probe.after.out, hist.md): a text
    write producing such a page, as Q15i found for a read-modify-write. A
    write; outside this ruling.
  - `read_nav` on a `nav.conf` that is not UTF-8 answers "Tool error: read_nav"
    (a body; the navigation file, not a page). Not changed.

# Found in Q15j, ruled (Q15k)

The release manager ruled on 2026-10-10, in these words:

"Fix both"
: (1) MCP restore_version (and the control API's equivalent git-restore/restore
  path, if it can write a recorded non-UTF-8 version back) refuses a recorded
  version that is not valid UTF-8 with the same encoding error
  (page_read_refusal / page_bytes_refusal shape) and leaves the page as it is;
  (2) read_nav (MCP) and nav-read (API) on a non-UTF-8 nav.conf answer the
  encoding error naming nav.conf, not "Tool error". Tests + sabotage.

# The rulings, built (n327)

(1) The restore
: The control API's `git-restore` could: it and MCP `restore_version` call the
  one `Manager::Files::action_git_restore`, which wrote the version through
  `action_save` as history read it - through the lax `:utf8` layer, so the
  version's own bytes (t/integration/121 before the change: both surfaces
  answered ok and the file held the bad bytes). It now asks `page_read_refusal`
  of the version before anything is written: kind `page-encoding-refused`,
  "Version 1a2b3c4 of the page ...", the offset, and how to fix it (restore
  another version, or save it as UTF-8 and write it whole), saying nothing was
  restored. The file is left as it is and no restore is recorded; an invalid or
  missing version still answers first. The rule is asked of every text file a
  restore reaches, as view_version's of the same version is, not only of `.md`
  pages: the version cannot be viewed, so it is not restored blind.

(2) The nav read
: `Manager::Nav::action_nav_read`, the one implementation of both reads, reads
  `nav.conf`'s bytes after the reach rule and answers a file that is not UTF-8
  with `page_read_refusal`: "The file 'lazysite/nav.conf' is not valid UTF-8",
  the offset, and how to fix it (`set_nav`, or save it as UTF-8 and write it
  whole over WebDAV). Before, MCP answered "Tool error: read_nav" and the
  control API's `nav-read` no body at all. A UTF-8 file is decoded and read as
  before.

Evidence (n327)
: t/integration/121 (both surfaces for each; the file unchanged and no commit
  after a refused restore; a UTF-8 version restores byte for byte; a missing
  version answers for its own reason; a UTF-8 nav reads with its labels
  decoded). starter/docs/ai-connector-tools.md and lint 114's exemption name
  the two new askers. Sabotage (tmp/q15k-sabotage.pl, .log), 5 cases, each
  failing and passing restored by cp and cmp: each guard removed, each remedy
  silent, the nav read not decoding.

# Related

[[SM975]], [[SM943]], [[SM578]], [[SM647]], [[SM648]], [[SM802]].
