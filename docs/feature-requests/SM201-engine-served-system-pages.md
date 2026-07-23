---
title: "SM201 - Engine-served system pages (fall back to protected defaults)"
subtitle: "The auth/error pages (login, claim, 402/403/404) live in the deletable content root - an agent can delete one and break sign-in, and on a multi-root site subdomains have no copy. Serve them with a three-tier fallback so a missing copy is harmless."
brand: plain
status: candidate
status-note: "SPEC for review, 2026-07-23. Field incident: a sign-up link (/claim) returned 404 - most likely the site agent deleted claim.md as stray boilerplate. Root cause is architectural: engine-required pages sit in the content root, indistinguishable from operator content. Models the existing lazysite/templates/components fallback."
---

# SM201 - Engine-served system pages (fall back to protected defaults)

## Why

The pages the engine and the auth flow REQUIRE - `login.md`, `claim.md`,
`402.md`, `403.md`, `404.md` - are shipped as `seed`-bucket starter pages
installed to the content root (`{DOCROOT}/<name>.md`), where they are
indistinguishable from operator/agent content. Three failure modes follow:

1. Deleted by an agent. A content agent tidying "boilerplate" can delete
   `claim.md`; `/claim` then 404s and sign-up / password-reset is dead (the field
   incident). `lazysite-auth.pl`'s own failure paths also redirect to `/claim`, so
   the break is total, not just the first click.
2. Missing on a subdomain. On a multi-root site (SM151), a request resolves the
   page under the domain's `content_root`. The system pages are seeded only at the
   PRIMARY docroot, so any content-rooted domain (a folder-root or a second
   registered domain) has no `claim.md` / `login.md` -> 404 on that host.
3. Absent on a migrated / bare tree. A content root populated by migration or over
   MCP (not the starter seed) may never have received them.

The 402/403/404 error pages already degrade to a bare built-in when their `.md` is
absent, so they do not hard-404; `login`/`claim` do. This spec unifies all five
under one resolution rule.

## Design - a three-tier resolution for the designated system pages

For the fixed set of system routes only (`/login`, `/claim`, `/402`, `/403`,
`/404`), resolve the source `.md` in this order and render the first that exists:

1. Per-domain content root - `$croot/<name>.md`. The domain's own copy (operator
   / agent customisation for that domain) wins.
2. Primary docroot root - `$DOCROOT/<name>.md`. Covers every EXISTING single-domain
   site (their seeded copy still serves), and lets a content-rooted subdomain
   share the primary site's copy without its own.
3. Protected engine default - `$LAZYSITE_DIR/templates/system/<name>.md`. Always
   present: shipped in the protected `lazysite/` tree (Apache-denied, on the DAV
   blocklist - an agent cannot read or delete it), `code` bucket so an upgrade
   always refreshes it.

Consequences, by design:

- All existing sites keep working - tier 2 serves their root copy unchanged.
- Subdomains work - tier 2 (shared root copy) then tier 3 (protected default).
- New / clean / migrated trees work - tier 3, with no root copy needed.
- Deleting a content-root copy is HARMLESS - it falls back to the next tier, so
  there is no need to hard-block deletion. Re-authoring a root/content-root copy
  is how you customise; deleting it reverts to the engine default.

This mirrors the existing built-in-components fallback
(`$LAZYSITE_DIR/templates/components/<name>.tt`, `lazysite-processor.pl` ~2615) -
the same "content copy if present, else the protected engine default" pattern.

## Scope of the fallback

The fallback fires ONLY for the enumerated system-page base names - it must not
turn an arbitrary missing `/foo` into a fallback lookup. The set is a small
constant in the processor: `login`, `claim`, `402`, `403`, `404`. Adding a future
system page = add its default under `templates/system/` and its name to the set.

## Packaging

- New classification rule: `^starter/lazysite/templates/system/(.+)$` ->
  `install_to: {DOCROOT}/lazysite/templates/system/$1`, bucket `code` (refreshed
  every upgrade, protected, never operator-editable).
- Ship the five defaults there (copied from today's `starter/*.md`).
- STOP seeding the root copies on fresh install: drop `login.md` / `claim.md` /
  `402|403|404.md` from the `^starter/(.+\.md)$` seed rule (an explicit exclude or
  a preceding rule), so "new sites have the files in the protected area", per the
  design. Existing sites' root copies are untouched (seed bucket, preserved) and
  still win via tier 2.

## lazysite-check probe (the safety net)

Add a check that each system route RESOLVES through the chain (a tier-1/2/3 hit),
and that the tier-3 protected defaults are present (a broken deploy is the only
way they are not). `--fix` restores a missing protected default from the staged
release. Because a missing content copy is now harmless, this is visibility, not a
break-fixer - but it also lets the operator see "this domain is serving the engine
default vs a local copy", and flag a stale root copy older than the shipped
default (adopt-the-default hint).

## Not needed once this lands

- No hard "cannot delete a system page" guard in the manager/DAV - deletion is
  self-healing.
- No separate "manifest of functional pages" store - the enumerated set in the
  processor + the `templates/system/` directory IS the manifest.

## Tests

- `/claim` and `/login` render when the content-root copy is ABSENT (tier 3), when
  only the primary-root copy exists (tier 2), and prefer the content-root copy
  when present (tier 1).
- On a content-rooted subdomain with no local copy, `/claim` renders (tier 2 root,
  then tier 3), never 404.
- Deleting `$DOCROOT/claim.md` on a single-domain site still serves `/claim` (tier
  3) - no 404.
- The fallback does NOT fire for a non-system missing page (`/nope` still 404s).
- `lazysite-check` reports each system route resolving; `--fix` restores a removed
  protected default.
- Packaging: a fresh install seeds NO root system pages but the protected defaults
  are present and served; an upgrade of an existing site preserves its root copies.

Related: SM151 (multi-root content roots - the subdomain case), SM085/SM072
(claim/auth flow), the components fallback (`lazysite-processor.pl`,
`lazysite/templates/components`), `dist/config/classification.json` (buckets),
`lazysite-check.pl`, and SM193 (migration seed gap - tier 3 covers a migrated
tree).
