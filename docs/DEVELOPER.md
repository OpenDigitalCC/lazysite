# lazysite - Developer guide

For someone **changing lazysite's code**. The deep references live under
[docs/architecture/](architecture/) and [docs/development.md](development.md);
this is the orientation.

## Architecture in one screen

lazysite is a set of **self-contained Perl CGI scripts** - no shared modules,
by deliberate convention (helpers are duplicated across scripts rather than
factored into a library; see `docs/architecture/code-quality.md`). Core-Perl
only, plus optional Template Toolkit / Archive::Zip / DB_File.

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
- **`.perlcriticrc`** (severity 4) is the enforced lint profile; `return undef`
  is the project idiom (see code-quality.md).
- **Conventional names** (view.tt, lazysite.conf, /manager, …) are settled -
  see code-quality.md.

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
