---
id: SM1369
title: "SM1369: extension hooks - core names no extension, and finds an extension's hooks in an index"
subtitle: "Ruling 55 moves the Odoo elements out of core behind generic hooks. Slices X0 and X1: a lint freezes every core line that names an extension, and core gains the hook declaration, its validator, the index built on enable, disable, save and upgrade, and the loader that runs an enabled extension's own code."
brand: plain
standard-margins: true
status: partial
raised: 2026-11-06
raised-by: "ruling 55 (release manager, 2026-11-04); design tmp/proposal-extension-hooks.md; planned as n757"
area: extensions
status-note: "PARTIAL: X0, X1 shipped in 0.16.6; X7 part one in 0.16.7. Built for 0.16.8: X2 on n768 (capability_info, api_actions, refusal_kinds live; Odoo's ten actions and two capabilities declared, wire unchanged); X3 on n769 (page sources and handler types declared; Odoo's sources and type on the hooks). Next X5 asset part, X8; X4, X6, X7's rest in 0.16.9."
---

# The ruling

Ruling 55 (release manager, 2026-11-04): "I would like the odoo elements to be in
the extension and not in core. If this means that the core needs generic hooks
that enable odoo, and could also enable other extensions to hook in to other
remote databases and systems, then make a proposal." The proposal is
`tmp/proposal-extension-hooks.md`: twelve hooks (H-1 to H-12) and nine slices
(X0 to X8). This filing carries the slices; this branch builds X0 and X1.

