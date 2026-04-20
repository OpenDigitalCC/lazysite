# Test coverage

## Overview

| | |
|---|---|
| Location | `t/` |
| Runner | `prove -r t/` |
| Framework | `Test::More` (core Perl, no extra dependencies) |
| Total | 393 tests across 26 files |

The suite is pure core-Perl. If `perl` and `prove` are installed,
the suite runs.

## Structure

```
t/
  unit/                 Function-level tests
    processor/          Core processor functions
    auth/               Password hashing, cookie signing
    forms/              Form field parsing
    users/              CLI and API mode of tools/lazysite-users.pl
  integration/          End-to-end pipeline tests
  smoke/                All starter pages render HTTP 200
  lib/
    TestHelper.pm       Shared fixture builders and subprocess runner
  run-all.t             Aggregate runner (skipped under prove -r)
```

A `t/journey/` tier for scenario-based user journey tests is
envisaged but not yet present. New journey tests should land there
rather than under `t/integration/`.

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

## Smoke tests

Every `.md` under `starter/` (excluding `/lazysite/`, `/manager/`,
and 40x templates) is rendered against a disposable docroot. Each
must return `Status: 200 OK`, `302`, or `402` - anything else fails
the test. The `402` allowance covers the intentional
`payment: required` demos.

## What is not covered

- **Remote URL fetching.** `:::include https://...`, `url:` TT vars,
  and `fetch_remote_layout` rely on live HTTP. Tested manually and
  via the SSRF-guard unit test; not exercised end-to-end.
- **oEmbed processing.** Same reason: requires live endpoints.
- **Theme upload and extraction.** Requires `Archive::Zip` and a
  real zip fixture; only the path-validation code path is exercised.
- **Manager API end-to-end via browser.** The CSRF wrapper,
  warning-bar, and per-page fetch flows are tested manually. The
  server-side endpoints are covered individually.
- **Payment flow end-to-end.** Requires x402 infrastructure to
  exercise the full loop; `check_payment` logic is unit-tested.
- **Rate limiting under load.** The `check_rate_limit` function is
  exercised once; saturation behaviour is not tested.
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
make test-safety                # process-spawn / cache-write safety
prove -rv t/                    # verbose
perl t/run-all.t                # aggregate runner (standalone; skipped under prove -r)
```

Tests self-contained: each `.t` file builds and tears down its
own `File::Temp::tempdir(CLEANUP => 1)` docroot. Nothing writes to
the repo tree.

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

**Journey tests.** The `t/journey/` directory does not exist yet.
When the first journey test is written, create the directory, add it
to the Makefile (`test-journey` target), and prefer it over
`t/integration/` for anything that exercises multiple manager actions
or a multi-step user flow.

**Conventions:**

- Use `File::Temp qw(tempdir)` with `CLEANUP => 1`. Never write into
  the repo tree.
- When a test surfaces a bug in production code, mark the assertion
  `TODO` with an explanation rather than deleting it. Fix the bug in
  a follow-up commit.
- Tests must be runnable standalone (`perl t/unit/.../x.t`) without
  running the whole suite.
