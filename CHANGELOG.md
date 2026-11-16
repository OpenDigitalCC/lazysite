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

## 0.17.1 - STABLE: the bad-URL blocker counts probes behind Apache (2026-11-16)

- SM1456 (f0226a87) **docs: the compliance records cover 0.17.1, a stable patch.** OBLIGATIONS.md
  and TECHNICAL-FILE.md are patch-walked against `git diff v0.17.0 main` and stamped 0.17.1: the
  one line that ships (SM1455) and the release tooling (SM1454) touch the register, threat-model,
  technical-file, significant-change and vulnerability-handling rows; the rest stand as walked
  for 0.17.0. SM1455's register entry and STRIDE row are drafted by the developer agent; for the
  release manager's confirmation. The bench is not re-captured and the Declaration is not
  stamped.
- SM1455 (cc154218) **security: the bad-URL blocker counts probes behind Apache.** The auth
  wrapper took its path from `REDIRECT_URL`, which Apache sets only on an internal redirect and
  leaves unset on the two routes into the wrapper (the source-type rewrite `[PT]` and
  `FallbackResource`), so the blocker checked `/` for every request and never counted a probe:
  eleven requests for `/wp-login.php` from one address were all answered 404. The wrapper's path
  is now `REDIRECT_URL`, else `REQUEST_URI` less its query, as the front door's is. Access
  rules were never affected (the processor reads the right path). A real-Apache test
  (t/integration/732) sends probes by both routes; t/integration/14 stops setting
  `REDIRECT_URL` where Apache would not.
- SM1454 (3d1756c0) **release: a patch gates on its diff, a tree is never run twice, and a patch's
  register entry is confirmed once.** The 0.17.0 gate spent 2096 s in the full suite and under two
  minutes in every other stage; a one-line patch would have cost the same. R2: the suite stage keeps a pass by the tree id
  of the gated commit, the version, the channel and the suite mode (`tmp/release-gate/suite-passes/`),
  a gate of a recorded tree says so in one line, skips the suite and names the record in the
  receipt, only a pass writes one, and a damaged record refuses by name (ruling 206);
  `LAZYSITE_SUITE_FRESH=1` ignores them. R1: `tools/gate-main.sh --patch` (and
  `release.sh gate --final --patch`) gates a stable patch on its diff from the line's last release,
  whose gate receipt must say pass: every lint, `bench --check` and the precheck's selection
  (`tools/precheck-select.sh`, now shared with `tools/precheck.sh`; `tools/patch-plan.pl`); it runs
  the whole suite, and says why, for a change to `t/lib/`, a lint's library, the release and
  precheck tools, the build's control files or a file the area map does not cover. The receipt says
  `suite=patch (base vX.Y.Z, N files)` or why it is full, and build accepts it for a stable whose
  base is the receipt's. `LAZYSITE_SUITE_RUNNER` hands the full suite to an external runner. R4: a
  register entry drafted on the patch's branch passes the compliance check (named, advisory; it
  blocks a certified cut), and `tools/release.sh confirm-register SMNNNN --ruling N` records the
  release manager's confirmation in one commit on main. t/tools/680 to 682.