The slice order
: Ruling 135 (release manager, 2026-11-06): Odoo's file move, the move that is
  part of X7 (its modules from core's `lib/` into its payload lib), comes before
  X2. X2 waits for it: under C-3, which stands, a hook's module must be in the
  extension's own payload lib, so X2 cannot declare a hook on a module still in
  core's `lib/`. The order is X0, X1, the move, then X2 to X6, the rest of X7
  and X8.

# X0: core names no extension

`t/lint/321-core-names-no-extension.t` reads every core file and counts the
lines that name an extension, with comments, POD and markup comments left out.

Core
: The CGIs and `install.pl`, the processor's parts, the library, the tools, the
  shipped scripts, the manager pages, the system, component and layout
  templates, and the installer templates. An extension's own files are not
  core: its descriptor, the endpoints it declares in `owns.endpoints`, and the
  payload the lint's `%OWN` names (Odoo's engine, its browser helper, its
  sign-in page and component, the warm endpoint's service). Docs and tests are
  not core.

Naming an extension
: Naming Odoo by its own names, `odoo`, `OOM` and `oomd`, the measure the
  proposal's inventory used; its script name `extensions/odoo.pl` is one of
  them. Ruling 136 (2026-11-06): the lint counts Odoo's names only, not every
  extension's script name, so that X7 empties the list.

The allow-list
: 43 files, measured at b7f178856 and recounted for ruling 136. A file over its
  count, or a file not listed, fails. A file under its count fails too, until
  the count is lowered, so the list only shrinks.

# X1: the index and the loader

Declaration
: `owns` gains `hooks` (a mapping) and `requires` (extension ids).
  `Lazysite::Extensions::Hooks` validates both, through `Owns::validate_owns`.
  An unknown hook is refused by name. A known hook whose consumer is not built
  yet is refused too, naming its slice, because nothing would call it. A hook's
  function is a fully qualified Perl name, never one in `main::`, `CORE::` or
  `UNIVERSAL::`, never `import` or `DESTROY`.

Layout and `@INC`
: An extension's payload sits beside its descriptor: `extensions/<stem>.pl` and
  `extensions/<stem>/` (`lib/`, `assets/`, `templates/`, `docs/`, `t/`,
  `tools/`). `Lazysite::Extensions::payload_lib` finds the payload's `lib/`, a
  real directory at each step and never a link. `add_payload_lib` is the one
  rule that puts it on `@INC`, and it appends.

The index
: `lazysite/extensions.index.json`, written atomically by
  `Manager::Extensions::rebuild_hook_index` from the descriptors of the enabled
  extensions. It is built on enable, disable and save, and on every upgrade or
  reinstall (`install.pl` `run_hook_index_build`, the installed lib, as the site
  user). A declaration that fails validation, names a module outside its own
  payload lib, or requires an extension that is off is left out and named in
  `refused`. A failed write keeps the previous index.

The loader
: `Hooks::call_hook( $docroot, $id, $function, @args )` returns
  `( 1, @result )` or `( 0, $why )`. It runs only a function the extension's
  indexed declaration names. The extension and everything it requires must be on
  at the call, read fresh from `lazysite.conf`. Its payload lib must be the one
  the index was built from. The module must be a file in that lib and found
  nowhere else on `@INC`. It is loaded lazily, and a function that dies is a
  failure with its reason, never an exception.

Requires
: Enabling an extension whose dependency is off is refused by name (kind
  `refused`, audit `requires_off: <id>`). An invalid declaration is refused
  before the conf changes (kind `descriptor`).

A site with no hooks
: An empty build writes no index, and removes one left by an earlier build. The
  toggles and the save build only when the extension declares hooks or an index
  exists. A site whose extensions declare none gets no file, no `--describe` of
  the others, and the same response keys.

Tests
: `t/lint/321`; `t/unit/extensions/70` (the validator); `t/unit/extensions/71`
  (the index and the loader, against a real fixture tree, including the site
  with no hooks); `t/tools/330` (the upgrade step, through the real
  `install.pl`); `t/lint/125` runs the loader's enabled-list reader beside the
  other two. Each fails with its change reverted.

# X7, part one: Odoo's modules move into its payload lib

Ruling 135 puts this before X2. It is built on n762 for 0.16.7. Ruling 143 leaves
the rest of X7 to 0.16.9: the separate `lazysite-odoo` deb, the `--with odoo` install
path and the empty allow-list.

The move
: Odoo's modules go from `lib/Lazysite/` to `extensions/odoo/lib/Lazysite/`, with
  their names unchanged (D-3 (a)). That is `Lazysite::Odoo`, the twelve
  `Lazysite::Odoo::*` and the two Odoo-only daemon services (`Daemon::Service::Oomd`,
  `Daemon::Service::OdooEndpoint`). The move is its own commit of renames. They still
  ship in the same package and install: `classification.json` installs
  `extensions/<id>/lib/**.pm` at `{DOCROOT}/../extensions/<id>/lib/`, and the six
  directories are declared at 0755.

How core reaches them
: `Lazysite::Extensions::require_payload($module)` loads the engine's own copy. That
  copy is the payload beside the lib core was loaded from: `{DOCROOT}/../extensions`
  on a site, `extensions/` in a checkout and in `/usr/share/lazysite`. It puts the
  payload lib on `@INC` by the X1 rule (`add_payload_lib`, appended). A module found
  in two payload libs is refused. So is a copy anywhere else on `@INC`, such as an
  edited file an earlier release left in core's lib. A missing module dies as
  `require` does. Like `require`, it gates nothing. Whether the extension is on stays
  each caller's question, as before the move.

Who uses it
: Every core `require` of an Odoo module now goes through it. The processor's
  `_lazy_lib` falls back to it for a module that is not core's, which covers its
  sources and the pool's preload list (`Lazysite::Extensions` joins that list). The
  manager's config validator (`validate_*`) does too. Odoo's own files find their
  payload themselves: the endpoint `lazysite-odoo.pl` in its BEGIN, the descriptor
  beside itself. The endpoint's service finds the script six levels up from its new
  place.

The upgrade
: The manifest plan installs the payload and removes the old copies, as it removes
  any file that left the manifest. The directories they emptied in core's lib go too,
  and only empty ones. The hook index is rebuilt as on every upgrade; Odoo declares
  no hooks yet. An edited old copy is kept with its orphan warning. `require_payload`
  then refuses it by name rather than running stale code.

Kept in place, for 0.16.9 (risk R-6)
: Odoo's tests stay in `t/unit/odoo` and the rest of `t/`. The OOM snapshot stays in
  `t/vendor/oom`, with `tools/vendor-oom.sh`, `tools/ext-compat.sh` and lints 207,
  261 and 262. Moving them is not mechanical:
  - every runner reads `t/`: `prove -lr t/` in `tools/suite.sh` and the nightly,
    `precheck.sh`'s greps of `t/unit` and `t/integration`, and the area map's
    `all_tests`;
  - the coverage digests are taken over those inputs;
  - `OdooTest` finds the snapshot at `t/vendor/oom` from its own place;
  - lint 261 holds that path to its MANIFEST.

  Moving them needs H-12, where the tools read the extension's declaration, and the
  core-alone gate job. Until then a test reaches the payload as `prove -l` reaches
  core's lib: `TestHelper` appends each in-tree payload lib to `@INC` in the test
  process only, never in a child a test starts.

The allow-list
: Lint 321 loses `lib/Lazysite/Daemon/Service/Oomd.pm`, which is now the extension's,
  and `tools/precheck-areas.pl` drops to 3 lines (one row now covers the payload lib):
  42 files. No core file gained a line naming Odoo.

Tests
: `t/lint/335`: core's `lib/` holds no extension module, and no core file loads one
  but through the rule. `t/unit/extensions/75`: the rule against a fixture engine
  tree, including a stale copy refused, two payloads and a linked payload.
  `t/tools/335`: the upgrade journey, with a site in the old layout with Odoo on, the
  site sign-in on, a page binding, a page reading it, a protected page and a person
  signed in through Odoo, upgraded in place by the real `install.pl`. After it, the
  installed code keeps the person signed in and the binding answering at the endpoint
  and on the page, and a second run changes nothing. oomd, the pooled warm endpoint
  and a scheduled binding's timer are not stood up there; their names, socket and
  paths are unchanged. Lints 262, 269 and 272 read the payload lib as they read
  `lib/`.

# X2: actions and capabilities are declared

Built on n768 for 0.16.8 (H-7 and H-9; rulings 71 and 135). The ruling's measure:
Odoo's actions and capabilities leave core's literals, and the wire does not move.

The declaration
: `owns.hooks` gains three live kinds. `capability_info` describes each capability
  `owns.capabilities` names: its section (one of the grids' seven), the grid's short
  `label`, the `title` and `grants` sentence describe-capabilities publishes, the UI
  surfaces it unlocks, and `top_up_from`, the capabilities a group holding any of
  which is topped up with it. Its api and mcp unlocks are derived from the gate rows
  that name it, so the map cannot over- or under-claim (lint 90, by construction).
  `api_actions` is one row per control-API action in `%ACTION`'s shape - name, mcp
  twin, params (each saying where it is read from), mutates, destructive, open_world,
  instance_wide, cookie_cap - with its `gate` (capabilities, or `ALWAYS` with its
  `always_reason`), the twin's `description` and `input_schema`, and the `handler`, a
  function in the payload lib called as `handler( \%params, \%ctx )`.
  `refusal_kinds` maps the kinds the extension's answers carry to the status the doors
  send. A name must start with the extension's id (`odoo-`, `odoo_`).

What the build refuses
: Each by name, and the extension is then not enabled (C-7): a row with no gate; an
  ALWAYS row with no reason; a name or twin not the extension's; a capability, an
  action, a twin or a refusal kind core has; an owned capability nobody describes, or a
  description of one not owned; a gate naming a capability nobody has; a cookie gate
  that differs from the token gate; a twin's schema requiring what the row does not
  (SM326), or naming a parameter the row lacks; a handler not a file in the payload
  lib.

The index
: Gains a `declared` view beside X1's `extensions`: every INSTALLED extension's
  declarations (from the listing's cached descriptors), validated as an enabled one's
  are, so a capability is grantable while its extension is installed and an action of
  an extension that is off is known. The toggles and the save build when the extension
  in hand declares hooks, an index exists, or any installed extension declares. A
  fresh install builds it as the upgrade does, by the same call (ruling 166), so a new
  site can grant a declared capability from the start. A failed write leaves `extensions.index.failed` beside the index; the check reports it.

The mirror
: `Declared::mirror($lz)` (the full scope; `Hooks::mirror` is the light one a grant resolver uses) reads the site's index once per process (a stat afterwards) and
  fills `@CAP_KEYS` (the literal is now `@CORE_CAP_KEYS`), Capabilities' `%ACTION_INFO`,
  `%GATE` and `%ACTION` (each row marked `extension`), and the refusal statuses, refusing
  a core name a second time. The doors and the tools call it before they derive their
  tables; `Auth::Settings` calls it from `caps_for` and the group-settings reads, so
  every process that resolves a grant sees the declared capabilities. The lints, the
  docs generator and the gate fingerprint mirror an index built in memory from the
  tree's descriptors (`Manager::Extensions::engine_hook_index`).

The dispatch
: One branch per door. The manager API reads each declared parameter from where its
  row says and hands `Declared::run_action` the caller's identity, capabilities, groups,
  address and door; MCP builds its tool row from the declaration (description, schema,
  the gate as `cap`/`cap_also`) and does the same with the arguments. `run_action`
  requires the extension on in `lazysite.conf` now and its hooks indexed, and runs the
  handler through X1's loader; off answers the house refusal "this extension is off"
  (kind `disabled`, running nothing), a missing entry "cannot run now", naming the
  rebuild.

Odoo
: Declares `manage_odoo` (ruling 71: the connection user's actions, which were
  manage_connectors', and the binding override; `top_up_from: manage_connectors`) and
  `settle_odoo_writes`; its ten actions with the descriptions and schemas the MCP table
  carried; its thirty refusal kinds. The handlers (`Lazysite::Odoo::Actions`) hand the
  engine's `action_odoo_*` what the branches handed. Core names no Odoo action,
  capability or kind: lint 321's allow-list falls from 42 files to 34. The 0.16.7
  listing and rows are captured in `t/lib/odoo-wire-0167/`, and t/unit/odoo/136 holds
  the declaration to them.

The grids and the check
: The Groups and Users pages keep core's capability lists (lint 19) and draw a declared
  capability from the labels `channel-services` serves. The users tool tops up a
  declared capability from what it declares (`top_up_from`), on SM645's trigger and by
  its rule (absent only); the upgrade runs the same top-up itself (ruling 167,
  `capability-top-up`) and prints one line naming the groups. `lazysite check` reads the index's capabilities for the
  manager-group walk and reports a failed build and an enabled extension whose hooks
  are not indexed.

Tests
: `t/unit/extensions/72` (a fixture extension declares a capability and two actions;
  the index, the mirror, both doors, the refusals, off and stale); `t/unit/odoo/136`
  (the capture); lint 76 reads the index; lints 14, 23, 52, 90 and 218 read the merged
  table; 70, 71, odoo/15 and odoo/105 learn X2's facts; odoo/04, 17, 106, 110,
  integration/171 and 114 hand the override capability ruling 71 names; tools/330 reads
  the declared view the upgrade builds, tools/338 the one a fresh install builds
  (ruling 166); tools/339 the upgrade's top-up (ruling 167). Each fails with its change
# X3: page sources and delivery handler types

Built on n769 for 0.16.8: H-2 and H-3 are live, and Odoo's `odoo:` and
`odoo-identity:` sources and its handler type are declared by the extension.
Bindings, page variables, refusals and handlers.conf rows are unchanged.

Page sources (H-2)
: `owns.hooks.page_sources` is a list of `{ prefix, resolve, check, per_viewer,
  live, read_only }`. The processor (sources.pm, `resolve_source`) resolves a
  variable whose prefix the index declares - after its own scan:, db:, json: and
  url:, the longest declared prefix first, never `scheme://` - by calling
  `resolve(spec, ctx)` through `Hooks::call_hook`. The context is the page, the
  key, the prefix, the request address through the trusted-proxy rule, the host,
  the site and mode `render`; a source that declared `per_viewer` is also handed
  the cookie header and the request's identity, and no other is. The answer is
  `( $value )` or `( undef, $why, %detail )`; core makes the value inert
  (`_source_inert`, `_odoo_inert` made generic: escaped and no link scheme) and
  writes one WARN line in one shape for a refusal, a death, a module that did not
  load or an extension that is off, with the value empty. `per_viewer` replaces
  the three `odoo-identity:` peeks: the processor's front-matter peek marks the
  page per viewer (`per_viewer_source`, the gated page's cache treatment), the
  offline-app rule in the processor and the manager's copy read the same
  prefixes from the index, and a per-viewer source anywhere the mark did not
  reach is refused. `live` and `per_viewer` set the live-source flag. `check(spec,
  docroot)` runs at the page's save (Validate, `_check_source_bindings`) and its
  issues join the page's, with the extension's own kind.

Handler types (H-3)
: `owns.hooks.handler_types` is a map of type name to `{ label, cap, schema,
  origins, note, parse, on_save, on_delete, deliver }`. `Lazysite::Handlers`
  merges the site's index into `%TYPES` and `@TYPE_ORDER` on every read of the
  catalogue (`_sync_hook_types`, a stat; the merge is redone when the index
  changes), after the five core types. Core runs `parse(h, ctx)` and
  `on_save(h, ctx)` at save - the shape, then the destination - `on_delete` at
  delete, and `deliver(h, fields, ctx)` from a form or the timer, each answering
  `{ ok, why, field, note }`; a function that did not run is a refusal or a
  failed delivery with the reason. Core keeps handlers.conf, the schema check
  that refuses an unknown key, the cap gate (the type's `cap` gates creating,
  editing, deleting and scheduling it, and the scheduler's job account must hold
  it, as for a core type), the origin gate (`origins`, the two core has: `form`,
  `timer`; a delivery from another is refused before the extension's code loads)
  and the delivery record. What crosses to `deliver` is the visible fields and a
  context without the handler list or the uploads. A type whose extension is off
  leaves the catalogue: a saved handler of it is listed with its problem and not
  delivered. The MCP save_handler schema reads the merged catalogue.

address_profiles (I-13)
: A schema field type for names of address profiles, comma separated, with a
  `slot` (allow, deny, match). `Handlers::address_profile_fields` says which fields
  of which types carry them, and `AddressRefs` walks handlers.conf by that answer,
  so the profiles a session binding's sign-in limit and an operation's address
  profile name are found by type, not by the type name `odoo`. The describe label
  for the place is `handler`.

The validator
: Refused by name before anything is indexed: a prefix core owns (scan, db,
  json, url), one with a colon or capitals, one declared twice, a source without
  `read_only => 1`; a type named for a core type (smtp, file, table, connector,
  notify) or a retired one (webhook, api, db), a `cap` that is not in the
  engine's capability list, an origin core has not got, no origin, a schema key
  every handler carries (id, type, name, enabled, domain, csrf_token), a field
  type the catalogue does not draw, a slot that is not one. `Hooks` gains the
  `named` form (a map of names to records), `lists` and `tables` keys, and a
  per-kind `check` for the vocabulary. The build runs `cross_problems` over the
  entries that passed: the later of two extensions declaring one prefix or one
  type name is left out, named.

Odoo
: `Lazysite::Odoo::Hooks` (its payload lib) carries `source_binding`,
  `source_identity`, `check_binding`, `handler_parse`, `handler_save`,
  `handler_delete` and `handler_deliver`, each the lines that left sources.pm,
  Validate.pm and Handlers.pm, with the same words. `extensions/odoo.pl` declares
  the two sources and the type with its schema. Lint 321's allow-list loses
  sources.pm, auth.pm, app.pm, Config.pm, Validate.pm, Handlers.pm and
  AddressRefs.pm, and one line of the processor: 35 files.

Tests
: `t/unit/extensions/72`: a fixture extension's sources through the real
  processor as a CGI - no credential to a shared render, per viewer never cached
  for another, inert, a dying source and one answering nothing as empty with one
  WARN line each, `live`, `check` at save, one owner per prefix, and the index
  file's spelling pinned between sources.pm and `Hooks::index_path`.
  `t/unit/extensions/73`: a fixture handler type - the vocabulary, the catalogue,
  save and delete through the extension, the origin gate, `address_profiles` by
  type, off means off. Odoo's tests assert what they asserted; `OdooTest::
  enable_odoo` builds the index from the checkout's descriptor (through the dev
  server's directory rule, so the loader sees the one payload lib TestHelper put
  on `@INC`), and tests 13, 30, 368, 145 and 395 enable and index Odoo where they
  relied on the type or the source being core's. Each fails with its change
  reverted.

# Choices made

Each of these is a point the proposal leaves open where the choice changes
behaviour. The conservative option is taken, and each is a question for the
release manager.

```datatable
columns: Ref | Choice | Taken | The other option
widths: 1cm | 4cm | X | X
text: 3
---
C-1 | What X0 counts | Ruled (136, 2026-11-06): Odoo's names only (`odoo`, `OOM`, `oomd`), so that X7 empties the list. 43 files | Every extension's script name as well, as first built: 58 files, the other extensions' rows (data, stats, briefs, remap, the login rate limiter, form-smtp, notify-xmpp, pandoc, form-handler) staying after X7
C-2 | A hook kind whose consumer is not built | Refused at validation, naming its slice; every kind is not live in X1 | Accepted and indexed now, run once its slice lands: a declaration nothing calls in the meantime
C-3 | Where a hook's module may live | Only the extension's payload lib, and found nowhere else on `@INC`. Stands (ruling 135, 2026-11-06): Odoo's file move comes before X2, which waits for it, so X2's hooks name modules already in the payload lib | Any module on `@INC` in the extension's namespace
C-4 | `requires` | Inside `owns`, beside `deps` and `bins` | A top-level descriptor key
C-5 | Disabling an extension others require | Allowed. The dependents' hooks stop at the next call, and a rebuild leaves them out with the reason | Refused while a dependent is on
C-6 | A site with no hooks | No index file, and none written. The toggles and the save build only when the extension declares hooks or an index exists | Always write an index, empty when nothing declares hooks
C-7 | An invalid declaration on an extension being enabled | The enable is refused before the conf changes | Enabled, with its hooks left out of the index
C-8 | The names of the hook kinds not yet live | The proposal's names, recorded in `%KINDS` with their slice; a slice may rename its kind before making it live | No names until each slice
C-9 | The upgrade build | Every upgrade and reinstall describes the enabled extensions, a few seconds a site | Only when an index already exists, which would miss the first release whose descriptors declare hooks
C-10 | What the index declares (X2) | Every INSTALLED extension's declarations, in a `declared` view beside the enabled hooks: a capability is grantable while its extension is installed (H-7's words), an action of an extension that is off is known and answers "off" (H-9's words), and the tool listing does not change with the toggle; the hooks that run stay enabled-only (G-1) | Enabled only: a disabled extension's actions become "no such action", its capabilities leave the grids, and a group saved meanwhile loses the grant
C-11 | When a toggle builds (X2) | When the extension in hand declares hooks, an index exists, or any installed extension declares (the listing's cached descriptors): the `declared` view stays current, and the response carries `index` on such a site | X1's rule alone, which would leave an installed extension's declarations out until something with hooks is toggled
C-12 | A capability's api and mcp unlocks (X2) | Derived from the gate rows that name it; only `ui` is declared | Declared, and held equal to the gate by a lint, as core's are
C-13 | Which refusal kinds move (X2) | The kinds only Odoo produces (thirty) go to its declaration; `expired`, `internal`, `unavailable`, `busy`, `maintenance` stay core's | All of the block, and core redeclares what it uses
C-14 | The handler type's capability | `Handlers.pm`'s `odoo` type stays `manage_connectors`' until X3 declares the type (its file is n769's); the top-up keeps the reach equal | Changed here to manage_odoo
C-15 | The older extensions' capabilities (data, briefs, daemon) | Stay mirrored in the core literal in 0.16.8: each owns its capabilities (`owns.capabilities`) and describes none. A fresh install now builds the index as the upgrade does (ruling 166), so nothing stops the move but the work: the data, briefs and daemon extensions describe their own capabilities and leave the literal in 0.16.9, with X6 (ruling 166). Lint 76 holds one state each meanwhile: described and indexed, or owned and literal | Describe all three here
C-16 | What a grant resolver mirrors | The light scope - the capability names and the refusal statuses, from `Auth::Settings` alone - so the processor's pooled workers carry no action table (lint 269); the doors, the tools and the lints mirror the full scope before deriving their tables | One scope everywhere, and the action tables resident in the processor
C-17 | X3: the origins a type may name | `form` and `timer`, the two core delivers from; the page endpoint runs its bindings itself, so `page` is not a name until a slice (X5) makes core deliver from one | `page` accepted now, as a name nothing passes
C-18 | X3: `odoo-identity:` on a site whose Odoo extension is off | The literal, as any undeclared prefix: the source is the extension's, and such a page can have no identity cookie to read | An empty mapping, as before, which needed core to know the prefix
C-19 | X3: a handler of a type whose extension is off | Listed with its problem (`unknown type`) and not delivered, as a retired type's record is; saving one is refused | Delivered through the extension's code regardless, which would run a disabled extension
C-20 | X3: the dying source's log | Two lines: the loader's, naming the extension and function with the reason where it happened, and the page's one line in the one shape, carrying the reason | One line, which would lose the record of which extension died for a caller that does not log (a check)
C-21 | X3: `AddressRefs` loads the handler catalogue | It asks `Lazysite::Handlers` which fields of which types name profiles, so an extension's type is found as a core one is | A second, hand-kept list of fields, which is the drift the module's own header refuses
C-22 | X3: the field type's name | `address_profiles`: the proposal and the brief say `address_list` (I-13, written before SM1343), and ruling 56 (lint 320) refuses that vocabulary in a functional file | `address_list`, exempted in lint 320 by name
C-23 | X3: the pool's preload | The pool preloads `Lazysite::Extensions::Hooks` and no Odoo module (lint 269: the list is what the processor's parts name); a hook's modules load in a worker on first use | Keep Odoo's four modules preloaded for the warm path, which lint 269 refuses as modules nothing names
```

# ADR 0007

The new-external-interface trigger fires. X1 adds an interface through which
code that is not core runs inside a core process: an extension's own Perl,
loaded from its payload lib by `call_hook`, where until now an extension ran only
as a separate process (`--describe` and its actions). No core caller uses it in
this release and no hook kind is live, so no request reaches it yet, but the
interface is built here and each later slice only adds a caller. The other three
triggers do not fire: no sign-in method (H-1 is X4), no new dependency, no new
processing of restricted data. The register entry in `docs/SECURITY.md` is the
trigger's assessment, drafted for the release manager's confirmation.

X2 (ruling 134 asked for the reassessment when the first caller landed): the two
doors are the first callers, for the ten actions that were core's own branches. The
code that runs is the same engine behind the same names under the same gates, and the
wire is held to a 0.16.7 capture; the X2 register entry is drafted as contained, for
the release manager's confirmation.
