---
id: SM1316
title: "SM1316: the Hestia updater is given its stage once"
subtitle: "Every command that told an operator to run the Hestia updater named the stage twice - in the updater's path and again as its argument - though the updater defaults its stage to the release it runs from. Ruling 45: give it once."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "release manager, ruling 45 (after the 0.16.2 rollout)"
area: docs
status-note: "SHIPPED (PENDING) on n740: OPERATOR.md, UPGRADE.md, the lazysite upgrade --all hint on a Hestia host and tools/lazysite-deploy.sh drop the second stage argument; the updater's usage says it need not be given. t/lint/292, t/tools/291."
---

# What happened

The 0.16.2 rollout command was

    bash STAGE/installers/hestia/lazysite-hestia-update-all.sh --force-security STAGE

and the release manager noted the stage should not need giving twice: the
updater determines it from the folder it runs from. It does, and always has
(since the updater was added, 2026-06-23):

    STAGE="${ARGS[0]:-$(cd "$(dirname "$0")/../.." && pwd)}"

`installers/hestia/lazysite-hestia-update-all.sh` lives at
`<release>/installers/hestia/`, so the default is the release root, the same
directory the second argument named.

# What shipped

- **docs/OPERATOR.md** ("Security releases") and **UPGRADE.md** give the command
  without the second stage.
- **`lazysite upgrade --all` on a Hestia host with no registry** (SM1307) prints
  `bash <payload>/installers/hestia/lazysite-hestia-update-all.sh
  [--force-security]`, with no payload argument after it.
- **`tools/lazysite-deploy.sh`** runs `/tmp/lazysite-X.Y.Z/.../lazysite-hestia-update-all.sh
  FLAGS` without `/tmp/lazysite-X.Y.Z` after the flags. Every release it can
  deploy has the default.
- **The updater's usage** says the default is the usual form and need not be
  given. `STAGE_DIR` is still accepted, for running one release's updater
  against another's payload.
- Swept: docs/, starter/docs, tools/, installers/, lib/, the top-level docs and
  debian/. The other mentions of the updater give no stage. Left alone, as the
  ruling says: released CHANGELOG sections, released release notes, filings and
  reviews.

# Tests

- t/lint/292 reads every tracked file outside the release history (CHANGELOG.md,
  debian/changelog, docs/releases/, docs/feature-requests/, docs/review/) and
  fails on a line that runs the updater by a path and gives that same path again
  as an argument, in plain, quoted or variable form. It reads the release
  commit's FEATURES entry, briefing and index too, so it is on
  `tools/release-material.pl`'s list of lints the build re-runs (t/lint/214).
- t/tools/291's Hestia-host subtest checks the CLI's printed command as a whole
  line, without and with `--force-security` (the latter from a scratch payload
  whose manifest declares `security_critical`, as the flag requires).
- With OPERATOR.md, UPGRADE.md, the deploy hook and the CLI as before, the lint
  names the three lines and both 291 checks fail.
