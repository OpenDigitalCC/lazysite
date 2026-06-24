---
title: "SM079 - Modular refactor: standalone processor, modules for everything else"
subtitle: "Resolve the 4273-line manager-api, kill helper duplication, keep 'just run the processor against a folder'"
brand: plain
---

::: widebox
Keep `lazysite-processor.pl` a **self-contained single file** you can drop in a
folder and run - that is the whole point of lazysite. Let everything heavier
(auth, WebDAV, the manager API, the users tool) become thin front-controllers
over a shared `Lazysite::*` module tree. This resolves the 4273-line
`manager-api` (D1), removes the helper duplication the no-shared-modules
convention forced, and - because the logic moves into modules that unit-test
**in-process** - also fixes the coverage-measurement gap (D2).
:::

## Status

Proposal for approval. Not yet executed. Supersedes the "no shared modules"
convention *except* for the processor's basic path (see Principle 1).

## Why now

- `manager-api.pl` is 4273 lines / 119 subs - it has become its own
  application, and the single-file rule (meant for the processor) now just
  makes it unmaintainable and hard to cover (60% stmt, the project low-water).
- The no-shared-modules convention forces real duplication: `log_event` is
  copied into **all five** scripts; `const_eq`, `hash_password`,
  `verify_secret`, the JSON and path helpers are copied across pairs of them.
- The tests drive the CGIs as subprocesses, so `Devel::Cover` fragments
  `auth.pl`/plugins across tempdir copies and cannot cleanly measure them.

## Principles

1. **The processor stays standalone.** `lazysite-processor.pl` remains a single
   file that renders a folder of Markdown with core Perl (+ optional Template
   Toolkit) and **no project modules on the basic path**. Confirmed feasible:
   its render path makes zero calls to any auth/credential/manager helper. It
   *may* `eval { require Lazysite::X }` for an advanced feature, degrading
   gracefully if absent - but "drop one file, run it against a dir" never needs
   `lib/`.
2. **Everything else is modular.** auth, dav, manager-api, users-tool become
   thin front-controllers over `lib/Lazysite/**`.
3. **One bounded duplication, on purpose.** The handful of helpers the
   standalone processor still inlines (a JSON helper, `log_event`, path
   sanitising) are the *only* remaining copies. Every other script shares the
   module. This is the deliberate trade for processor simplicity.

## Proposed module tree

Installed to `{DOCROOT}/../lib` (siblings `plugins/` and `tools/` already install
there); each modular script adds it with `use lib` computed from its own path.

```
lib/Lazysite/
  Util.pm            json in/out, const_eq, slurp/spit, log_event, sanitise_path,
                     validate_path, is_safe_url            (the duplicated core)
  Config.pm          lazysite.conf read/parse, allowlisted get/set
  Auth/
    Credential.pm    sha256iter hash/verify; token/claim/pairing/recovery
                     mint + consume; TOTP (replay-guarded)
    Settings.pm      user-settings.json + the consume flock; per-user caps
    Session.pm       cookie HMAC sign/verify; CSRF token
    Acl.pm           acls.json store; _acl_allows/_is_operator/_acl_denied;
                     the deny-set (is_blocked_path / _config)
  Manager/
    Files.pm         list / read / save / delete / mkdir; edit locks
    Themes.pm        theme + layout list/activate/install/validate/backup
    Plugins.pm       plugin + handler + form-target config
    Upload.pm        multipart parse, limits, upload / download / zip
```

### Front-controllers after the refactor

| Script | Becomes | Uses |
|---|---|---|
| `lazysite-processor.pl` | unchanged shape, **self-contained** | core Perl (+ optional TT); optional `require` only |
| `lazysite-auth.pl` | thin login/claim/token controller | `Util, Config, Auth::Credential, Auth::Settings, Auth::Session` |
| `lazysite-dav.pl` | thin WebDAV controller | `Util, Auth::Settings, Auth::Acl` |
| `lazysite-manager-api.pl` | **dispatcher only** (auth + `%need` gate + dispatch table) | `Util, Config, Auth::*, Manager::*` |
| `tools/lazysite-users.pl` | thin CLI/API over the credential modules | `Util, Auth::Credential, Auth::Settings` |

`manager-api.pl` drops from 4273 lines to a few hundred (the gate + dispatch);
the ~1000-line themes/layouts block, the ~600-line upload block, files/ACL,
plugins/forms each move to their module.

## Usage modes (all preserved)

| Mode | How `lib/` is found |
|---|---|
| **Just run the processor** | not needed - the processor is standalone |
| **Just run the manager too** | unpack the tarball (ships `lib/` adjacent); scripts `use lib dirname($0)."/../lib"` |
| **tar install** (`install.pl`) | lays out `cgi-bin/*.pl` + `../lib/Lazysite/`; classification gets a `lib/` rule |
| **package** (deb/rpm) | same relative layout under the package prefix, or `lib/` added to a vendor path |
| **Hestia / meta-installers** | per-domain tree already has the `../lib` sibling |

## Migration plan (incremental, suite green at every step)

1. **Bootstrap** `lib/` + the `use lib` path resolution + the classification
   install rule + a per-usage-mode path test. No logic moves yet.
2. **`Util`** - extract the most-duplicated helpers; point auth/dav/manager/
   users at it (processor keeps its inline copies). Suite.
3. **`Auth::*`** - Credential, Settings, Session, Acl; migrate users-tool, auth,
   dav, manager onto them; delete the duplicates. Suite.
4. **`Manager::*`** - Files, Themes, Plugins, Upload; reduce `manager-api.pl` to
   the dispatcher. Suite.
5. **Tests** - add in-process unit tests per module. Because the logic is now in
   modules (not subprocess-only CGIs), `Devel::Cover` measures it directly -
   coverage becomes both measurable and high, closing the D2 limitation.
6. Raise the coverage floor toward the 75% target as the modules land.

Each numbered step is its own commit; extractions are **verbatim** (move code,
don't rewrite) so behaviour cannot drift, with the full suite as the guard.

## What this fixes

- **D1** - no 4000-line file; each unit is a focused, reviewable module.
- **D2** - logic is unit-tested in-process; the subprocess-fragmentation
  limitation (auth/install/plugins) goes away.
- **Duplication** - one shared copy of each helper instead of five.

## Risks / trade-offs

- **Path resolution** across the four usage modes - mitigated by a small `use
  lib` bootstrap and a test per mode in step 1.
- **The `do "...pl"` in-process test hooks** - the CGIs get thinner; their logic
  (and its hooks) move into the modules, which is where the new unit tests live.
- **Bounded duplication** in the processor - accepted, by design (Principle 3).
- This is a multi-commit refactor; it touches every script. The mitigation is
  the verbatim-move discipline and the 1276-test suite as a ratchet.
