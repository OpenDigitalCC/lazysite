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
`docs/architecture/code-quality.md`). Core-Perl only, plus optional Template
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
| `make tier-review` | ~2 min | branch handoff | the whole plain suite at `-j4` |
| `bash tools/handoff.sh [--release]` | ~2 min | **before a branch is offered for review** | tier-review plus the review's own tripwires (clean tree, compile, the mangled-literal check, bench with `--release`); prints the one line the handover carries (SM764) |
| `make tier-release` | ~80 min | once per cut | suite, then bench, then coverage |

There is deliberately **no scheduled tier**. SM269 phase 3 has to justify one by
emitting a worklist somebody uses; measurement without a consumer is not a tier.

Two measured facts that explain the shape (SM269 phase 0/1, 6 cores): the plain
suite is ~330s sequential and ~122s at `-j4`, and the release gate is ~80
minutes of which **coverage is 92%**. So the ladder does not speed up the gate -
nothing short of phase 3 does. It exists so a problem surfaces while the code is
being written rather than at the cut.

**A branch is not offered for review without `tools/handoff.sh` saying READY.**
The 0.13.4 cut was launched three times because two faults - one a textual
pin one test file over from the change - reached review and the build without
the whole suite having been run on the branch; each cost a review round-trip
through a release manager who was not watching (SM764). The tier existed; the
script is what makes running it the handover rather than a step before it.

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

## Where to start a change

1. Read the relevant `docs/feature-requests/SM0xx-*.md` (the design of record).
2. Add tests first where practical (red→green).
3. Keep the change in one self-contained script; update the architecture doc +
   CHANGELOG (commit-ref keyed).

The release contract and commit flow are in [development.md](development.md).
