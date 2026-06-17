---
title: "SM071: WebDAV theme and layout management"
subtitle: "Staged authoring with preview, activation, sub-user accounts, and a token-driven control API"
brand: plain
standard-margins: true
---

Status
: Draft specification (2026-06-17). Design only, no implementation in the tree. Extends SM070.

Author
: Claude (specification), with Stuart Mackintosh (design direction).

Target
: lazysite ≥ current main (post-SM070).

Constraints
: All design points are ratified. `[DEFER]` marks work deliberately left for a later cycle. No backward compatibility - SM071 targets greenfield sites only; no migration of existing settings, locks, or themes is provided.

## 1. Summary

SM070 gave lazysite a WebDAV endpoint for publishing content - individual
pages, direct to the live docroot. SM071 extends the same auth and identity
plane to themes and layouts, but with a write model suited to bundles rather
than single files: a staged authoring lifecycle, plus a token-driven control
API for the operations that are not file-shaped. It also adds a delegated
sub-user account model so that users can create and manage their own automated
partners.

The lifecycle is: edit an inactive artifact, preview it against the live site
for your session only, validate-and-activate, auto-backup the outgoing version,
and back out by re-selecting the backup.

The motivating workflow is a designer who already has an AI partner producing
HTML and CSS. SM071 turns that output into a direct implementation step - the
partner (and a human with a DAV mount) edits theme and layout files in place,
previews the result, and promotes it to live, all under one credential with a
clean back-out.

::: widebox
Drafts, the live theme, and backups are the same kind of object - an entry in
the existing themes or layouts list, distinguished only by a pointer
(`theme:` / `layout:` in `lazysite.conf`) and metadata. A draft is an inactive
artifact, editable over DAV; live is whichever one the pointer names, read-only
over DAV; a backup is an inactive snapshot, auto-created at switch time; and
back-out is simply `activate` on a backup. No new verbs.
:::

Because of that collapse, SM071 reuses the SM070 lock store, the SM070 per-user
settings and credential machinery, and the existing manager theme and layout
actions (`theme-upload`, `theme-activate`, `themes-list-all`,
`layouts-install`) almost wholesale. The genuinely new surface is small: a
preview render path in the processor, a content-hash manifest, a sub-user
account and token model, and the per-object read-only rule in
`lazysite-dav.pl`.

### Why staging, not direct-to-live

A theme or layout is valid only as a set - a theme needs `theme.json` with a
non-empty `layouts[]`; a layout needs a compilable `layout.tt`. The processor
reads `theme.json` on every render, so file-by-file DAV writes straight to the
live theme would make a half-deployed, broken theme go live mid-upload. Staging
confines edits to an inactive artifact and gates the live transition on
validation.

### Why a control API alongside DAV

Switching a theme, previewing, setting config, and exchanging a pairing key for
a token are not file operations. Forcing them through WebDAV verbs is awkward. A
small JSON control API authenticated by the same credentials DAV already
verifies is the right shape, and lets the existing manager logic be reused
rather than reimplemented.

### Themes and layouts share one lifecycle

The lifecycle is artifact-type-parameterised (`theme` or `layout`). Nothing in
stage, preview, activate, or backup is theme-specific. Layouts add four wrinkles
(nesting, switch-forces-compatible-theme, a separate capability, a weaker
validation gate) covered in section 3.12, but otherwise ride the same code.

## 2. Scope

In scope:

- A delegated sub-user account model: equal users, two delegable permissions
  (`create_sub_users`, `delegate_sub_user_creation`), per-account provenance
  (`created_by`, `created_at`) plus a mutable `managed_by`, and creator-scoped
  management including disable, enable, cascade-disable, and reassign of a
  sub-tree (section 3.1).
- New per-user capability flags `manage_themes`, `manage_layouts`,
  `manage_config` (all default off), beside SM070's `webdav` / `ui` /
  `dav_scope`.
- A per-object read-only rule in `lazysite-dav.pl`: the active theme and active
  layout are read-only over DAV; all other themes and layouts are writable,
  gated by capability. This relaxes SM070's blanket `lazysite/` denial only for
  `lazysite/layouts/**`, per object.
- A content-hash (SHA-256) manifest of any theme or layout, exposed as a JSON
  control-API action and an optional custom DAV live property on PROPFIND.
- Preview rendering in the processor: a signed, short-lived, per-session cookie
  selects an alternative theme and layout for that session only, cache-bypassed.
