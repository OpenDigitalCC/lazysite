---
id: SM1142
title: "SM1142: plugin becomes extension everywhere, in one release"
subtitle: "The directory, the key a site's lazysite.conf stores, the code's own names and the wire's old spelling all say extension; the upgrade fixes each site up in place, and the word plugin is free for later."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: release manager, 2026-10-17 ("plan rename of plugins/ to extensions/")
area: release
status-note: "CANDIDATE, planned and ruled 2026-10-17: one release, fix up on upgrade, full rename (R3, R5); R1, R2, R4 as recorded below. Built as slices S1-S4."
---

# The request and the rulings

The release manager, 2026-10-17: "plan rename of plugins/ to extensions/".
Then, on the first plan's rulings:

> r3 - immediate - you are the only developer, so when this is released,
> fixup on upgrade, then its done. R5 - prefer full rename, so that the
> namespace of plugin is fully free, in case we need it in future - its tech
> debt to have it hidden inside, sooner its done the cheaper.

So there is no transition period and no phase 2: the release that carries
this moves every site on upgrade, and from then on nothing reads the old
name. And the rename is not limited to paths an operator meets: the module
namespace, the internal action names, template variables, file and test names
all move, so `plugin` is unused and free.

# Where it stands

SM817 renamed what an operator sees (the `extension-*` actions on the wire,
the `extensions:` conf key, the manager's words) and left "the `plugins/`
directory with the loader accepting `extensions/` beside it, the capability
names, and SM222's constrained-enablement mechanism". No capability name
contains `plugin` any more (checked 2026-10-17). SM1125 moved every shipped
caller to `extension-*`.

# What the rename reaches (measured 2026-10-17)

- **464 files, 1,008 lines** name `plugins/`; **139 functional files** carry
  the word `plugin` at all (code, starter, installers, tools); 231 tests.
- **11 places find a script on disk**, each with its own candidate list
  (the registry scan in `Manager/Plugins.pm`, `install.pl`, `Daemon/Jobs.pm`,
  `Handlers.pm` `_find_script`, `Notify.pm`, `Manager/PagePdf.pm`,
  `lazysite-auth.pl`, `lazysite-mcp.pl`, `Manager/Common.pm` `_tool_path`,
  `tools/lazysite-server.pl`, `tools/bench.pl`), three falling back to the
  deb's `/usr/share/lazysite/plugins`.
- **A site's lazysite.conf stores the path**: the enabled list holds the
  registry key, today `plugins/<file>.pl`, under `extensions:` or `plugins:`.
  Six readers parse it; **18 literal keys** compare against the raw entry;
  `t/lint/119` pins the `^plugins/` form. If the code moved and a site's conf
  did not, every extension would read as disabled - login rate limiting
  among them, silently.
- **Installed layout**: each site's copy at `{DOCROOT}/../plugins/`, two
  `cgi-bin` links into it (re-made on every upgrade), the deb payload at
  `/usr/share/lazysite/plugins`. On Hestia the domain root is mode 0551, so
  the user-run install cannot create a sibling directory; the root-run
  scripts make them.
- **Names inside the code**: `Lazysite::Plugins::Owns`,
  `Lazysite::Manager::Plugins`, internal `plugin-*` action names behind the
  wire's `extension-*` (one normalising regex in `lazysite-manager-api.pl`),
  the `enabled_plugins` template variable, `starter/manager/plugins.md` and
  `plugin-config.md` (`/manager/plugins`, `/manager/plugin-config`),
  `t/unit/plugins/`, functions named `plugin_*`.
- **Outside the engine**: no layout in lazysite-layouts uses
  `enabled_plugins` (the only uses are site copies of the engine's own
  manager layout, overwritten on upgrade). External callers of the old
  `plugin-*` wire spelling exist: the sites agent's scripts (asked to move,
  `lazysite-sites/inbox/2026-10-17-app-practice-uses-the-old-plugin-action-names.md`).
  Hand-made references an operator may have from the docs: a `cgi-bin` link
  to `plugins/form-handler.pl`, `perl plugins/form-smtp.pl --pipe`,
  `plugins/stats.pl --classify`.

# The plan (one release; slices S1-S4)

## S1 - the directory, the key and the fix-up on upgrade (M)

- **One resolver**, `Lazysite::Extensions::locate($file)`: the site's
  `extensions/`, then the deb's `/usr/share/lazysite/extensions`. The 11
  lookups call it. Nothing else names the directory (a lint).
