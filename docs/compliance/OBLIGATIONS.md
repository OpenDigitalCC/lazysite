---
title: "lazysite - dated obligations register"
subtitle: "Every obligation with a date or a version anchor, in one place. Reviewed at every release."
brand: plain
standard-margins: true
---

# What this file is

The single register of every lazysite obligation that has **a date, a version
anchor, or both**. It exists because those obligations were previously spread
across four documents with no combined view, and one of them was written
relatively ("five years from the first stable release") - which decays the
moment a reader has to work out which release that was.

Nothing here is new policy. Each row points at the document that *is* the
policy; this file is the calendar over them.

::: widebox
**This file is reviewed at every release.** The release gate runs
`tools/lazysite-compliance.pl --check`, which fails when a row's date has
entered its lead time with the row still `open`, or when `reviewed_at_version`
is behind the version being cut. Updating this file is therefore part of
cutting a release, not something to remember afterwards.
:::

```yaml
reviewed_at_version: 0.16.6
content_sha:         c8547d3d824105d1
reviewed_on:         2026-11-06
next_review:         at the next release, whichever channel
owner:               release manager
```

# Build-side obligations

Discharged by the development team, in the repository, as part of making a
release. Each has a version anchor: the release that must carry it.

```datatable
columns: Obligation | Due | Version anchor | State | Source
widths: 4.2cm | 2.4cm | 2.4cm | 1.8cm | X
bold: 1
tone: medium
text: 5
---
Declaration of Conformity finalised and signed | at the certified cut (ADR 0010) | certified cut | OPEN | docs/DECLARATION-OF-CONFORMITY.md - draft restamped to 0.16.0 on 20 Oct 2026 and unsigned; the release manager signs it at the certified cut
Significant-change register entry per triggering release | at each release | 0.16.6 | STARTED | docs/SECURITY.md - eleven entries cover 0.16.6, an edge release, dated 6 Nov 2026. Ten were written on their branches and confirmed by the release manager on 6 Nov 2026 (rulings 134, 140), and each was walked at the 0.16.6 compliance walk against the stack's tip 41c47b006, gaining a "walked" note: SM1369 X0, X1 (an extension's own code loaded into a core process, with no caller yet) fires new-external-interface and SM1362 (a form's owner mailed a `notify: full` submission; an opt-in acknowledgement) fires new-processing-of-restricted-data, each that trigger's assessment, confirmed contained; SM1366, SM1370-SM1374, SM1377 and SM1379 fire none. One was written at the walk, a developer-agent draft until the release manager confirms: SM1375 and SM1378 (the 403 page's group list, whose names the stash does not escape, found at the walk; a layout's engine requirement), no trigger fired. Six entries cover 0.16.5, an edge release, confirmed by the release manager on 6 Nov 2026 (ruling 127). Of those, four dated 5 Nov 2026 were written on their branches and walked on 6 Nov 2026: SM1324 (a protected folder's history, opt-in, a second copy of protected content) and SM1325 (the AI read audit, opt-in, account and path and address in a log) each fire new-processing-of-restricted-data, found at the walk, as SM286 and SM1219 fired it, and are that trigger's assessment; SM1332-SM1334 (domain grants add, the primary grantable, a group pin) and SM1343-SM1345 (address lists become address profiles, allow or deny chosen where used; the upgrade converts the store and the template calls) fire none. Two dated 6 Nov 2026 were written at the walk: SM1335, SM1336, SM1339 (a theme's served copies follow its source on every write and are refused to every writer; the mirror refuses a link or a server-run file) and the rest of 0.16.5 that moves a control (SM1321 the bad-URL blocker's exemptions, SM1322 /login's session check, SM1327, SM1328, SM1340, SM1341 the public setup page, SM1347, SM1365); no trigger fired. One entry dated 6 Nov 2026 covers 0.16.4, an edge release that is SM1142 alone (the rename to extensions): the one-time upgrade step `extensions-rename` moves files and links in every site's tree and converts which extensions are on, the login rate limiter among them, and the wire's old spelling is refused and its response keys renamed for an external reader (ruling 95); no trigger fired; a developer-agent draft until the release manager confirms. Two entries cover 0.16.3, an edge release. The entry dated 4 Nov 2026 (SM1308, SM1309, SM1311-SM1313): a confined grant answered from the whole docroot when it named no path, and a member of a protected area could widen its rule on a subfolder; no trigger fired, each recorded as a bypass of a boundary the register names (confinement; the access rule); drafted by the developer agent and accepted by the release manager on 5 Nov 2026 (ruling 65). The entry dated 5 Nov 2026 records the rest of 0.16.3 that moves a control (access, the served tree with the engine's /docs manual, MCP install_theme reaching the theme upload with a token, the settle_odoo_writes capability, the deploy hook's --force-security); no trigger fired; drafted by the developer agent and accepted by the release manager on 5 Nov 2026 (ruling 93). Ruling 94 (5 Nov 2026): no exploitation of SM1308 or SM1309 is known, so no CRA Article 14 notification and no advisory; the 0.16.3 release notes carry it. One entry dated 23 Oct 2026 covers 0.16.2, a security release: a theme archive's symbolic link reached the served asset mirror and could serve the session-signing secret (SM1303, with SM1304's planted-link warning); no trigger fired, recorded as a bypass of boundary 6 as SM1213 and SM1257 were; drafted by the developer agent and accepted by the release manager on 5 Nov 2026 (ruling 65). SM1305 (release.sh --security-critical) and SM1307 (the Hestia updater's --force-security) are release and rollout tooling and touch no boundary. Five entries dated 23 Oct 2026 cover 0.16.1: the warm-forked Odoo endpoint (SM1226, a new local interface), a page's stem rule on move and delete (SM1257, SM1242, SM1258), the Odoo extension's options and OOM 0.42 (SM1223-SM1225, SM1244, SM1247, SM1248, SM1261), the Docker Compose package (SM1233), and the access, rollout and channel changes with no trigger; each drafted by the developer agent and accepted by the release manager on 23 Oct 2026. SM1219 and SM1118, accepted on 21 Oct 2026, are recorded as landed in 0.16.1. Previous 20-21 Oct 2026 for 0.15.3 to 0.16.0, confirmed by the release manager on 21 Oct 2026
Threat model current with the architecture | at each release | 0.16.6 | met | docs/SECURITY.md trust boundary 15 (an extension's code in a core process, SM1369) and three STRIDE rows (the hook loader, SM1369; the primary's content reaching the other domains' folders, closed by SM1372; the site used as a mailer by an acknowledgement, SM1362), added 6 Nov 2026 at the 0.16.6 walk, drafts for the release manager's confirmation; docs/architecture/security.md (the hook loader, agent roles and a form's config, a token following its grant, the primary's reach, the owner mail and acknowledgement, the data endpoint's refusal, the extension settings read, Odoo's refusals and the record's actor), added 6 Nov 2026; for 0.16.5, docs/SECURITY.md two STRIDE rows (a theme's source re-mirrored on every write, SM1335; the bad-URL blocker's loopback exemption behind an uncovered front end, SM1321), added 6 Nov 2026, and trust boundary 11 restated for address profiles (SM1343), added 5 Nov 2026; docs/architecture/security.md (address profiles and domain grants, added 5 Nov 2026; a protected folder's history and the read audit, a theme's served copies, the bad-URL blocker's exemptions, the sign-in page's session check, the ACL 403 page and the public setup page, added 6 Nov 2026); no new trust boundary; for 0.16.4, a STRIDE row for an extension list left under the old spelling (SM1142) and docs/architecture/security.md (extensions on disk and the step that moves a site to them), added 6 Nov 2026; no new trust boundary; for 0.16.3, two STRIDE rows (a confined grant's walks, SM1308; a rule inside another, SM1309), added 4 Nov 2026, and docs/architecture/security.md (a confined grant's walks and a rule inside another; the engine's /docs manual and pages beside a moved engine tree; the zip upload over MCP; a write whose answer never came; the shared sign-in return), added 5 Nov 2026; no new trust boundary; for 0.16.2, a STRIDE row for the theme archive's link (SM1303, SM1304) and docs/architecture/security.md (the zip upload and the served asset mirror), added 23 Oct 2026; for 0.16.1, trust boundary 14 (the warm-fork parent) and two STRIDE rows (the stem rule, the parent), and docs/architecture/security.md (the warm-forked endpoint, Odoo idempotency, sizes and downloads, the stem rule, MCP remove_permissions, bundle adoption, Permissions-Policy, the rate counter, the Docker package), added 23 Oct 2026; boundaries 9-13 20 Oct 2026
SBOM regenerated and shipped | at each release | every release | met | strict gate, tools/manifest-to-sbom.pl --strict - run 6 Nov 2026 on the 0.16.6 tree (the 0.16.6 stack's tip 41c47b006 with the 0.16.6 release material written in, manifest not security-critical): exit 0, 462 components, the one more being the hook loader `lib/Lazysite/Extensions/Hooks.pm` (SM1369), whose `use` lines are core modules (Cwd, JSON::PP, Time::HiRes) already declared; sbom-deps.json is unchanged since 0.16.2. At 0.16.5: 461 components, the two more being `lib/Lazysite/ProtectedHistory.pm` (SM1324) and `lib/Lazysite/Odoo/Name.pm` (SM1328), with the address modules renamed (`Auth::AddressProfiles`, `Manager::AddressProfiles`; SM1343); sbom-deps.json is unchanged since 0.16.2
Annex VII technical file kept current | continuous; complete before CE marking | 2027-12-11 | STARTED | docs/compliance/TECHNICAL-FILE.md - index form, walked to 0.16.6 on 6 Nov 2026
Signed releases (Sigstore/cosign) | before CE marking; cannot be applied retroactively | 2027-12-11 | OPEN | docs/POLICY.md - every unsigned release is permanently unattestable; stays for the certified release (release manager, 20 Oct 2026)
OpenChain 5230 + 18974 written policies | before CE marking | 2027-12-11 | OPEN | docs/POLICY.md
Bench baseline re-captured | at each stable cut | next stable | OPEN | dist/config/bench-baseline.json - captured 2026-09-30; re-capture on a quiet host at the stable cut (stable-gate plan P8)
Restore rehearsal recorded | at least once per stable cycle | next stable | OPEN | docs/RELIABILITY.md - last recorded 2026-08-26, before the last stable cut (0.16.0, 2026-10-22); the rehearsal on a scratch copy of a real site at the candidate version is the operator's (stable-gate plan P6)
```

