# Test coverage

## Overview

| | |
|---|---|
| Location | `t/` |
| Runner | `prove -r t/` |
| Framework | `Test::More` (core Perl, no extra dependencies) |
| Total | 2048 tests across 141 files (2026-07-02) |

The suite is pure core-Perl. If `perl` and `prove` are installed,
the suite runs.

## Structure

```
t/
  unit/                 Function-level tests
    processor/          Core processor functions
    auth/               Password hashing, cookie signing, login rate limit, ui flag
    forms/              Form field parsing
    users/              CLI and API mode of tools/lazysite-users.pl
    dav/                WebDAV endpoint: gates, auth, paths, PROPFIND,
                        write methods, locking, conditionals
    manager/            Manager API helpers incl. lock-store interop
  integration/          End-to-end pipeline tests
  smoke/                All starter pages render HTTP 200
  journey/              Multi-step scenario tests
  lib/
    TestHelper.pm       Shared fixture builders and subprocess runner
  run-all.t             Aggregate runner (skipped under prove -r)
```

## Unit tests - what is covered

- **YAML front matter parsing** across every documented key: `title`,
  `subtitle`, `register`, `tt_page_var`, `tags`, `auth`, `auth_groups`,
  `query_params`, `payment_*`. Empty body, missing front matter, TT
  directive stripping, invalid-value normalisation.
- **`nav.conf` parsing:** leaves, clickable parents, group headings
  (no URL), children, comments, blank lines, missing file.
- **`scan:` directive:** file collection, front matter extraction,
  `sort=`, `filter=`, path-traversal rejection, non-`.md` rejection,
  missing directory handling.
- **Fenced divs:** class-name safelist, include/oembed pass-through,
  Markdown inside preserved.
- **`:::include` directive:** absolute paths, missing file produces
  `include-error` span, path traversal blocked, TT variable paths
  deferred to the second pass, `ttl=` modifier respected (does not
  override a pre-existing front-matter `ttl`).
- **Form directive (`:::form`):** hidden fields (`_form`, `_ts`,
  `_tk`, `_hp`), per-field rules (`required`, `email`, `textarea`,
  `max:N`, `select:...`), submit button, form-name sanitisation.
- **Auth checking (`check_auth`):** `auth: none`, unauthenticated
  redirects with `next` param, authenticated pass-through, group
  restriction, the `auth_redirect` prefix is always accessible,
  custom header names.
- **Payment checking (`check_payment`):** no payment required,
  payment proof grants access, group-based bypass.
- **Peek functions** return the expected field for valid and
  missing front matter.
- **Cache functions:** `ct_cache_path`, `write_ct` / `read_ct`,
  default content type not written, `write_html` honours
  `LAZYSITE_NOCACHE`, refuses zero-byte content.
- **Sanitisation:** `uri_encode`, `sanitise_uri` (path traversal,
  null byte, suspicious characters), TT directive stripping,
  allow-listed env-var interpolation inside conf values.
- **TT variable population:** literal keys, nav arrayref, `scan:`
  prefix, env-var interpolation.
- **Password hashing:** SHA-256 length and determinism, legacy
  hash format round-trip.
- **Cookie signing contract:** HMAC-SHA256 signature length,
  tamper detection, wrong-secret rejection.
- **`sanitise_next()`** rejects protocol-relative URLs (`//host`),
  triple-slash, backslash, absolute URLs with scheme,
  `javascript:` scheme, traversal, empty, undef.
- **Process safety:** `lazysite-manager-api.pl`'s `plugin-list`
  action spawns at most one subprocess per candidate script and
  times them out at 2s; the shared auth-secret file does not
  proliferate under concurrent first-requests.
- **User management CLI and API:** `add`, `passwd`, `remove`,
  `list`, `group-add`, `group-remove`, `groups`, new salted-iterated
  hash format, legacy hash auto-rehash, JSON API error shape.

## Integration tests

- **Page render pipeline:** plain pages, `api: true`, `raw: true`,
  fallback template when no `view.tt`, `/lazysite/*` blocked (403),
  `/lazysite-demo` not blocked.
- **Cache hit path:** first render writes cache, second render serves
  it, `LAZYSITE_NOCACHE` suppresses writes, protected pages are never
  cached and carry `Cache-Control: no-store, private`.