- Activate-with-backup: activation validates, snapshots the outgoing artifact
  into a backup entry, flips the pointer, and invalidates cache. Retention via
  the existing `backup_retention` key (default 3).
- A control API extending `lazysite-manager-api.pl` with a token-auth
  front-path, CSRF-exempt for token requests, capability-gated: manifest,
  validate, activate, preview-grant, backup-list/prune, account
  create/disable/reassign, and an allowlisted `config-set`.
- Token lifecycle (model A): a single-use pairing key exchanged on first
  connection for a short-lived, rotating access token with `expires_at`.
- Bootstrap: a `partner-create` command and a downloadable onboarding file
  offered from the manager Users page for any user holding an automation
  credential.
- Rate limiting and a documented retry contract.
- Routing for the control API (Hestia template, Docker note, dev server).
- Tests, docs, and SBOM per the standing non-functional close-out.

Out of scope:

- Site content publishing keeps SM070's direct-PUT-to-live model. SM071 adds no
  staging for content. The asymmetry is intentional and documented.
- A general-purpose config editor over the API. `config-set` writes an allowlist
  only (section 3.13).
- Backward compatibility. SM071 targets greenfield sites only; no migration of
  existing settings, locks, or themes is required or provided.
- `[DEFER]` Rich layout metadata or a layout manifest schema beyond
  "`layout.tt` compiles".
- `[DEFER]` Multi-draft merge and diff tooling. Collaboration is shared
  candidate plus DAV locks plus manifest; true three-way merge is out.

## 3. Design

### 3.1 Account model and sub-users

Users are equal. There is no privileged account class among these accounts;
authority comes from two delegable permissions and from the creator-to-sub-user
relationship, not from a tier. (This sits alongside the existing operator auth
in `manager_groups`, which is unchanged.)

The model:

Sub-users and responsibility
: Any account may be created as a sub-user of another. The responsible user may
  manage the sub-users beneath it, transitively down the sub-tree. A sub-user is
  an ordinary user in every other respect.

create_sub_users
: Permission to create sub-users. Without it a user has no sub-users.

delegate_sub_user_creation
: Permission, when creating a sub-user, to also grant that sub-user
  `create_sub_users`. This is the right to pass on the right - recursive
  delegation control. A user with `create_sub_users` but not this permission can
  create sub-users that cannot themselves create sub-users.

created_by, created_at
: Immutable provenance recorded at creation - who originally created the account
  and when. For an automated partner, `created_by` answers "whose partner was
  this originally?"

managed_by
: The current responsible parent. Defaults to `created_by`; changed only by
  reassign. The `managed_by` edges form the live sub-user tree that management
  and cascade operations walk and authorise against.