# Operate-side obligations

Discharged by whoever **runs** a lazysite instance. On this project that is
sometimes the same people and sometimes not, and the lifecycles differ: a build
obligation is met by cutting a release, an operate obligation is met by a
person doing something on a running service, on a calendar that has nothing to
do with the release cadence.

An operator records their own instance's state in their filled-in copy of
`docs/compliance/OPERATIONS-TEMPLATE.md`; the rows below are the obligations
that copy must account for.

```datatable
columns: Obligation | Due | State | Source
widths: 4.6cm | 3cm | 1.8cm | X
bold: 1
tone: medium
text: 4
---
CRA Article 14 reporting path rehearsed before the clock is live | 2026-09-11 | OPEN | toolchain OPERATIONS-GUIDE.md #report-path-rehearsal; named triage owner + deputy, platform access verified, 24h/72h/14d cascade walked as a tabletop
Named security triage owner and deputy | 2026-09-11 | OPEN | as above - the DoC names a function, not an individual
First third-party penetration test | 2026-12-31, or first GA marketing, whichever first | OPEN | docs/adr/0007-pentest-deferral.md - after expiry an absent report is a refusal condition, not a deferral
Significant-change assessment on each fired trigger | continuous | drafted to 0.16.6 | docs/adr/0007-pentest-deferral.md - the register is what keeps the waiver valid; the 20 Oct 2026 entries were confirmed by the release manager on 21 Oct 2026; of the 23 Oct 2026 entries, the five for 0.16.1 were confirmed on 23 Oct 2026 and the SM1303 entry for 0.16.2 on 5 Nov 2026; the 4 Nov 2026 entry for 0.16.3 (SM1308, SM1309) was confirmed on 5 Nov 2026, and the 5 Nov 2026 entry for the rest of 0.16.3 on 5 Nov 2026 (ruling 93); the 6 Nov 2026 entry for 0.16.4 (SM1142) and the six entries for 0.16.5 (5 and 6 Nov 2026) were confirmed on 6 Nov 2026 (ruling 127), two of them (SM1324, SM1325) the assessments of a fired trigger, new-processing-of-restricted-data, confirmed contained (ruling 125); of the eleven 6 Nov 2026 entries for 0.16.6, the ten written on their branches were confirmed on 6 Nov 2026 (rulings 134, 140), two of them the assessments of a fired trigger: SM1369 (new-external-interface, ruling 134) and SM1362 (new-processing-of-restricted-data, ruling 140), both contained; the one written at the 0.16.6 walk (SM1375, SM1378) fires none and awaits the release manager's confirmation
Vulnerability handling in operation (intake, triage, advisory, VEX) | continuous | PARTIAL | SECURITY.md declares CVD intake; the dated remediation register against the ADR 0007 SLAs stays for the certified release (release manager, 20 Oct 2026). 0.16.2 is cut as a security release for SM1303 (ruling 41 as revised, 41b): its manifest declares security_critical (SM1305) and it is pushed with `lazysite upgrade --all --force-security`, or on a Hestia host the updater's `--force-security` (SM1307); the fix is in the register, its dated remediation record with the rest at certified. 0.16.3 carries the fixes for SM1308 and SM1309 as an edge release, not security-critical, so each site takes them by its own update channel; from 0.16.3 a security release is cut on stable (SM1314) and the deploy hook passes `--force-security` itself when the manifest declares it (SM1315). 0.16.4, SM1142 alone, is an edge release, not security-critical, and fixes no vulnerability. 0.16.5 is an edge release, not security-critical, and fixes no vulnerability: its fixes are of availability (SM1321's blocker refusing every visitor behind a front proxy), of a lost update (SM1327) and of what a page says (SM1322, SM1365). 0.16.6 is an edge release, not security-critical, and fixes no vulnerability, judged at the 0.16.6 walk: SM1373 (an extension's settings read answered the rest of `lazysite.conf`) narrows what a cookie session holding `manage_config`, an account trusted with the site's settings, is shown, where no shipped extension keeps a credential in that file; SM1372 closes a reach recorded as residual risk at 0.16.5 (ruling 126); SM1374 and SM1377 narrow what a visitor or a script is told. SM1375's unescaped group names on the 403 page, found at the walk, are written only by accounts that can already put markup in a page, and are left for the release manager to rule
People who sign in told that the visitor log records their account | on running 0.16.1 or later with the visitor log on | OPEN | docs/OPERATOR.md "The visitor log names signed-in accounts" (SM1219) - account names are personal data; the site's privacy notice says so, or the log is turned off or its retention shortened. The engine publishes no notice (SM1010)
A symbolic link planted in the served asset mirror removed, and the session secret rotated | on upgrading to 0.16.2, where `lazysite check` names each link | OPEN | docs/OPERATOR.md "A symbolic link in the asset mirror is left for you" (SM1304) - before 0.16.2 a theme upload could plant one, serving what it points at, `lazysite/auth/.secret` included; the engine warns and never deletes, so the operator removes the link and rotates the secret (the manager's Sessions page, "Log out all users")
An access rule wider than its enclosing rule, written before 0.16.3, reviewed | on upgrading to 0.16.3, where `lazysite check` names each | OPEN | docs/OPERATOR.md "A rule wider than the rule around it is left for you" (SM1313, ruling 61) - before 0.16.3 any account that could write inside a protected area could open a subfolder to people the area's rule does not admit; 0.16.3 refuses that (SM1309) and keeps the rules stored, so the operator keeps or removes each one the check names; the engine changes none
References the upgrade to extensions/ cannot see, updated | on upgrading to 0.16.4 | OPEN | UPGRADE.md, the SM1142 entry (ruling 95) - the upgrade converts the site's own tree, lazysite.conf and stored start pages; the rest is the operator's: a crontab or pipe running the old directory's stats.pl or form-smtp.pl, a link made by hand outside the site's cgi-bin, a bookmark to the old manager pages, a script on the old action spelling or reading the old response keys, and an audit filter on the old action names. `lazysite check` names an old-spelling line in lazysite.conf and an old directory left beside the docroot
Each address rule whose slot differs from its old list's kind, and each old template call, reviewed | on upgrading to 0.16.5, where `lazysite check` names each | OPEN | UPGRADE.md, the SM1343-SM1345 entry (rulings 56-58, 105-108) - the upgrade converts the store and renames the template calls; a rule naming a list in the other slot, possible only by a hand edit, refused every visitor before and now applies in its slot, so it can widen; a call written back under an old name is false. The engine changes no rule, so the operator keeps or corrects each one the check names
A protected folder's history and the AI read audit, where a site turns them on, accounted for | on turning on `history: true` or `audit_reads: on` (0.16.5) | OPEN | docs/SECURITY.md, the SM1324 and SM1325 entries - the history is a second copy of protected content, in the site's backups, kept until the operator purges it (`lazysite acl purge-history`); the read audit records which agent account read which path, when and from where, kept and rotated as the trail is. The site's records of what it holds, and the notice to whoever runs the agents, are the operator's (SM1010 principle, as SM1219's row)
An account that worked on a secondary domain's folder through the primary, granted that domain | on upgrading to 0.16.6 | OPEN | UPGRADE.md, the SM1372 entry (rulings 126, 137) - the primary's content leaves out the other domains' content roots, so a non-operator account (a manager holding `manage_users` outside the operator group, an agent's token, a WebDAV login) that edited `sites/<host>/` with no grant on that domain is refused and no longer sees it listed; the operator names its group in that domain's `allowed_groups`, and on the primary's row too to keep the primary
Who holds `manage_forms`, and which agent roles a site keeps | on upgrading to 0.16.6 | OPEN | UPGRADE.md, the SM1371 entry (ruling 122) - `manage_forms` now reads and writes a form's own `lazysite/forms/<name>.conf` over MCP and the manager's editor, as over WebDAV; four agent roles (`content-agent`, `data-agent`, `forms-reader`, `analytics-agent`) appear with no members, and an operator deletes any it does not want
A form's owner address and acknowledgement, where a site sets them, accounted for | on setting `owner_contact` or a form's `acknowledge_field` (0.16.6) | OPEN | docs/SECURITY.md, the SM1362 entry (ruling 140) - a `notify: full` form's owner mail carries the submission's fields, personal data, to the address `owner_contact` names; an acknowledgement sends the form's fixed words to an address a visitor typed, within the caps. The owner words it so that receiving it unasked is harmless, and the site's records and privacy notice are the operator's (SM1010 principle)
A site's own scripts that send the data endpoint, or `data-rows`, a parameter it does not read, changed | on upgrading to 0.16.6 | OPEN | UPGRADE.md, the SM1377 entry (rulings 131, 139) - such a read is now a 400 (`kind: unknown-parameter`) where it was every row; the operator searches the site's scripts for `lazysite-data.pl?` and token scripts for `data-rows`, and filters on the page binding or after reading. The shipped `lazysite-data.js` and the manager are unaffected
CE marking applied | 2027-12-11 | OPEN | docs/POLICY.md
Support period ends | 2031-07-10 | running | docs/POLICY.md - five years from 0.7.0, cut 2026-07-10. The absolute date is written here so the commitment does not depend on anyone recalling which release was first stable
```

