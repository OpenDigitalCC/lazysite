# lazysite - Developer guide

For someone **changing lazysite's code**. The deep references live under
[docs/architecture/](architecture/) and [docs/development.md](development.md);
this is the orientation.

## Architecture in one screen

lazysite is a set of **Perl CGI scripts over a shared `lib/Lazysite/` module
tree** (19 modules since the SM079 modular refactor: `Util`, `Audit`,
`Auth::*`, `Manager::*`, `Capabilities`, `Fetch`, `BadUrl`, `Aliases`). The one deliberate exception is the **processor's
render path**, which stays module-free so the page-serving hot path has no
`@INC` dependency (see `docs/adr/0001-capability-resolution.md` and
`docs/architecture/code-quality.md`). Since SM944 the processor is split by area
into **parts** under `lazysite-processor/`: package-main files it requires by
absolute path from beside itself, never through `@INC`, so the property holds.
State a part shares with the script is declared `our` in the script and aliased
in the part with a bare `our ( ... );`; a part never names the script's `my`
variables (t/lint/215).
Core-Perl only, plus optional Template
Toolkit / Archive::Zip / DB_File.

| Script | Role |
|---|---|
| `lazysite-processor.pl` | the request pipeline: render Markdown pages, TT, cache, registries, auth/payment gates, the trust gate; dual-mode (CGI / FastCGI accept loop) |
| `lazysite-auth.pl` | cookie login, claim redemption, pairing-key exchange, token rotation, forgot-password, TOTP - sets `X-Remote-*` for downstream CGIs |
| `lazysite-manager-api.pl` | the manager UI back-end + the token control API |
| `lazysite-dav.pl` | the WebDAV (class 1+2) publishing endpoint with its own Basic auth |
| `tools/lazysite-users.pl` | the account/credential CLI (also called as an API by the others) |
| `install.pl` / `tools/build-manifest.pl` / `tools/manifest-to-sbom.pl` | install + release tooling |
| `tools/lazysited.pl` + `lib/Lazysite/Daemon/` | the persistent runtime (SM666): a supervisor, one child per service, a scheduler running engine jobs as a `run_jobs` account; born disabled (ADR 0009), `lazysited@.service` per site |

**Dual-mode dispatch (SM142).** The processor detects a FastCGI listen
socket on fd 0 (the spawn-fcgi convention, used by the SM139
`lazysite@.service` pool unit via `tools/lazysite-pool.pl`) and services
requests from a persistent accept loop; invoked as plain CGI it takes the
single-shot path, byte-identical to before. Both paths share
`handle_one_request` (per-request state reset + the die-guard); `FCGI` /
`FCGI::ProcManager` are lazy-required, so the CGI path has no new
dependency. When adding request-scoped state, reset it in
`reset_request_state` - state isolation across consecutive pool requests is
pinned over the real FCGI protocol via `t/lib/MiniFcgi.pm`.

**The persistent runtime (SM666).** Since 0.13.0 a site may run a second per-site
process beside the pool: `tools/lazysited.pl` starts `Lazysite::Daemon::Supervisor`,
which forks one child per service in `services()` (phase 1: the scheduler),
restarts a dying one with backoff until a ceiling, and reports through the
`Lazysite::Lifecycle` contract. **A job is engine code**: the closed table
`%JOBS` in `Daemon/Service/Scheduler.pm` names each with `every` (seconds),
`needs` (the capability the same work costs through the manager - the test reads
it from the manager API's gate table, so a job cannot need less) and `run` (a
body in `Daemon/Jobs.pm` taking `docroot` and `actor`, returning
`{ ok, detail }`, `{ ok => 0, error }`, or dying). Jobs run as the configured
`daemon_job_user`, which must exist and hold `run_jobs`; a refusal is recorded,
not a run. No configuration can add a job. The run record
(`lazysite/daemon/scheduler-runs.json`) is the operator's only view of what a
job did, so `detail` carries numbers. Tests: `t/unit/daemon/`.

Capabilities are channel x action grants carried by **groups**
(`lazysite/auth/groups-settings.json`, edited on the manager Groups page; see
`docs/adr/0003`), resolved per request through the one resolver
(`Lazysite::Auth::Settings::caps_for`); enforcement lives in `lazysite-dav.pl`
(`authorise`), the manager API, and the MCP connector.