Management actions are inherent to a responsible parent over its own sub-tree
(they are not separately granted permissions; authorisation is "the actor is an
ancestor of the target via `managed_by`"):

disable user / enable user
: Disable or re-enable a single sub-user. A disabled user fails auth everywhere
  (DAV, control API, manager UI) until re-enabled.

disable sub-users
: Cascade. Iterate the actor's descendant sub-tree and disable every account in
  it, leaving the tree structure intact so a later enable can reverse it.

reassign sub-user
: Move a sub-user (optionally with its own sub-tree) to a different parent by
  setting `managed_by` to the new parent; `created_by` is left untouched as
  immutable provenance, and the move is recorded. Used when a person leaves or a
  partner is handed over. Authorises on ancestry of the sub-user being moved.

Onboarding (section 3.11) is available for any user that holds a generated
automation credential, not for a special account class - consistent with users
being equal.

### 3.2 Capability flags

Extend the SM070 settings store. New keys, all default off:

```datatable
columns: Flag | Default | Grants
widths: 4cm | 2.2cm | X
bold: 1
tone: medium
---
manage_themes | off | Stage, preview, activate, and backup themes, including writing the theme: pointer.
manage_layouts | off | The same for layouts, including the layout: pointer.
manage_config | off | Write the broader config-set allowlist (section 3.13).
```

Each `manage_*` flag implies the right to write its own pointer key - you cannot
usefully manage themes without switching them - so activation is not separately
gated behind `manage_config`. A designer account typically gets `manage_themes`
only; a site builder also gets `manage_layouts`; `manage_config` is granted
sparingly. All three surface as checkboxes on the manager Users page beside the
existing `webdav` / `ui` toggles, along with the sub-user permissions from
section 3.1.

### 3.3 The artifact lifecycle

Identical for theme and layout (section 3.12 for layout deltas):

1. Read live. The active artifact is readable over DAV so the partner and a
   mounted human see the deployed truth, including each other's manual edits.
2. Edit a candidate. Any inactive artifact is writable over DAV, file-by-file.
   Shared staging means collaborators editing the same inactive candidate;
   independent experiments mean separate candidates.
3. Diff via manifest. Clients pull the content-hash manifest (section 3.5) to
   know what changed and whether live drifted.
4. Preview. Render the live site against the candidate for this session only
   (section 3.6), cache-bypassed, to verify before going live.
5. Activate. Validate the candidate; if it passes, snapshot the outgoing live
   artifact (section 3.7), flip the pointer, invalidate cache. Activation is
   conditional on a base manifest the client supplies: if live drifted since the
   client last synced, activate returns 409 so the client re-reads and retries.
6. Back out. `activate` a backup entry; optionally snapshot current-live first
   so nothing is lost.
7. Delete. Existing `theme-delete` or layout deletion.

There is no heavy staging-to-live promotion: live is never written file-by-file.
Validation lives at the flip, where correctness matters.

### 3.4 DAV exposure, the per-object read-only rule, and dav_scope

SM070's `authorise()` blanket-denies the whole `lazysite/` subtree. SM071
relaxes this only for `lazysite/layouts/**`, evaluated per object against the
active pointers read from `lazysite.conf`:

```datatable
columns: Path | Read | Write
widths: X | 3.2cm | 5.5cm
bold: 1
tone: medium
---
lazysite/layouts/<L>/layout.tt and layout assets | manage_layouts | manage_layouts, iff <L> is not the active layout
lazysite/layouts/<L>/themes/<T>/** | manage_themes | manage_themes, iff <T> is not the active theme
everything else under lazysite/ | denied | denied
```

A theme under the live layout stays editable whilst it is itself inactive, which
is the common case (tweak a theme without disturbing the layout skeleton).

How `dav_scope` fits in - the two namespaces are governed differently:

Content namespace
: `dav_scope` confines where a user's content writes may land (SM070 behaviour).
  It is a docroot-relative path prefix; a scoped user can only PUT, MKCOL, MOVE,
  and DELETE pages beneath it. This is the right control for content because
  content is addressed by its live URL path.

Theme and layout namespace
: Reachability is governed by the capability flags plus the per-object
  active/inactive rule above, and is independent of `dav_scope`. A scoped
  content user can still manage whole themes, because a theme is an artifact in
  a separate list, not a path in the site the scope describes. If a deployment
  wants to also fence which themes a user may touch, that is a separate future
  control, not an overload of the content path scope.

In short: `dav_scope` answers "which part of the site may this user publish
into", whereas `manage_themes` / `manage_layouts` answer "may this user author
the look at all". They are orthogonal.

### 3.5 Content-hash manifest and change detection

The SM070 ETag is `dev-ino-mtime-size`, a weak validator: it changes on a
`touch` and differs between two copies of identical bytes, so it cannot answer
"did the content change" or "does the candidate match live". SM071 adds a
SHA-256 content manifest (Digest::SHA is already loaded in `lazysite-dav.pl`,
mirroring the `tools/build-manifest.pl` pattern):

```json
{ "<relpath>": { "sha256": "...", "size": 0, "mtime": 0 } }
```

Exposed two ways:

- A control-API action `artifact-manifest` (token-auth) returns the manifest for
  a named theme or layout, and for live. One round-trip and a client knows
  exactly which files to PUT.
- A custom DAV live property `lzs:sha256` on PROPFIND, so a vanilla DAV mount
  gets the same identity without a side channel.

This enables three-way awareness for clobber-safety: `base` (the live manifest
the client last synced from), `live-now` (may have drifted from a human edit),
and `candidate` (the client's edits). The client diffs locally, PUTs only what
changed, and detects drift. The base manifest is what `activate` checks
(section 3.3, step 5).

### 3.6 Preview rendering (built first - see section 5)

This is the only change that reaches the main render path, and the rationale for
building it first is in the implementation plan. Mechanism:

- A signed, short-lived preview cookie (HMAC with the existing secret machinery,
  the same primitive as the auth cookie and CSRF token), payload of layout,
  theme, user, and expiry.
- Minted by a manager-UI Preview button or the control-API `preview-grant`
  action; returns the cookie or a preview URL.
- The processor's theme and layout resolution: if a valid, unexpired preview
  cookie is present, render with its layout and theme instead of the
  `lazysite.conf` pointers.
- Cache discipline is exactly what protected pages already do:
  `Cache-Control: no-store, private`, and preview requests neither read nor write
  the shared cache. A preview never pollutes the live cache; a live visitor
  never sees a preview render.
- Only an authorised user can mint a preview cookie (server-signed, user-bound,
  expiring), so an anonymous visitor cannot force a broken theme.

Because preview only needs the existing manager auth, the secret machinery, and
the processor, it has no dependency on the DAV, manifest, or token work and can
ship and be regression-tested on its own.

### 3.7 Activate, backup-on-switch, retention

On `activate` of a theme or layout:

1. Validate the candidate (section 3.12 for layout rules; a theme needs
   `theme.json` present with a non-empty `layouts[]`). This also closes the
   current `theme-activate` gap, which today flips `theme:` with no validity
   check.
2. Check the client's supplied base manifest against live; 409 on drift.
3. Snapshot the outgoing live artifact: copy its directory to
   `<name>-backup-<UTCstamp>` under the same layout's `themes/` (or the layouts
   directory for a layout), with metadata (`backup_of`, `backup_at`) so the UI
   can badge and group backups.
4. Flip the pointer (`theme:` / `layout:`), reusing `theme-activate`'s
   conf-rewrite and cache-invalidate, which are already implemented.
5. Prune backups beyond `backup_retention` (existing key, default 3, 0 means
   keep all), oldest first.

Back-out is `activate` on a backup entry, with an optional snapshot-current-first
flag.

### 3.8 Locking

Reuse the SM070 class-2 lock store, already interoperable between manager and
DAV:

- Candidate files use ordinary DAV `LOCK` for exclusive editing.
- Activate takes a short artifact-level exclusive lock across validate,
  snapshot, flip, and invalidate, so two activations cannot interleave and a
  manager-UI edit of the live artifact cannot collide mid-flip. If the artifact
  is locked, activate returns 423 Locked and the client retries per section 3.9.

### 3.9 Rate limiting and the retry contract

Two distinct mechanisms, kept separate:

Auth-failure limiter
: SM070's per-IP `.dav-rate.db` brute-force guard, extended to the control-API
  endpoint. Security control.

Volume throttle
: A per-token token-bucket with a generous burst. A real theme deploy is many
  PUTs, so per-token (known identity) beats per-IP (a human and a partner may
  share an IP). Initial defaults, tunable at implementation: burst 200, refill
  20 per second.

The retry contract is a server and client handshake, documented in `webdav.md`:
the server emits `Retry-After` on 429 (throttle), 423 (locked), and 503; clients
honour it with exponential backoff and jitter.

### 3.10 Token lifecycle (model A)

Today's `lzs_` tokens never expire. SM071 adds expiry and rotation:

Pairing key
: `partner-create` mints a single-use code, not a token. This is what gets
  copied into the partner's setup.

Exchange
: First connection POSTs the pairing key to a `token-exchange` action and
  receives a short-lived access token with `expires_at`; the pairing key is then
  invalidated.

Rotation
: The access token has a TTL; the client refreshes before expiry via a
  `token-rotate` action that mints a new token and grace-expires the old. A
  leaked token self-expires; a leaked pairing key is already spent.

Token records in the settings store gain `expires_at` and rotation state; the
DAV and API auth path checks expiry. Initial defaults, tunable at
implementation: access token 24h, refresh window 7d, pairing key 15 min.

### 3.11 Bootstrap, partner accounts, and the onboarding file

A user with `create_sub_users` can create a sub-user from the CLI or the manager
UI:

```bash
lazysite-users.pl partner-create <name> [--themes] [--layouts] [--config] [--scope PATH]
```

This creates a sub-user (`created_by` and `managed_by` set to the creating
user), sets the requested capability flags (default `webdav` plus
`manage_themes`), records `created_at`, and mints a pairing key. If the creator
holds `delegate_sub_user_creation`, it may also grant the new sub-user
`create_sub_users`.

The onboarding file is offered as a download from the manager Users page,
positioned next to the username, for any user holding a generated automation
credential. It is generated, not committed, and contains the DAV base URL, the
control-API base URL, the pairing key, the lifecycle (read live, edit candidate,
preview, activate), the manifest endpoint, and the retry contract. Dropping that
file into the partner's project makes the partnership live.

The file is named generically, for example `automated-partner-<name>.md`, not
after any one vendor. We expect AI partners to be common, but the feature is
built for the user's choice of partner.

### 3.12 Layout-specific rules

1. Per-object read-only (section 3.4): the active layout's `layout.tt` is
   protected, but its inactive nested themes stay editable.
2. Switch forces a compatible pair: a theme is valid only under the layouts its
   `theme.json` `layouts[]` declares. Activating a candidate layout must either
   confirm the current theme lists the new layout, or require a compatible theme
   named in the same activate call. This is the one path strictly more involved
   than theme activation.
3. Separate capability `manage_layouts`: a broken `layout.tt` breaks every page,
   whereas a broken theme is mostly cosmetic, so the structural layer is granted
   independently.
4. Validation gate: layout activate requires `layout.tt` present and compilable
   as a Template Toolkit template. Richer layout metadata is `[DEFER]`.

### 3.13 Control API surface

Extend `lazysite-manager-api.pl` with a token-auth front-path: authenticate
`Authorization: Basic lzs_…` against the settings store (reusing SM070's
`verify_password` and the per-IP limiter), exempt token requests from the CSRF
gate (no cookie means no ambient authority means no CSRF vector), then enforce
the relevant capability flag per action. New or extended actions:

- `artifact-manifest` (section 3.5; read, `manage_themes` / `manage_layouts`).
- `artifact-validate` - dry-run the activate validation.
- `theme-activate` / `layout-activate` - extended with validation, the
  base-manifest conditional, and backup-on-switch (section 3.7).
- `preview-grant` - mint a preview cookie or URL (section 3.6).
- `backup-list` / `backup-prune` - manage snapshot entries.
- `config-set` - write an allowlist only: `theme` and `layout` (covered by the
  manage flags) and, under `manage_config`, `site_name`. It excludes
  security-sensitive keys (`webdav_enabled`, `dav_allow_insecure`, `manager*`,
  `auth_*`) so a deploy token can never escalate.
- `token-exchange` / `token-rotate` (section 3.10).
- `account-create` - create a sub-user, gated by `create_sub_users`, recording
  provenance and optionally granting `create_sub_users` when the creator holds
  `delegate_sub_user_creation` (section 3.1).
- `account-disable` / `account-enable` - single or cascade, gated by the actor
  being an ancestor of the target via `managed_by` (section 3.1).
- `account-reassign` - move a sub-user (optionally its sub-tree) to a new parent
  by updating `managed_by`; gated by ancestry of the source (section 3.1).

Reuse SM070's dev-server routing pattern and Hestia ScriptAlias; the control API
is one endpoint alongside `/dav`.

## 4. Security considerations

Escalation containment
: The `config-set` allowlist excludes every key that could widen access
  (transport, endpoint enable, manager, auth). This is the primary new trust
  boundary.

Delegation containment
: `create_sub_users` and `delegate_sub_user_creation` are separate, so the right
  to create sub-users and the right to pass that right on are independently
  controlled. A sub-tree cannot grow creation rights it was never delegated.

Creator-scoped management
: Disable, enable, cascade-disable, and reassign authorise on ancestry via
  `managed_by` - the actor must be an ancestor of the target. A user cannot
  manage accounts outside its own sub-tree. Reassign updates `managed_by` whilst
  `created_by` stays as immutable provenance.

CSRF
: Token requests are CSRF-exempt because they carry no cookie. The Basic-auth
  front-path must reject any request that also carries a manager cookie from
  being treated as a token request, so the exemption cannot be used to bypass
  CSRF for a browser session.

Read-only live
: The per-object rule keeps the active theme and layout unwritable over DAV,
  preserving the "live is never half-written" invariant; only the validated
  activate flip changes live.

Preview cannot be forced
: Preview cookies are server-signed, user-bound, and short-lived; an attacker
  cannot push a broken theme onto a victim's session.

Token leak posture
: Model A's short-lived rotating tokens and single-use pairing keys bound the
  blast radius of a leak.

Account provenance
: `created_by` and `created_at` give an immutable audit trail of who created
  each account; `managed_by` records current responsibility.

Lock interop
: The artifact-level activate lock prevents manager-UI, DAV, and API three-way
  clobbering, reusing the audited SM070 store.

Backups are inert
: Snapshots are inactive list entries, never rendered unless explicitly
  activated.

Self-contained-script convention
: Validation and manifest helpers are duplicated into `lazysite-dav.pl` rather
  than shared, per the existing codebase ethos; the lock-record and manifest
  formats are documented cross-script contracts.

## 5. Implementation plan (three phases, branch-and-review per phase)

The work is grouped into three phases. Phase 1 (preview) is built and
regression-tested on its own because it is the only change that touches the main
processor render path - the highest regression risk - and it is independently
useful. Phase 2 delivers the complete user and auth foundation, so that
identity, capabilities, and tokens are ready before any theme or layout code is
written. Phase 3 is the theme and layout management itself, building on phases 1
and 2.

Per-phase workflow:

- Each phase is developed on its own branch (`claude/sm071-<phase>`), one logical
  change per commit (SM063 contract), clean tree before hand-off.
- Each phase ends with the full five-dimension non-functional close-out
  (coverage, quality, performance, security, docs) and a `lazysite-layouts`
  alignment review (analyse whether the layouts/themes repo needs matching work).
- The phase branch is then handed off for vcs-review. The operator reviews,
  commits the phase, and cuts a release before the next phase begins. SM071 work
  uses this branch-and-review flow rather than lazysite's uncommitted-tree
  contract; Claude does not push (no push access).

Within each phase the code rows below are one commit each; the closing two rows
are the per-phase wrap done before hand-off.

### Phase 1 - Preview (branch claude/sm071-preview)

```datatable
columns: Step | Work | Tests / output
widths: 1.4cm | X | 6cm
bold: 1
tone: medium
---
1.1 | Processor render override driven by a signed preview cookie. | Preview renders the candidate theme/layout; live pointers untouched.
1.2 | Cache discipline: preview requests no-store, no shared-cache read or write. | Preview never caches; live cache uncontaminated; regression pass on the render path.
1.3 | preview-grant minting (manager UI button first; user-bound, expiring). | Only authorised users mint; anonymous cannot set; expiry honoured.
1.W1 | Five-dimension non-functional close-out. | Coverage/quality/perf/security/docs recorded.
1.W2 | lazysite-layouts alignment review; clean tree; hand off for vcs-review. | Alignment findings noted; branch ready.
```

### Phase 2 - User and auth foundation (branch claude/sm071-user-auth)

```datatable
columns: Step | Work | Tests / output
widths: 1.4cm | X | 6cm
bold: 1
tone: medium
---
2.1 | Sub-user model: created_by/created_at provenance and managed_by on every account. | Provenance recorded; managed_by defaults to created_by; tree reconstructable.
2.2 | Permissions create_sub_users and delegate_sub_user_creation; account-create. | Creation gated; delegation only when held; non-delegated sub-users cannot create.
2.3 | Disable/enable single user; cascade disable-sub-users; ancestry authorisation. | Disabled user fails auth everywhere; cascade hits the whole sub-tree; out-of-tree management refused.
2.4 | Reassign sub-user (optionally its sub-tree) to a new parent via managed_by. | managed_by updated; created_by untouched; reassign authorised on ancestry.
2.5 | Capability flags manage_themes/layouts/config; CLI, API, and UI toggles. | Flag round-trip; UI checkbox behaviour.
2.6 | Token lifecycle (model A): expires_at, pairing-key exchange, rotation. | Expiry rejected; pairing key single-use; rotation grace window.
2.7 | partner-create plus the downloadable onboarding file. | File generated and offered for users with an automation credential; contents correct.
2.W1 | Five-dimension non-functional close-out. | Recorded.
2.W2 | lazysite-layouts alignment review; clean tree; hand off for vcs-review. | Alignment findings noted; branch ready.
```

### Phase 3 - Theme and layout management (branch claude/sm071-theme-layout)

```datatable
columns: Step | Work | Tests / output
widths: 1.4cm | X | 6cm
bold: 1
tone: medium
---
3.1 | lazysite-dav.pl per-object read-only rule for lazysite/layouts/**. | Write denied on active, allowed on inactive; rest of lazysite/ denied; dav_scope orthogonal.
3.2 | Content-hash manifest: lzs:sha256 PROPFIND property and artifact-manifest action. | Manifest correctness; drift detectable from base vs live.
3.3 | Control-API front-path: Basic-to-capability auth, CSRF exemption, artifact-validate. | Capability gating; CSRF exemption safe; cookie+token rejected together.
3.4 | Activate-with-backup: validation, base-manifest conditional, retention, artifact lock. | Drift 409; backup snapshot; retention prune; lock 423.
3.5 | Layout specifics: compatible-pair check, layout.tt-compiles gate. | Incompatible pair rejected; uncompilable layout rejected.
3.6 | Rate limiting (per-token bucket) and Retry-After on 429/423/503. | Throttle headers; documented client backoff contract.
3.7 | Routing (Hestia, Docker, dev server); docs and SBOM. | Endpoint reachable; docs and SBOM updated.
3.W1 | Five-dimension non-functional close-out. | Recorded.
3.W2 | lazysite-layouts alignment review; clean tree; hand off for vcs-review. | Alignment findings noted; branch ready.
```

## 6. Non-functional requirements (five-part package, run per phase)

Test coverage
: Unit - the per-object authorise rule, manifest hashing, token expiry and
  rotation, allowlist enforcement, validation gates, sub-user provenance,
  managed_by reassign, and ancestry authorisation. Integration - stage, preview,
  activate, back-out end-to-end; drift 409; lock 423; retry headers;
  cascade-disable. Journey - full `partner-create` to pair to edit candidate to
  preview to activate to back-out, for both a theme and a layout. Target ≥80%
  statement on new code, matching SM070.

Code quality
: `perl -c` clean; perlcritic profile no worse than the SM070 and manager-API
  baseline. Document the duplicated manifest and validation helpers in
  `code-quality.md`'s duplication-by-convention inventory.

Performance
: The manifest is one SHA-256 pass per artifact file, bounded and on demand.
  Preview adds no shared-cache cost because it bypasses cache by design. Note the
  per-token bucket's memory and IO footprint.

Security verification
: perlcritic security theme; trust-boundary review of the `config-set` allowlist,
  the CSRF-exemption rule, and the ancestry authorisation; diff secrets scan (no
  pairing keys or tokens committed, all generated at runtime).

Documentation deliverables
: New `starter/docs/features/configuration/theme-publishing.md` (lifecycle,
  capabilities, preview, back-out, the retry contract, partner onboarding).
  Updates to `webdav.md` (control API and retry contract), `security.md` (new
  flags, sub-user model, allowlist, token lifecycle, preview), `configuration.md`
  (new recognised keys), `test-coverage.md` (totals and new sections),
  `CHANGELOG.md`. SBOM if new dependencies appear (none expected).

## 7. Acceptance criteria

1. A user with `manage_themes` can, over DAV and the control API, read the live
   theme, edit an inactive candidate, preview it (cache-bypassed, session-only),
   and activate it, with the outgoing theme auto-snapshotted as a selectable
   backup.
2. Back-out is `activate` on a backup; live is never written file-by-file at any
   point.
3. The active theme and active layout are read-only over DAV; inactive ones are
   writable per capability; the rest of `lazysite/` stays denied. `dav_scope`
   confines content only and does not gate theme or layout access.
4. `activate` validates, is conditional on the base manifest (409 on drift),
   takes an artifact-level lock (423 if held), and invalidates cache.
5. Layouts work the same, with the compatible-pair check and the
   `layout.tt`-compiles gate; `manage_layouts` is independently grantable.
6. `config-set` writes only the allowlist and cannot touch security-sensitive
   keys.
7. Users are equal; `create_sub_users` and `delegate_sub_user_creation` gate
   sub-user creation and the passing-on of that right; every account carries
   `created_by`, `created_at`, and `managed_by`.
8. A responsible parent can disable, enable, cascade-disable, and reassign within
   its own sub-tree (via `managed_by`) and no account outside it; disabled users
   fail auth everywhere; reassign leaves `created_by` intact.
9. Tokens expire and rotate; a single-use pairing key bootstraps a partner;
   `partner-create` produces a downloadable onboarding file offered for users
   holding an automation credential.
10. 429, 423, and 503 carry `Retry-After`; the documented client retry contract
    is honoured by the test clients.
11. Each phase ends green with a five-dimension non-functional close-out and a
    lazysite-layouts alignment review recorded before hand-off.