# Walked for 0.16.6: what a person must confirm

Walked on 2026-11-06 by the developer agent for 0.16.6, an edge release: every row above
was read against the CHANGELOG's `## Unreleased` section and `git log
cbeef1ea0..41c47b006` (36 commits: SM1369 X0 and X1, SM1370, SM1371, SM1362, SM1366,
SM1372-SM1375, the SM1376 filing, SM1377-SM1379 and SM1350's umbrella row). The rows below
hold what only a person can close. The 0.16.5 walk's items are carried where they still
stand.

- Ten register entries in `docs/SECURITY.md` cover 0.16.6 as written on their branches,
  each confirmed by the release manager on 2026-11-06 (rulings 134, 140) and walked here
  against the code on the tip, each gaining a "walked" note. Two are the assessments of a
  fired trigger, confirmed contained: SM1369 X0, X1 (new-external-interface, ruling 134)
  and SM1362 (new-processing-of-restricted-data, ruling 140). The waiver holds.
- One entry was written at this walk and is a draft for the release manager's
  confirmation: SM1375 and SM1378 (dated 2026-11-06), no trigger fired.
- Found at this walk: the 403 page's group names (`auth_required_groups`) are not escaped
  where the stash escapes the other auth values (SM709), as SM1375's commit says they are;
  a read list's `@name` with markup renders as markup on the 403 page. It predates SM1375
  and is written only by accounts that can already put markup in a page, so the walk
  judges it no vulnerability; the fix (escape it in `render.pm`, with a test) is for the
  release manager to rule and file. This walk changes no code.
- Trust boundary 15 (an extension's code in a core process, SM1369) and three STRIDE rows
  (the hook loader; the primary's reach, closed by SM1372; the site as a mailer, SM1362),
  added at this walk: drafts for the release manager's confirmation.
- 0.16.6 is cut edge and not security-critical: no change in the range fixes a
  vulnerability (the vulnerability-handling row). SM1373 was judged against that row:
  `extension-read` answered the rest of `lazysite.conf` to a cookie session holding
  `manage_config`, an account trusted with the site's settings, and no shipped extension
  keeps a credential in that file, so it is recorded as a hardening, not a fix.
- The operate-side rows for SM1372 (grant the domain an account relied on), SM1371 (who
  holds `manage_forms`; which roles a site keeps), SM1362 (the owner address and the
  acknowledgement) and SM1377 (a site's own scripts' parameters), added at this walk.
- The threat model rows in `docs/SECURITY.md` and `docs/architecture/security.md`: read
  from the filings and the code they name, not from a fresh review of the code.
- The operate-side rows for SM1343-SM1345 and for SM1324 and SM1325, added at the 0.16.5
  walk, SM1142 (references the upgrade cannot see), added at the 0.16.4 walk, SM1313,
  added at the 0.16.3 walk, SM1304, added at the 0.16.2 walk, and SM1219, added at the
  0.16.1 walk.
- The Declaration of Conformity (restamped, unsigned).
- Operate-side rows the developer agent cannot observe: the CRA Article 14 reporting
  path rehearsal and the named triage owner and deputy (both dated 2026-09-11, still
  OPEN), the first third-party penetration test (2026-12-31, or first GA marketing),
  OpenChain 5230 and 18974 (pending in `docs/POLICY.md`), CE marking, and the support
  period (`docs/POLICY.md`, ending 2031-07-10).
- The restore rehearsal (operator, root) and the SM296 re-apply sweep on each production
  site (operator): stable-gate plan P6 and P7.
- Left open for the certified release by ruling: signed releases and the vulnerability
  register.

# How a row is discharged

open
: the obligation has not been met and its date has not passed.

met
: met for the version named in the version anchor. A row that is `met` for
  0.10.8 is **not** met for 0.10.9 - obligations with a per-release cadence
  return to `open` when a new release is cut. That is what the release gate
  checks.

started
: partially discharged, with the artefact existing and incomplete. Used where
  completing early is cheaper than completing late - the technical file is the
  case in point.

running
: a continuing commitment with an end date rather than a due date.

# Why this file is anchored on versions as well as dates

A compliance claim is always a claim about **a version**. "The threat model is
current" is meaningless without saying current as of what; "the SBOM matches
the code" is a statement about one tarball. The eight-dimension review that
prompted this file made the same point about itself - a verdict belongs to the
tree it was measured on.

So every build-side row carries the release that must satisfy it, and
`reviewed_at_version` at the head of this file records the last release at
which the whole register was walked. If that value is behind the version being
cut, the register has not been reviewed for this release and the gate fails.

# References

- `docs/POLICY.md` - the regulatory posture and the CRA Article 13 table.
- `docs/DECLARATION-OF-CONFORMITY.md` - the declaration these obligations
  support.
- `docs/adr/0007-pentest-deferral.md` - the waiver, its expiry and its triggers.
- `docs/compliance/TECHNICAL-FILE.md` - the Annex VII index.
- `docs/compliance/OPERATIONS-TEMPLATE.md` - what an operator fills in.
- `/srv/projects/toolchain-development/OPERATIONS-GUIDE.md` - the operate-half
  items this register's operate section is drawn from.
