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

## Tests

### Which tests to run when (the tier ladder)

One answer per situation, so "which directory" stops being the question people
get wrong. `make tiers` prints this.

| Tier | Cost | When | What |
|---|---|---|---|
| `make tier-dev AREA=x` | seconds | every edit | compile + tidy lint, plus `t/unit/<AREA>/` |
| `make tier-review` | ~2 min | branch handoff | the whole plain suite at `-j4` |
| `make tier-release` | ~80 min | once per cut | suite, then bench, then coverage |

There is deliberately **no scheduled tier**. SM269 phase 3 has to justify one by
emitting a worklist somebody uses; measurement without a consumer is not a tier.

Two measured facts that explain the shape (SM269 phase 0/1, 6 cores): the plain
suite is ~330s sequential and ~122s at `-j4`, and the release gate is ~80
minutes of which **coverage is 92%**. So the ladder does not speed up the gate -
nothing short of phase 3 does. It exists so a problem surfaces while the code is
being written rather than at the cut.

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