- **Auth flow:** unauthenticated request to a protected page
  redirects to `/login?next=...`, authenticated request serves the
  page, wrong group gets 403, correct group gets 200, login page is
  always accessible.
- **Search index:** registry template generates a JSON page listing
  pages with `register: search-index` and `search: true`; pages with
  `search: false` are excluded.

## Journey tests

Multi-step scenarios that cross subsystem boundaries:

- **`01-new-site-setup.t`:** fresh docroot renders, index is served,
  cache is written, cached reads work, `/lazysite/*` stays forbidden.
- **`02-auth-flow.t`:** user creation via `tools/lazysite-users.pl`,
  POST /login via the auth wrapper to get a cookie, use the cookie
  to serve a protected page, access without the cookie is
  redirected, rotating the secret via `action=rotate-auth-secret`
  invalidates the cookie.
- **`03-form-delivery.t`:** render a contact form to harvest
  `_ts`/`_tk`, POST to the form handler with honeypot empty, the
  submission lands as JSONL in the configured file-storage handler
  path. Replay of a valid token is currently accepted (pinned as
  current behaviour). Honeypot-filled submissions are rejected.
- **`04-edge-cases.t`:** UTF-8 content round-trips, empty front
  matter, path traversal and null byte in URI, three sequential
  renders do not collide on the atomic cache write, `ttl:` sets
  `Cache-Control: public, max-age=N`. One TODO flags a query-
  string UTF-8 mojibake bug pending a separate fix.

## Remote URL fetching

`t/unit/processor/16-remote-url-mock.t` spins up a loopback HTTP
server on a random free port, monkey-patches `is_safe_url` (which
normally rejects loopback) to permit the mock, and exercises
`fetch_url()` and `:::include` end-to-end. Covers: plain text
response, HTML response, 5xx handling, `file://` rejection,
`:::include http://...html` inlining. Runs in a single process
with a short-lived child forked for the server. No live network.

## Theme upload

`t/unit/processor/17-theme-upload.t` builds zip fixtures in-process
with `Archive::Zip`, feeds them to `action=theme-upload` via
`lazysite-manager-api.pl` as a subprocess, and checks the
filesystem result. Covers the happy path (view.tt + theme.json
extract cleanly), zip-slip rejection (entries with `../` never
reach disk), absolute-path entry rejection, missing-view.tt
rejection, missing-theme.json rejection. Skipped with a clear
message if `Archive::Zip` is not installed.

## Login rate limiting

`t/unit/auth/03-login-rate-limit.t` pins the exact saturation
boundary. The `DB_File` state is seeded directly so the test
doesn't have to iterate through real failed attempts (each of
which would sleep 2s). Covers: count=MAX-1 allows one more
credential check, count=MAX blocks with `error=rate`, a
different IP is not affected by the first IP's counter.

## Smoke tests

Every `.md` under `starter/` (excluding `/lazysite/`, `/manager/`,
and 40x templates) is rendered against a disposable docroot. Each
must return `Status: 200 OK`, `302`, or `402` - anything else fails
the test. The `402` allowance covers the intentional
`payment: required` demos.

## WebDAV (SM070)

`t/unit/dav/` exercises `lazysite-dav.pl` through the
`TestHelper::run_dav` subprocess harness (a real CGI invocation):
gate chain and Basic auth incl. the per-IP rate limiter and ignored
proxy headers (`01`), path traversal / internal-tree / blocked-path /
scope / symlink containment (`02`), PROPFIND depth 0/1 and the
PROPPATCH refusal (`03`), PUT/DELETE/MKCOL incl. size gate and cache
drop (`04`), COPY/MOVE incl. Destination validation and Overwrite
(`05`), class-2 LOCK/UNLOCK incl. refresh, flood guard, and owner
escaping (`06`), and conditionals + If lock-token enforcement (`07`).
`t/unit/manager/08-lock-interop.t` covers the manager side of the
shared lock store (honouring and not stealing DAV locks; legacy-line
compatibility). `t/integration/dav-publish.t` checks a DAV write
becomes a served page with cache invalidation; `t/journey/05-webdav-
publish.t` runs the full provision → publish → scope → lock → disable
→ credential-rotation lifecycle.

A `litmus` compliance run (`basic`, `copymove`, `locks` suites) is the
recommended manual check before a release that touches the endpoint;
the `props` suite is expected to report failures (no dead-property
store — see the feature request, §2 exclusion 3).

