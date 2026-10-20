---
title: "lazysite - Changelog"
subtitle: "Release history, newest first. Tags are the stable identifiers."
brand: plain
standard-margins: true
---

## About this changelog

Versioning
: Releases are git tags (`vX.Y.Z`). Since SM063, `main` is unstable and
  carries unreleased work. Since SM971 a release is ONE commit on `main` -
  this file's section, the FEATURES entry, `VERSION`/`NEXT_VERSION`, the
  briefing, the index and the gate record, written by
  `tools/release-material.pl` - and the tag names that commit.

Keying
: Entries are high-level. Released versions are keyed by tag; unreleased
  entries are keyed by SM number and short commit ref.

Shipped versus mentioned
: An item that SHIPPED in a release **begins its own bullet and names the commit
  that implemented it** - `- SM238 (37e7c37) per-domain tools over MCP`. The
  commit ref is what marks it as built rather than merely written down, so a
  bullet like `- SM184 (publish pages by email) recorded as a candidate proposal`
  is a filing, not a ship. An SM number appearing anywhere else in an entry, such
  as inside a `Docs:` bullet, is likewise a reference: newly filed backlog items
  are routinely listed that way while still open.
  `t/lint/26-backlog-status-matches-changelog.t` relies on this distinction to
  check that everything a release claims to have shipped is marked accordingly
  in `docs/feature-requests/`, so the two cannot drift apart unnoticed.

Naming the commit: AFTER it lands, never before
: vcs-review lands a branch onto `main` **by rebase**, which gives every commit
  a new SHA. So a ref written while the work is still on a branch is stale the
  moment it lands - and the old object lingers in the reflog just long enough
  for a spot check to pass ([[SM354]], where seventeen entries were wrong and
  seven named commits that no longer existed).

  While the work is on a branch, write `(PENDING)`. The release commit
  replaces it with the landed SHA - the commit that added that exact line -
  and the build refuses an entry whose commit it cannot tell (SM971).
  `t/lint/53-changelog-commit-refs-exist.t` ignores `(PENDING)` and fails on any
  ref that no branch contains, so the placeholder is safe and a stale ref is
  not. SM354's own entry went stale in its own landing, which is how this
  paragraph came to be written.

Archive
: This file holds the current minor release line and Unreleased. Earlier
  releases are in `docs/releases/CHANGELOG-archive.md` (SM946), moved there
  unchanged by the release commit of a new minor; the lints that check history
  read both.

## Unreleased

- SM1219 (PENDING) **the visitor log names the signed-in account.** A visit made while signed in is
  recorded with the account the engine verified (never a header a client sent; an anonymous
  visit has none), kept as long as the rest of the log. analyse_visitors takes `by_account`
  (analytics; a domain-confined caller sees only its own domains' accounts) and the manager
  Stats page lists the visits per account. The analytics capability's text no longer says it
  cannot identify a visitor. Account names are personal data: telling members is the operator's
  duty (operator guide).
- SM1118 (PENDING) **a site can be put into maintenance.** `maintenance: on` (Config page; per
  domain on the Domains page, `alias.<host>.maintenance: on`, with the instance switch covering
  all) sends every page request by 302 to `maintenance_page` (default `/maintenance`, a shipped
  system page); the page answers 503 with Retry-After (`maintenance_until`, UTC). A new
  capability, `maintenance_access` (Access during maintenance), is what gets an account through:
  the operator group holds it, on upgrade too, and any group can be given it. A posted form is
  refused and not stored, and MCP, the control API, WebDAV and the data endpoint answer 503 to an
  account without it. The check is in the processor, so it holds behind the wrapper, on the
  split templates and in the one-rule pool. `lazysite check` warns while it is on.

## 0.16.0 - STABLE: the stable release of the 0.15 line (2026-10-22)

- SM1230 (902e2784) **coverage fits around the night's other work.** The 01:30 cover-once was refused on
  2,904 MB of swap in use with 7,075 MB available (the host carries swap all day). Swap in use no longer
  refuses a heavy job (a note, as in the gate); only MemAvailable under 5 GB, disk, inodes or the lock do.
  A stand-alone `tools/coverage.sh` runs under `nice -n 19 ionice -c3` with 2 jobs (`LAZYSITE_COVER_JOBS`),
  has no time limit, resumes from the groups already recorded, and a second start exits 2.

- SM1231 (d5739370) **docs: the stable gate's records are walked for the 0.16.0 stable.** The
  threat model (`docs/architecture/security.md`, `docs/SECURITY.md`) takes in the trust
  changes since 0.11; the held SM1219 and SM1118 are held for 0.16.1, not in the 0.16.0
  stable. The significant-change register has ten drafted entries for the release manager
  to confirm; SM747's (the Odoo extension) is accepted. OBLIGATIONS.md and TECHNICAL-FILE.md
  are walked row by row against the code of 0.15.15 (which is 0.16.0's) and stamped 0.16.0,
  with what a person must confirm, and the Declaration of Conformity is an unsigned draft
  for 0.16.0, saying so at its top. Docs only; nothing is signed.
