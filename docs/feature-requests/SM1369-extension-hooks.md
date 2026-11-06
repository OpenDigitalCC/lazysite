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
status-note: "PARTIAL on n757: X0 (t/lint/321) and X1 (Lazysite::Extensions::Hooks, the index build in Manager::Extensions, install.pl run_hook_index_build, the payload lib rule) are built. To come: X2 actions and capabilities, X3 sources and handlers, X4 identity, X5 endpoint, services and assets, X6 check, panels and secrets, X7 the move, X8 the offline kit."
---

# The ruling

Ruling 55 (release manager, 2026-11-04): "I would like the odoo elements to be in
the extension and not in core. If this means that the core needs generic hooks
that enable odoo, and could also enable other extensions to hook in to other
remote databases and systems, then make a proposal." The proposal is
`tmp/proposal-extension-hooks.md`: twelve hooks (H-1 to H-12) and nine slices
(X0 to X8). This filing carries the slices; this branch builds X0 and X1.

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
C-3 | Where a hook's module may live | Only the extension's payload lib, and found nowhere else on `@INC`. X2 to X6 declare Odoo's hooks while its modules are still in core's `lib/` (they move in X7), so X2 needs the modules it names moved first, or a ruling that allows the extension's namespace in core's lib until X7 | Any module on `@INC` in the extension's namespace
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