## Theme and layout management (SM071)

- **Preview:** `t/integration/06-preview.t` (render override, no-store +
  no cache write, tamper/expiry/malformed rejection) and
  `t/unit/manager/09-preview-grant.t` (mint → verify → render chain, CSRF,
  validation).
- **Sub-user accounts:** `t/unit/users/07-sub-users.t` (provenance,
  delegation gates), `08-account-management.t` (disable/enable, cascade,
  ancestry authorisation, reassign, and disabled-denied-over-DAV),
  `09-capabilities.t` (the manage_* flags), `10-token-lifecycle.t`
  (pairing → exchange → rotate, expiry enforced over DAV),
  `11-partner-create.t` (partner provisioning + onboarding brief).
- **Control API and authoring:** `t/unit/dav/08-layout-authz.t`
  (per-object active/inactive rule, capability gating, dav_scope
  orthogonality), `09-manifest.t` (lzs:sha256 property),
  `10-rate-limit.t` (write throttle + Retry-After, 423 Retry-After);
  `t/unit/manager/10-control-api.t` (token auth, capability gating, CSRF
  exemption, actor injection), `11-activate-backup.t` (validation, base
  conflict, lock, snapshot), `12-layout-activate.t` (compile gate,
  compatible pair), `13-rate-limit.t` (control-API 429).

## What is not covered

- **oEmbed processing.** Requires live oEmbed endpoints.
- **Manager API end-to-end via browser.** The CSRF wrapper,
  warning-bar, and per-page fetch flows are tested manually. The
  server-side endpoints are covered individually.
- **Payment flow end-to-end.** Requires x402 infrastructure to
  exercise the full loop; `check_payment` logic is unit-tested.
- **Browser rendering.** No Selenium / Playwright layer.

These are the known gaps. Tests that surface bugs should be kept
even when failing - mark them as `TODO` with a reason and a pointer
to the relevant issue.

## Running the suite

```
prove -r t/                     # full suite
make test-unit                  # unit tests only
make test-integration           # integration tier
make test-smoke                 # all starter pages
make test-journey               # multi-step scenarios
make test-safety                # process-spawn / cache-write safety
prove -rv t/                    # verbose
perl t/run-all.t                # aggregate runner (standalone; skipped under prove -r)
```

Tests self-contained: each `.t` file builds and tears down its
own `File::Temp::tempdir(CLEANUP => 1)` docroot. Nothing writes to
the repo tree.

## Measuring coverage (WP-2 / D2)

The tests run the CGIs as **subprocesses** (`open2`/`open3` with `$^X`), so a
plain `cover -test` instruments only the parent `prove` process and reports
`n/a` for the scripts that matter. `tools/coverage.sh` solves this by exporting
`PERL5OPT=-MDevel::Cover=...` so **every** `perl` invocation - the test scripts
*and* the spawned CGIs - loads Devel::Cover and writes to one shared
`cover_db`, which `cover` merges into a single report.

```bash
tools/coverage.sh            # run the suite under coverage, print the report
tools/coverage.sh --check    # also enforce the declared floor (exit 1 if below)
```

It is slow (every subprocess is instrumented), so it is a **signoff** tool: it
runs in the release gate (`tools/release.sh`) and on demand, not as part of
`prove -r t/`. The declared floors live in `dist/config/coverage-floor`:
**60% statements AND 60% branches** per gated CGI (the eight-dimension
framework requires line and branch thresholds); under the Commercial regime
the target is **75%** statements. `lazysite-manager-api.pl` carries a
documented per-file branch-floor override (its branch measurement is noisy
run-to-run under subprocess instrumentation - see the floor file).

Tests that rebuild `%ENV` from scratch for a CGI child must splice in
`TestHelper::env_passthrough()`, or the child never loads Devel::Cover and the
CGI reports "not measured" - this was why `lazysite-auth.pl` (and the
`Manager::Plugins`/`Upload` handlers) looked uncovered for weeks while being
tested all along.

### Measured baseline

Full suite, subprocess-instrumented (2026-07-02, after the eight-dimension
review hardening), statement / branch:

