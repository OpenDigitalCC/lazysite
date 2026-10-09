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
status-note: "SHIPPED (PENDING): ruled 2026-10-09 \"One rule, fix all\" - a confined caller reaches only its own domains (n312, lint 218). R1-R4 built (n314), F1-F4 (n315). \"Refuse new binding\" built (n316): no content write by a confined caller newly binds a form it does not reach. F3 old exports ruled: no code. t/integration/112, 114-117."
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
  (tmp/q15e-sabotage.pl, 22 cases).

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

# Related

[[SM975]], [[SM943]], [[SM578]], [[SM647]], [[SM648]], [[SM802]].