- SM1454 (20edf21e) **tests: the slow ones are trimmed (R5), 449 s to 123 s over six files, no
  assertion removed.** Timed alone, before and after: `t/lint/218` 114 s to 1.3 s (its closures
  matched a pattern per name over every sub body; the names a body calls are now read once), the
  changelog lints `53` 88 s to 0.2 s, `65` 27 s to 1.0 s and `75` 10 s to 0.2 s (they started one
  git process per ref, per SHA and per tag; each now asks git once for the whole set and looks
  each up, with the same answers, checked against the old method), `t/tools/03` 125 s to 96 s (the
  plain first install that fourteen subtests only start from is made once and restored from a
  tarball to the same path; the one-second sleeps between backups wait for a new backup name
  instead), and `t/tools/154` 85 s to 24 s (a daemon test waits for the service it started and
  now stops waiting when that service has exited, which the OOM that cannot start one does at
  once, so the thirty seconds are not waited out; `OdooDaemonTest::wait_until` takes the
  service's pid). The rest of the slowest in the suite are one CGI process per case
  (t/integration/112 to 117, t/unit/manager/226, 228) and are left. Tests only; no engine change.
- SM1454 (R3) (PENDING) **tools: the full suite can run on an HPS lab VM, with a local fallback**.
  `tools/suite-lab.sh STAGE_DIR JOBS OUTFILE` is a suite runner for the gate's
  `LAZYSITE_SUITE_RUNNER` hook: when `LAZYSITE_SUITE_LAB=1` and a bounded check finds the lab
  available, it runs the suite on a throwaway 8 vCPU / 16 GiB VM, writes prove's output to
  OUTFILE, exits with prove's status and destroys the VM; otherwise it says `suite-lab: lab not
  available (REASON) - running locally` and runs `tools/suite-local.sh`. A lab failure after the
  tests started is a failure, never a fallback.

- Docs: SM1453 (the rollout reads the ACL probe's cache verdict as a verdict, not as "could not
  run") filed as a candidate.

- Docs: SM1449 (a gate stopped part way resumes where it stopped) and SM1452
  (t/integration/315 does not race the clock) filed as candidates.

## 0.17.0 - STABLE: the stable release of the 0.16 line, with an unfinished backup named and a full backup that runs detached (2026-11-15)

- SM1451 (2138b509) **release: the coverage stage runs for certified only; a stable gates like a
  beta.** Ruling 256 (the release manager, 2026-11-15) replaces SM1083's "coverage for stable
  only". The 0.17.0 stable was held for three days by the coverage stage alone: the suite and
  bench passed each time, and every failure was the stage's own (two tests that raced the clock
  under instrumentation, SM1450, and repeated memory kills in the Devel::Cover merge of the
  processor group). In its history the stage has found no engine fault; every coverage filing is
  about the stage itself. A stable that cannot ship its fixes is the larger risk. `release.sh`
  and `gate-main.sh` now run coverage for `--certified` only (or `LAZYSITE_COVER_FORCE=1`); a
  stable receipt says `coverage=not run (channel stable; certified only, ruling 256)` and build
  accepts it. `--final` keeps the release-material lints and the download/ commit.
  `tools/coverage.sh` stays, on demand, as advice. t/tools/104 and 168 follow the rule.
- SM1450 (ee644e44) **tests: two processor tests no longer race the clock under Devel::Cover.**
  The 0.17.0 `--final` gate's coverage stage failed `t/unit/processor/185-a-schedule-page-is-cached-until-its-state-changes.t`
  and `t/unit/processor/131-a-static-says-when-it-changed.t`, both of which passed in the plain
  suite minutes earlier. Under instrumentation a render takes tens of seconds and each test read
  the clock at the wrong moment. 185 bounded a `ttl:` page's max-age by `time` read after the
  render returned, though the engine fixed max-age when it rendered, so the bound was as much
  too tight as the render was slow; it now uses the time read before the request. 131 stamped
  the "fresh" file a minute ahead once at the top of a file that runs for over a minute, so by the
  If-Range request it was more than a second behind the clock and the engine rightly answered
  206; the stamp is now set an hour ahead immediately before that request. Each assertion still
  fails when the engine is wrong (checked by scratch edits to the clamp and to the one-second
  rule). Tests only; no engine change.
- SM1448 (e36cef5f) **docs: the compliance records cover 0.17.0, the stable.** OBLIGATIONS.md
  and TECHNICAL-FILE.md are walked against the 0.17.0 line (`git log 930e7f32a..f02c7cbb0`, 19
  commits: SM1442 to SM1447) and stamped 0.17.0, channel stable (rulings 227, 242). 0.17.0 is cut
  with `--final` as the stable promotion of the 0.16.12 beta with only the fixes of the 0.16.11
  and 0.16.12 field passes; the first stable since 0.16.0, it carries 0.16.1 to 0.16.12, and the
  feature freeze (ruling 228) ends with it. It is not security-critical: no change since
  0.16.12 fixes a known vulnerability. Drafted by the developer agent and confirmed by the release
  manager on 12 Nov 2026 (ruling 251): register entries for SM1444 (a hardening of a default list, no trigger), SM1447 (messages and
  check text, no trigger) and the finished SM1446 (the detached full backup: who, how long, one at
  a time, and the residual that two starts in the same instant can both pass the check; no
  trigger; the residual is accepted as written), the walk's entry, one STRIDE row and a section in
  docs/architecture/security.md. The restore-rehearsal row is closed (ruling 247). The 0.17.0
  stable is not the beginning of general-availability marketing, so the first third-party
  pentest stays due by 31 Dec 2026 (ruling 249); the bench baseline is re-captured after 0.17.0
  (ruling 250). The Declaration of Conformity, which a stable cut
  does not require signed (ADR 0010), is restamped to 0.17.0 and stays unsigned. UPGRADE.md's
  0.17.0 notes are one section whose opening paragraph takes a site on the 0.16.0 stable through
  0.16.1 to 0.16.12 in order.

- SM1446 (2f58e1c1) **fix: a backup that did not finish is never listed as a backup.** A full
  backup of a large instance from the Backups page was killed mid-tar by a deadline in front of
  the manager; the empty name it had claimed was listed as a full backup (size 0, no sha256),
  the page showed nothing, and the audit trail had no row. `backup-list` now lists an empty
  claim, and an archive whose gzip stream stops part way with no sha256 beside it, under
  `unfinished` with its time and how to remove it, never under `backups`; restore and site-package
  apply refuse one by name, `install.pl --restore-full` refuses one before anything is laid, and
  `lazysite check` names each, and a staging directory a killed backup left. A request terminated
  mid-tar (TERM, the pool relay's first signal) stops tar and keeps nothing. The trail records a
  backup's start by file name as well as its outcome, which now names the file and, for a full
  backup, the kind `full` (it read `manual`). The Backups page shows the outcome beside the button
  (the name, the refusal, or that the server stopped waiting), reads the list again whatever
  happened, and shows unfinished backups apart with a Delete. A finished backup records its
  sha256, as it has since SM183. **A full backup now runs detached from its request (ruling
  248):** `backup-create&scope=full` answers at once with the name and `in_progress`, a worker
  takes the backup and writes its start and outcome to the trail, and `backup-list` lists it
  under `in_progress` while its process is alive (for at most six hours), then as a backup or as
  unfinished; the page follows it until then. Restore and delete refuse one in progress, and a second full backup is refused while one is. The
  registry rebuild and the backup share one detach helper (`Lazysite::Util::detach`). A
  field-pass fix (rulings 206, 227, 228, 248).
- SM1447 (0dcc97a7) **a refusal names the user who can actually run the command.** On a Hestia
  host the store files in `lazysite/auth/` belong to the web server's user, not to the
  directory's owner, so the root refusal of `lazysite acl` and the check's advice sent the
  operator to a user who then could not read them. The user named is now the owner of the files
  the command reads and writes (each owner, where they differ), through one helper used by acl,
  handlers, check and users. The address-profile refusal names the file's owner and the user to
  run as. The upgrade's ADDRESS PROFILES line says it could not check the unread directory, names
  its owner and the rerun, and no longer says calls are false.
  The check says ok only about what it read: a walk that could not read part of the tree prints no
  ok (form patterns, protected content, the template cache, ownership, content history, content
  provenance, theme assets, the asset mirror) and its warning names the user who owns what was not
  read; an unreadable acls.json, which hid every page from the public page set, now makes the page
  check say so instead of "0 public page(s)". Every piece of advice spells the command through
  cli_spelling, never a bare `lazysite`.
- Docs: SM1445 filed, for after stable, the owner's other bad-URL blocker requests. An agent
  adding patterns (R1), an agent seeing blocked addresses and a visitor's block state (R2) and a
  built-in pattern edited or switched off for a site that serves it (R4) are features under the
  freeze (ruling 246); `docs/feature-requests/SM1445-*.md` records them for 0.17.x edge. It is a
  candidate, not shipped. No code.
- SM1444 (55fa35c2) **security: the bad-URL blocker counts probes for credential files.** Scanners
  fish for the dot-directories of developer and cloud tools and for app config files no lazysite
  site serves; those requests stayed under the threshold. The built-in patterns now include
  `/.docker/`, `/.claude/`, `/.cursor/`, `/.kube/`, `/.azure/`, `/.vscode/`, `/.idea/`,
  `/.terraform/`, `/.gnupg/`, `appsettings*.json`, `aws-exports.js` and `/wp-json/batch`, in the
  blocker and, but for the batch endpoint (the stats sweep catches that), in the stats noise set
  (the same block in both, checked by t/tools/640).
  `/app.js` and `/app.config.js` stay out: a real site can serve them. A site's `bad_url_extra`
  still adds to the list, and a real file is still spared. A field-pass hardening (ruling 245):
  no new setting, tool or UI.
- SM1443 (28d9e917) **docs: the restore rehearsal is rerun on the shipped 0.16.12 tarball, and
  a full restore is one command that gives a site that serves.** `install.pl --restore-full`
  onto a new docroot and cgi-bin took 743 ms; the content, the auth store, `lazysite.conf`, the
  three cgi-bin entry points and the 0.16.12 install state were present, and `lazysite check
  --group` reported 0 failures (it was 3 on 0.16.11). A backup whose `lazysite/` is a symlink is
  refused before anything is changed. SM602 stands. `docs/RELIABILITY.md` has the new row and the
  0.16.11 row's date is now ISO, so the compliance check reads the newest rehearsal. The release
  manager confirmed the rerun on 12 Nov 2026 (ruling 247) as the 0.17.0 stable cycle's rehearsal,
  and the obligations row closes. Docs only; no shipped code changes.
- SM1442 (78b74915) **tests: t/tools/158 proves a killed cover is not a test failure in a quarter
  of a second, not 270 s.** The 0.16.12 gate failed on 158 alone, killed at the suite's 300 s
  per-test deadline. Before its report step `tools/coverage.sh` digests every input that decides
  coverage (`tools/coverage-inputs.pl`, PPI over the tree); that costs 238 s of CPU on a cold
  cache, and the gate's staged tree has none. 158 now runs the real coverage.sh from a fixture
  root that has no coverage-inputs.pl, so the digest is empty and the stage goes straight to the
  cover step the test is about. Every assertion is kept; the deadline is unchanged. Test-only; no
  shipped code changes.