- **One key**, `extensions/<file>.pl` (R1). One normalising function serves
  every reader; the 18 literals change; lint 119 follows.
- **The upgrade fixes the site up**, as an `install.pl` one-time step
  (`extensions-rename`, the `once` mechanism, text-in text-out like
  `convert_retired_conf_keys`):
  - moves every file in `{DOCROOT}/../plugins/` to `extensions/`, edited
    copies included (nothing reads `plugins/` afterwards, so an edited copy
    left behind would stop working); a name already present in `extensions/`
    keeps the payload's copy and the old one is kept as
    `extensions/<file>.pl.from-plugins` and named in the summary;
  - rewrites every `- plugins/<file>.pl` entry to `- extensions/<file>.pl`
    and a `plugins:` header to `extensions:` (the writer
    `enable_extension_in_conf`, which writes `plugins:` today, is fixed);
  - re-makes the `cgi-bin` links into `extensions/`;
  - removes `plugins/` when it is empty; where it cannot (Hestia's root-owned
    sibling), the root-run deploy removes it after the install.
  - The step is idempotent and its result is in the upgrade summary.
- **After the step**, the readers accept `extensions/` keys only; a leftover
  `plugins/` entry in a conf (an operator's hand edit after upgrade) is named
  by `lazysite check` with the line to fix.

## S2 - the code's own names (L, mechanical)

- `Lazysite::Plugins::Owns` -> `Lazysite::Extensions::Owns`,
  `Lazysite::Manager::Plugins` -> `Lazysite::Manager::Extensions`, functions
  `plugin_*` -> `extension_*`, the internal action names `plugin-*` ->
  `extension-*` (the normalising regex goes).
- **The wire's old spelling is removed**: `plugin-*` actions answer
  `unknown action` naming the `extension-*` spelling (an ON UPGRADE note;
  the sites agent has been told).
- `enabled_plugins` -> `enabled_extensions` in templates; the engine's
  manager layout is the only user.
- Manager pages `extensions.md` and `extension-config.md`
  (`/manager/extensions`, `/manager/extension-config`) (R2); the old URLs
  are not kept.
- The `plugins:` conf header is no longer read once S1's step has run.
- **A rename invariant lint** (CLAUDE.md: a rename over 10 files gets one):
  the word `plugin` does not appear in functional files - code, starter,
  installers, tools, tests' code - with an explicit exemption list for the
  history (CHANGELOG, feature requests, docs/review, the archive) and for
  S1's migration step, which must name the old directory to move it.

## S3 - installers and packaging (S)

- Hestia's root-run template and `lazysite-hestia-domain.pl` create
  `extensions/` (and the deploy chowns it) in the same release (R4: no
  separate release ahead, because the root-run deploy runs before the
  user-run install); `classification.json` installs to
  `{DOCROOT}/../extensions/`; the deb ships `/usr/share/lazysite/extensions`;
  `release-manifest.json` regenerates.

## S4 - docs, starter, tests (M)

- Every doc and starter page says `extensions/` (configuration, forms, the
  briefings, the conf example, UPGRADE.md with an entry naming the hand-made
  references to check).
- Tests move with the code (paths, conf fixtures, `t/unit/plugins/` ->
  `t/unit/extensions/`).
- **One journey test**: a 0.15.x site with `plugins:` and `- plugins/...`
  entries (login rate limiting, data, the daemon), an edited extension copy
  and the two cgi-bin links, upgraded in place, keeps every extension
  enabled, its conf rewritten, its edited copy moved, its links working, and
  no `plugins/` left.

# Rulings

| Ref | Question | Ruling |
|---|---|---|
| R1 | The stored key | `extensions/<file>.pl`, migrated on upgrade (as proposed) |
| R2 | Manager URLs | `/manager/extensions` and `/manager/extension-config`; old URLs not kept, under R5 |
| R3 | How long the old name is accepted | Not at all after the upgrade step: "fixup on upgrade, then its done" (release manager, 2026-10-17) |
| R4 | A separate installer release first | No: the root-run deploy creates the directory in the same release |
| R5 | Internal names | Full rename, "so that the namespace of plugin is fully free" (release manager, 2026-10-17) |

R1, R2 and R4 follow from R3 and R5 and are recorded here as the plan's;
the release manager may overrule any of them before S1 starts.

# Size and order

L in all: S1 (M) first, because it is the risk; S2 (L, mechanical) and S3
(S) on S1; S4 (M) last with the journey test. Built as one stack and one
integration, in one edge release, with a test plan row for an upgraded site.