## Conventions

- **Self-contained CGIs**, core-Perl, no CPAN at runtime. New deps must be added
  to `dist/config/sbom-deps.json` or the strict SBOM gate fails the release.
- **`.perlcriticrc`** is the enforced lint profile; `return undef` is the project
  idiom (see code-quality.md).
- **`.perltidyrc`** is the formatting profile, gated CHANGED-CODE-ONLY: the
  existing hand-formatting stays, but code you add or edit must match it. Run
  `perltidy -b <file>` on what you touch, or `tools/tidy-check.pl` to see which
  lines the gate (`t/lint/06-tidy.t`) will flag.
- **Conventional names** (view.tt, lazysite.conf, /manager, …) are settled -
  see code-quality.md.
- **Engine-owned vs author files.** The engine owns `lazysite/auth`, `lazysite/cache`,
  `lazysite/manager`, `cgi-bin`, the `*.pl` scripts and the form-secret configs;
  these are protected (the WebDAV blocklist and the whole-`lazysite/` denial refuse
  writes to them) and enumerated for agents in the capability map's `engine_owned`
  list. A partner should reach the site through the API / MCP / WebDAV surfaces,
  never by editing the engine. For an author's own *private* content (drafts, notes
  not meant to publish), the convention is an `_` prefix (e.g. `_drafts/`) as a
  do-not-touch signal; it is a convention for new content, not a rename of the
  existing tree and not an enforced mechanism.

## Validating page source (SM887 F2)

`Lazysite::Validate` is the engine's page checker, and every surface that wants
one calls it rather than growing its own. It was `_validate_page` inside
`lazysite-mcp.pl`, reachable only by an authenticated partner over HTTP against
a live site; it is a module now, so CI, a pre-commit hook, a test, or a person
with a file can ask the same question and get the same answer.

```perl
use Lazysite::Validate qw(validate_content validate_file);
my $r = validate_file( $path, docroot => $d );   # docroot optional
#  { valid => 0|1, issues => [...], warnings => [...] }
```

On the shell, and the reason the exit status exists:

```sh
lazysite validate page.md && publish     # 1 on an issue, 2 on bad usage
lazysite validate --docroot /srv/site --json page.md
lazysite validate --strict page.md       # warnings count too
```

- **A message carries its own `severity`** (`issue` / `warning`), plus `kind`,
  `message`, `line` where there is one, and `file` where the caller gave one.
  MCP still returns them split into `issues` and `warnings`, because that is
  what partners parse.
- **`valid` is false only for an ISSUE.** A warning is a judgement the author
  may have made deliberately, and a gate that failed on those would be a gate
  people learn to bypass.
- **Two checks need a site** - `db:` table bindings and whether a named form is
  bound. Without a docroot they report that they could not check, rather than
  passing: a check that skips silently is a check that always passes.

## Tests

### Which tests to run when (the tier ladder)

One answer per situation, so "which directory" stops being the question people
get wrong. `make tiers` prints this.

| Tier | Cost | When | What |
|---|---|---|---|
| `make tier-dev AREA=x` | seconds | every edit | compile + tidy lint, plus `t/unit/<AREA>/` |
| `bash tools/precheck.sh` | minutes | each commit, and **the handoff's test run** | every lint, the tests naming a changed file, and the tests of each AREA the change touches (`tools/precheck-areas.pl`, SM1061) |
| `bash tools/handoff.sh [--stack BASE]` | minutes | **before a branch is offered for review** | the precheck on each stack branch plus the review's own tripwires (clean tree, the generators, the mangled-literal check, the tracked-tree check); prints the one line the handover carries (SM764, SM1061) |
| `bash tools/suite.sh` (`make tier-review`) | ~18 min | **on demand** | the whole plain suite at `-j<nproc>`, one run at a time on the host (a lock in the common git dir; a second run waits) |
| `bash tools/handoff.sh --full` / `--release` | + the suite | a branch that wants the suite / a branch bound for a cut | the handoff plus `tools/suite.sh`; `--release` adds the bench |
| `tools/gate-main.sh` | the release gate | **required for a release**: after a landing, before a cut | `tools/release.sh gate`: suite, bench, coverage on main's tip |
| `make tier-release` | ~80 min | by hand, once per cut | suite (through `tools/suite.sh`), then bench, then coverage |
| `bash tools/overnight.sh` | the night | 00:30, from claude's crontab | **where READY comes from**: the queued stacks prechecked, cherry-picked onto main in queue order and tested with one whole suite (`tools/integration.pl`, SM1062); an empty queue runs `tools/suite.sh --nightly` on main |

