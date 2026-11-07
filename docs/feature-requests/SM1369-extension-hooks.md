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
status-note: "PARTIAL: X0 and X1 shipped in 0.16.6. X7 part one (ruling 135) built on n762: Odoo's modules in extensions/odoo/lib, reached by require_payload; tests and the OOM snapshot stay for 0.16.9. Next X2 actions and capabilities, X3 sources and handlers, X4 identity, X5 endpoint, services, assets, X6 check, panels, secrets, X7's rest, X8 the offline kit."
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