| Component | stmt | branch | note |
|---|---:|---:|---|
| `lazysite-dav.pl` | 93% | 73% | |
| `tools/lazysite-bundle-apply.pl` | 90% | 65% | |
| `tools/lazysite-users.pl` | 89% | 70% | |
| `lazysite-processor.pl` | 83% | 69% | standalone, unchanged |
| `lazysite-auth.pl` | 82% | 61% | newly gated (env_passthrough fix) |
| `lazysite-manager-api.pl` | 71% | 57-72% | branch noisy run-to-run; override in floor file |
| `Lazysite::Util` | 100% | 92% | in-process unit-tested |
| `Lazysite::Auth::Acl` | 100% | 85% | in-process |
| `Lazysite::Auth::Session` | 100% | 73% | in-process |
| `Lazysite::Auth::Credential` | 100% | 72% | in-process |
| `Lazysite::Audit` | 100% | 70% | in-process |
| `Lazysite::Manager::Files` | 96% | 72% | |
| `Lazysite::Auth::Settings` | 96% | 69% | in-process |
| `plugins/stats.pl` | 94% | 68% | |
| `Lazysite::Manager::Common` | 88% | 76% | in-process |
| `Lazysite::Manager::Upload` | 82% | 69% | handlers now measured (was 37/29) |
| `Lazysite::Manager::Themes` | 76% | 52% | |
| `Lazysite::Manager::Layouts` | 75% | 54% | |
| `Lazysite::Manager::Backups` | 70% | 56% | |
| `Lazysite::Manager::Plugins` | 66% | 43% | handlers now measured (was 21/11) |

The old "under-measured modules" caveat is resolved: `Plugins`/`Upload` showed
21%/37% because %ENV-rebuilding tests dropped `PERL5OPT`, so their subprocess
children were never instrumented - a measurement artifact fixed by
`env_passthrough()`, not a test gap. `install.pl` remains outside the gate
(its tests exercise a tempdir-copied tree end to end). Floors are ratcheted
upward as coverage improves, never down.

**The under-measured modules are a test-style artifact, not a gap.**
`Manager::Plugins` and `Manager::Upload`'s `action_*` handlers show ~0 because
they are exercised only by **subprocess** integration tests, whose coverage does
not aggregate into `cover_db` - whereas `Themes`' handlers, hit by **in-process
`LOAD_ONLY`** tests, measure fine. The handlers are tested (the suite is green);
they just don't register. The clear next step the refactor unlocks: add
in-process unit tests that call those handlers as **module functions** (as the
Upload pure-function tests already do), which both raises and correctly measures
them toward the 75% target.

## Writing tests for new features

**Unit tests.** Put them under `t/unit/<area>/`. Load the processor
into the current Perl process via `TestHelper::load_processor($docroot)`
and call functions as `main::func(...)`. The helper silences the
processor's stdout during the `do`-load so the 404 response that
`main()` produces for the placeholder URL does not pollute the TAP
stream.

```perl
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

is( main::parse_yaml_front_matter("---\ntitle: X\n---\nbody\n"),
    ... );
done_testing();
```

**Integration tests.** Put them under `t/integration/`. Use
`TestHelper::run_processor($docroot, $uri, %env)`, which spawns the
processor as a subprocess and returns the full CGI output. This is
the right tier for testing cache behaviour, auth redirects, content
types, and anything that depends on `main()` running end-to-end.

**Fixture builders** in `TestHelper.pm`:

- `setup_minimal_site($docroot)` - `lazysite.conf`, index, 404
- `setup_test_site($docroot)` - adds a minimal `view.tt`,
  `api-test.md`, `raw-test.md`
- `setup_auth_site($docroot)` - adds users, groups, protected
  pages, admins-only page, login page, sets `auth_proxy_trusted:
  true` so `HTTP_X_REMOTE_USER` env vars in tests are honoured
- `setup_search_site($docroot)` - adds a registry template and
  searchable/hidden pages

**Journey tests.** For flows that span multiple subsystems or
multiple requests, add a file under `t/journey/` rather than
`t/integration/`. Journey tests may legitimately do things that
integration tests should not: spawn multiple subprocesses,
manipulate cookies, sleep for timestamp-age checks, seed `DB_File`
state directly to avoid real-time iteration.

**Conventions:**

- Use `File::Temp qw(tempdir)` with `CLEANUP => 1`. Never write into
  the repo tree.
- When a test surfaces a bug in production code, mark the assertion
  `TODO` with an explanation rather than deleting it. Fix the bug in
  a follow-up commit.
- Tests must be runnable standalone (`perl t/unit/.../x.t`) without
  running the whole suite.