**The whole suite is not the handoff (SM1061).** The release manager ruled on
2026-10-12: *a targeted subset on each commit and handoff (precheck); the whole
suite on demand; the whole suite required for a release; and, as safety nets,
"Area subset + nightly".* That day four agents each ran the whole plain suite
in their handoff at once on an 8-core host; the load reached 26-30 and every
suite slowed from ~1,080 s to ~1,950 s - and the handoff suite caught nothing:
every handoff fault was found by the precheck, and the one cross-stack clash
(t/unit/processor/101, broken by a change to `lazysite-processor/sources.pm`)
by a whole-suite run on main. The precheck now runs the tests of every area a
change touches, which selects that test.

**The overnight queue: the night tests what is about to land (SM1062).** The
release manager ruled on 2026-10-12: *"maybe the suite runs on its own branch,
not main, then the review process checks that in to main"*. A stack is queued
rather than handed off in the day: `bash tools/overnight.sh --queue WORKTREE TIP
[--full|--release]` appends `WORKTREE TIP [FLAG]` to `tmp/overnight/queue.txt` in
the main checkout (FLAG is still accepted and changes nothing: every stack gets
the whole suite, and the bench is the release gate's). At 00:30
`tools/overnight.sh` takes the whole queue (lines added while it runs wait for
the next night) and runs `tools/integration.pl` at nice 19 and idle I/O:

1. **Release.** Every queued worktree, and any worktree holding a branch of a
   queued stack, is detached at main, so vcs-review can offer the branches in
   the morning. One with uncommitted changes is left alone; its stack is NOT
   READY.
2. **Precheck** each stack as `tools/handoff.sh` does - each branch against the
   one below it. A failure is NOT READY and stays out of the tree.
3. **Build** `tmp/wt-integration`, a detached worktree, fresh from main: each
   stack's commits that `git cherry` says are not yet applied are cherry-picked
   in queue order. vcs-review lands by cherry-pick, so landing the stacks in
   that order makes main this tree - a merge would test a tree no landing
   produces. A stack that does not apply is reported `CONFLICT with <earlier
   stack>: files` (or with main), left out, and the rest continue; a commit
   already on main (a stack landed in part) is skipped. The tip is kept as
   `review/assess/integration`: vcs-review offers no `review/assess/` branch
   (`review/integration` it would offer).
4. **One whole suite** on that tip, `tools/suite.sh --tree tmp/wt-integration`:
   the host-wide suite lock, nice 19, idle I/O, inside the 5 h the whole run
   keeps to. A held lock is a skip, and the stacks go back on the queue.
5. **The verdict**, in `tmp/overnight/results-DATE.txt`. GREEN: `LAND IN THIS
   ORDER:`, the stack tips with SHAs, and a `READY FOR REVIEW: BRANCH SHA (...)`
   line per branch, as `tools/handoff.sh` prints it. RED: each failing test file
   is run again alone - on main, on each stack applied alone on main, and, when
   no single stack fails it, on each pair - and put down to `main itself`,
   `stack X` or `stacks X+Y together (clash)`. Only the stacks named are NOT
   READY; the rest are READY and say they were not implicated. A red night, or
   any CONFLICT, also files `DATE-overnight-integration-red|green.md` in
   `inbox/`; a green night files nothing there.

An empty queue (or one where every stack was left out) runs the plain nightly
instead: `tools/suite.sh --nightly`, the whole suite on main's tip in
`tmp/wt-nightly`, logged to `tmp/nightly/DATE.log` (the newest 14 kept); a
failure files `DATE-nightly-suite-failed-on-SHA.md` in `inbox/`. Either way main
is checked every night. A second overnight run finds the runner lock held and
logs a skip rather than queueing, so one night cannot overlap the next.
`tools/handoff.sh` keeps its daytime role: a quick precheck-only check for an
agent that wants one before queueing.

Two measured facts that explain the shape (SM269 phase 0/1, 6 cores): the plain
suite is ~330s sequential and ~122s at `-j4`, and the release gate is ~80
minutes of which **coverage is 92%**. So the ladder does not speed up the gate -
nothing short of phase 3 does. It exists so a problem surfaces while the code is
being written rather than at the cut. (The suite has since grown to ~1,200
files; on 2026-10-12 it took ~1,080 s on a quiet host.)

**A branch is not offered for review without `tools/handoff.sh` saying READY.**
The 0.13.4 cut was launched three times because two faults - one a textual
pin one test file over from the change - reached review and the build without
the whole suite having been run on the branch; each cost a review round-trip
through a release manager who was not watching (SM764). The tier existed; the
script is what makes running it the handover rather than a step before it.
Since SM1061 what that script runs is the precheck, widened by area; the whole
suite is on demand, nightly, and required for a release. Since SM1062 the READY
a stack is offered with comes from the overnight integration run, which runs
that precheck and then the whole suite on the stack together with everything
else queued; `tools/handoff.sh` by day is the quick check before queueing.

Every tier passes `-l`. Without it, tests that load `Lazysite::` modules die
with zero tests run and `prove` reports a failure whose cause is not on screen.


Five-level taxonomy under `t/`: `unit/`, `integration/`, `journey/`, `smoke/`,
`lint/`, plus `tools/`. Run `prove -r t/`; the run prints its own totals on the
final `Files=… Tests=…` line, which is the number to quote. (A count written
into prose here is stale by the next release and misleads about the suite's
size - this one said "≈2,700" while the suite had grown well past it.) The CGIs are exercised
as **subprocesses** (`open3`/`open2`) with CGI env, or in-process via a
`LOAD_ONLY` hook. `t/lib/TestHelper.pm` has the fixtures (`setup_dav_site`,
`run_processor`, …). `tools/bench.pl --check` is the performance gate.

## The Odoo extension's tests and OOM (SM1081)

The Odoo extension uses OOM (`libodoo-oom-perl`), which is another project and changes on its
own schedule. **An OOM change must never stop a lazysite build** (release manager,
2026-10-14: "it isn't intended that oom changes will prevent a lazysite build ... we can't be
testing against odoo to run a lazysite, it's just an extension, not core"). So:

- **Every Odoo test runs on a pinned snapshot of OOM inside the repository**, `t/vendor/oom/`:
  its library, its test doubles, its data and its specification, taken from one released commit.
  `t/lint/261` holds it to its `MANIFEST`, so it never changes by accident; `t/lint/262` fails
  any file under `t/`, `lib/` or `tools/` that names OOM's tree or reads OOM from the host's
  perl5 directory. Nothing in the gate reads `/srv/projects/odoo` or an installed OOM.
- **Adopting a newer OOM is one reviewable commit**: `tools/vendor-oom.sh [--deb FILE] COMMIT`
  refreshes `t/vendor/oom/`, rewrites the `MANIFEST`, and prints what the SM747 filing's copy
  of the specification must now say. Update the filing in the same commit; `t/lint/207`
  fails until the filing and the snapshot agree. Run the Odoo tests, and the compatibility
  tier below, before proposing it.
- **The compatibility tier is advisory**: `tools/ext-compat.sh` runs the same tests against the
  installed deb and against OOM's tree, one line per target. It always exits 0 and is never the
  gate. `tools/overnight.sh` runs it after the nightly suite and a failing target files one
  short note in the inbox. `LAZYSITE_OOM_LIB` and `LAZYSITE_OOM_TEST_LIB` exist for it alone.
- **Live Odoo is never in an automatic run.** `tmp/live/odoo-live.pl` is manual: read-only unless
  `--writes` is given, and `--writes` refuses to run unless its config says
  `test_database: yes`. It never prints a password, key or session id.
- The lazysite packages do not depend on OOM: `debian/control` has no `libodoo-oom-perl` in any
  relation. The extension declares it (`owns.deps`) and refuses, by name, when it is missing or
  older than 0.03.

## Where to start a change

1. Read the relevant `docs/feature-requests/SM0xx-*.md` (the design of record).
2. Add tests first where practical (red→green).
3. Keep the change in one self-contained script; update the architecture doc +
   CHANGELOG (commit-ref keyed).

The release contract and commit flow are in [development.md](development.md).
