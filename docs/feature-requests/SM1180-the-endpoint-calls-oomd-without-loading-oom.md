---
id: SM1180
title: "SM1180: the endpoint calls oomd without loading OOM"
subtitle: "Each binding's operation declaration is stored when the binding is saved, stamped with the OOM version and the site's packs, so a call oomd answers loads six OOM modules instead of thirty-three, and none of the registry; a bench check warns when the endpoint adds more than a margin to oomd."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox 2026-10-19-what-lazysite-adds-to-an-odoo-call.md (OOM Lab); ruled by the release manager 2026-10-19
area: odoo
status-note: "SHIPPED on n667 (base 4c4798a6c, SM1164 D1-D4): lib/Lazysite/Odoo/Decl.pm, Lazysite::Odoo::binding_class, t/unit/odoo/70 (the load), t/tools (the margin check). Rows parameters still load OOM for OOM's own check_rows (see What is left)."
---

# What happened

The OOM Lab measured what lazysite adds to an Odoo call (inbox
2026-10-19-what-lazysite-adds-to-an-odoo-call.md). The owner's requirement:
"**lazysite and OOM must add minimal latency to Odoo**." The target: "**lazysite
adds at most ~10-20 ms to what oomd takes**." Two of the figures: "A fresh `perl`
loading OOM: 250 ms" and "A fresh `perl` loading the oomd light client: 61 ms".
The lab's note on the registry: "with oomd the endpoint needs no registry, since the
daemon has it", and "A test that holds it: a timing check for the endpoint against
oomd for one fixed operation, failing above a set margin."

SM1164 sent the call to oomd, and recorded the gap itself in its "Decisions":
"Binding and operation declarations are still read from OOM's registry in-process,
before anything is sent." So with `odoo_daemon: on` the endpoint still loaded OOM
(`Odoo::Ops`, `Config`, `Context`, `Registry`, `Plan`, `Runner`, the operation's pack
and the tree under them: 33 Odoo modules in a fresh process) before the light client
did its work.

The release manager ruled, 2026-10-19: "build now - store each binding's operation
declaration at save, stamped with the OOM version, so the endpoint calls oomd without
loading OOM; plus an advisory bench margin check."

# Where the request path loaded OOM

Every place, on the base:

- **`gate` -> `oom_check`** required `Odoo::Ops` and six modules (`Error`, `Config`,
  `Context`, `Registry`, `Plan`, `Runner`) on every call and confirm.
- **`_ready` -> `operation_class` -> `registry()`** built `Odoo::Ops::Registry`,
  found the pack and loaded the operation's class.
- **`Binding::check_against`** read `$class->params` and `$class->writes`.
- **`Binding::assemble`** read `$class->params`, and for a rows parameter called
  `$class->check_rows` (an `Odoo::Ops::Operation` method, in a module that itself
  uses `Registry`).
- **`_take_cap` / `Binding::rate_limits`** asked `$class->writes` (read or write
  defaults).
- **`call`, `_run`, `_run_daemon`, `_finish`** asked `$class->writes` (plan or
  apply, who owns it, the phase recorded, whether a report is drawn).
- **The endpoint's `_writes`** (the GET refusal of a writing binding),
  **`Handlers::_odoo_writes`** (a form or the schedule running a binding) and
  **`writes_of`** (`lazysite check`) each ran `oom_check` and `operation_class` of
  their own.
