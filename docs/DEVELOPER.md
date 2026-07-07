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
| `lazysite-processor.pl` | the request pipeline: render Markdown pages, TT, cache, registries, auth/payment gates, the trust gate |
| `lazysite-auth.pl` | cookie login, claim redemption, pairing-key exchange, token rotation, forgot-password, TOTP - sets `X-Remote-*` for downstream CGIs |
| `lazysite-manager-api.pl` | the manager UI back-end + the token control API |
| `lazysite-dav.pl` | the WebDAV (class 1+2) publishing endpoint with its own Basic auth |
| `tools/lazysite-users.pl` | the account/credential CLI (also called as an API by the others) |
| `install.pl` / `tools/build-manifest.pl` / `tools/manifest-to-sbom.pl` | install + release tooling |

Capabilities are per-account settings read **per request** (`webdav`,
`manage_themes/layouts/config`, `create_sub_users`, `ui`); enforcement lives in
`lazysite-dav.pl` (`authorise`) and the manager API.

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

Five-level taxonomy under `t/`: `unit/`, `integration/`, `journey/`, `smoke/`,
`lint/`, plus `tools/`. Run `prove -r t/` (≈1,275 tests). The CGIs are exercised
as **subprocesses** (`open3`/`open2`) with CGI env, or in-process via a
`LOAD_ONLY` hook. `t/lib/TestHelper.pm` has the fixtures (`setup_dav_site`,
`run_processor`, …). `tools/bench.pl --check` is the performance gate.

## Where to start a change

1. Read the relevant `docs/feature-requests/SM0xx-*.md` (the design of record).
2. Add tests first where practical (red→green).
3. Keep the change in one self-contained script; update the architecture doc +
   CHANGELOG (commit-ref keyed).

The release contract and commit flow are in [development.md](development.md).