- **Fields.pm** (`present`) reads the report's descriptors and loads
  `Lazysite::Data::Descriptor`, which is lazysite's; it loaded no OOM. `form_fields`
  (the manager's binding list) reads `$class->params`.
- **The CSRF and visitor paths** (`Visitor`, `Identity`, `?csrf=1`, the token
  checks) load no OOM.

# What shipped

Branch n667. Test: `t/unit/odoo/70-a-call-to-oomd-loads-no-oom.t`.

- **The declaration, stored at save.** `Lazysite::Handlers` validates an odoo
  binding against the registry when it is saved (`_destination_problem`); it now
  also stores what the request path asks of the operation - its parameter
  declarations, whether it writes (the read or write answer the caps use), and its
  summary - in `lazysite/odoo/decl/<binding>.json` (the Odoo store, which is
  `lazysite/`, never under the docroot), written atomically. The stamp is the OOM
  version (`Odoo::Ops::Version`, which loads nothing else), the site's `odoo_packs`
  and `odoo_pack_dirs`, and the operation's name. Deleting the binding deletes the
  file. New module `Lazysite::Odoo::Decl`; the declaration is opaque data from OOM
  (no Odoo knowledge, t/lint/240).
- **The request path.** `Lazysite::Odoo::binding_class` replaces the operation
  lookup in `_ready` and `writes_of`. With `odoo_daemon` off it is `operation_class`
  exactly as before. With it on or required, it reads the stored declaration; if the
  stamp fits it is used as the operation class would be (`params`, `writes`,
  `summary`) and OOM is not loaded. `gate` asks only the installed version
  (`oom_check( light => 1 )`) in that mode. The call goes to oomd as it did.
- **Stale or missing.** A stamp that does not fit (OOM upgraded, packs changed, the
  binding changed to name another operation) or no file (a binding saved before this
  release) is re-checked in-process ONCE: the registry is read, the declaration is
  stored again with the new stamp, and the call goes on. It is recorded in the call
  record's new field **`decl`**: `stored` (the declaration was used) or `rechecked`
  (it was read again). `via` keeps saying `daemon` or `in-process`; the two are
  independent. The event log says why (`OOM 0.31 -> 0.33`, `odoo_packs changed`,
  `none`). A call with `odoo_daemon` off carries no `decl`.
- **The fallback.** With `odoo_daemon: on` and the daemon down, the call runs
  in-process as SM1164 made it; OOM is loaded at that point (`_real_class`,
  `_load_oom`), because a stored declaration cannot run an operation.
- **Measured by `%INC`** in a fresh process (t/unit/odoo/70, the real vendored oomd
  under the real supervisor): a daemon-path call loads `Odoo::Error`, `Ops::Calls`,
  `Ops::Client::Daemon`, `Ops::Daemon::Path`, `Ops::Version`, `Ops::Wire` - six, and
  none of `Registry`, `Service`, `Odoo::Client` - against 33 in-process. The same file
  asserts a stale stamp re-checks once and stores again, a changed pack list is stale,
  a missing file re-checks, a declaration changed with the OOM version is honoured
  (a matching stamp is trusted and refuses a binding that no longer fits; once the
  stamp is stale the operation's own declaration is read and the call is answered),
  the fallback loads OOM, and `odoo_daemon` off still loads it. Sabotage: with the
  stored declaration never accepted, tests 3, 4, 6, 7 and 9 fail.

# What is left, and said plainly

- **A rows parameter** (SM1166) loads OOM, for that one check: `check_rows` is an
  `Odoo::Ops::Operation` method and that module uses the registry. A request that
  feeds a list of rows pays the load; every other request does not. The fix is OOM's:
  `check_rows` as a function in a light module (to be filed with OOM).
- **A pack edited in place** under an unchanged `pack_dirs` does not change the
  stamp. The declaration is read again when the binding is saved, or when OOM or the
  pack list changes. Re-save the binding after editing a pack's parameters.
- **Still in-process, with no oomd verb** (SM1164): sign-in, sign-out, the
  two-factor step, `refresh_identity` (when an identity cookie has ended), the
  has-groups check, `action_odoo_status`, `action_odoo_bindings` (the manager's list)
  and the scheduled-key expiry read. They load OOM as before.
- **The resident endpoint** (the ~210 ms of starting programs; L-4, SM1082) and OOM's
  own extra round trip are not lazysite's to fix here.

# The margin check

`tools/bench-surfaces.sh --odoo-margin` is advisory: for one fixed read binding it
times the endpoint (one CGI request, as the bench makes them) against a direct oomd
client call (a fresh perl loading the light client, as the lab's 61 ms), and prints a
`WARN` line, with exit 0, when the endpoint adds more than the margin (default 20 ms,
`--margin-ms N`). It is never in the suite.

Tested in `t/tools/183-the-bench-warns-when-the-endpoint-adds-more-than-a-margin-to-oomd.t`
with `BENCH_MARGIN_STUB` standing in for the two timings: the WARN line appears above
the margin and not at or below it, `--margin-ms` moves it, the exit is 0 either way.
Run for real it needs `--margin-docroot` (a site with a running oomd) and
`--margin-binding` (a public read binding), optionally `--margin-query q=v`.

# Measured

Through `tools/bench-surfaces.sh --odoo-margin --n 8` (pinned to one CPU, nice 19) on
a throwaway site with `odoo_daemon: on`, the real vendored oomd under the supervisor,
one `oomd.pid` read binding, base 4c4798a6c against this branch, two runs each, the
host at load 29 (very busy, and the pinned CPU shared with it, so the figures are
high and noisy; the direction is the point):

| | endpoint (median ms) | direct oomd client (ms) | endpoint adds (ms) |
|---|---|---|---|
| base 4c4798a6c, run 1 | 941 | 164 | 777 |
| base 4c4798a6c, run 2 | 1435 | 184 | 1251 |
| n667, run 1 | 847 | 244 | 603 |
| n667, run 2 | 501 | 204 | 298 |

The module count is the exact figure: 33 Odoo modules loaded per call before, 6 after.
The remaining ~300 ms here is the endpoint's own start (the lab's ~210 ms floor of two
programs, on a busy host) and the other loads in the endpoint; the ~20 ms target needs
the resident endpoint (L-4, SM1082), and the check will keep saying WARN until then.
