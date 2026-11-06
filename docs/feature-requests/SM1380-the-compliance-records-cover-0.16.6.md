---
id: SM1380
title: "SM1380: the compliance records cover 0.16.6"
subtitle: "The gate's compliance check refuses 0.16.6 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.5. Both are walked against the 0.16.6 stack and stamped 0.16.6; the ten confirmed register entries are walked against the code, and one entry, a boundary and three STRIDE rows are drafted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "the compliance check run alone for 0.16.6 (tmp/n761-compliance-check.sh): two blocking findings, as the 0.16.2 to 0.16.5 gates had (SM1306, SM1337, SM1367, SM1368)"
area: release
status-note: "SHIPPED (PENDING) on n761. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.6; ten confirmed entries walked; SM1375/SM1378 entry, boundary 15 and three STRIDE rows drafted; four operate-side rows; the 403 page's unescaped group names found; filings SM1373-SM1375; UPGRADE.md's 0.16.6 section; install.pl names an unreadable directory (t/tools/331)."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.6 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.5, cutting 0.16.6 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.5, cutting 0.16.6 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The walk reads
each record against what 0.16.6 changes: `git log cbeef1ea0..41c47b006`, 36 commits
(SM1369 X0 and X1, SM1370, SM1371, SM1362, SM1366, SM1372-SM1375, the SM1376 filing,
SM1377-SM1379, and SM1350's umbrella row).

# What it carries

- docs/SECURITY.md, the ten entries written on their branches (SM1369, SM1370, SM1371,
  SM1373, SM1374, SM1366, SM1362, SM1372, SM1379, SM1377), each already confirmed by the
  release manager (rulings 134, 140), walked against the code on the tip, each with a
  "walked" note. SM1369 fires new-external-interface and SM1362
  new-processing-of-restricted-data, each assessed and confirmed contained; the others
  fire none.
- docs/SECURITY.md, a new entry dated 2026-11-06 for SM1375 and SM1378 (the 403 page's
  group list; a layout's engine requirement), no trigger, confirmed by the release
  manager on 2026-11-06 (ruling 142); and one for ruling 141 (the 403 page escapes its
  group names), confirmed.
- docs/SECURITY.md, trust boundary 15 (an extension's code in a core process, SM1369)
  and three STRIDE rows (the hook loader; the primary's content reaching the other
  domains' folders, closed by SM1372; the site as a mailer, SM1362), confirmed by the
  release manager on 2026-11-06 (ruling 142).
- docs/compliance/OBLIGATIONS.md, stamped 0.16.6: the register, threat-model, SBOM
  (strict, exit 0, 462 components, the one more being `lib/Lazysite/Extensions/Hooks.pm`;
  sbom-deps.json unchanged) and technical-file rows; the operate-side register and
  vulnerability-handling rows; four new operate-side rows (an account that relied on the
  primary's reach; who holds `manage_forms` and which roles a site keeps; the owner
  address and the acknowledgement; a site's own scripts' data parameters); the "what a
  person must confirm" section for 0.16.6. Two stale clauses (the 0.16.4 and 0.16.5
  entries awaiting confirmation) now record ruling 127.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.6: the risk assessment current to
  0.16.6, a fifteen-boundary model, 0.16.6 edge and not security-critical, 462 SBOM
  components, 1,644 test files.
- docs/POLICY.md: the technical file is walked to 0.16.6.
- docs/architecture/security.md: the hook loader, a token's grant, agent roles and a
  form's config, the primary's reach, the owner mail and acknowledgement, the narrowed
  answers, the Odoo record's actor and the 403 page's list.
- UPGRADE.md: the 0.16.6 notes as one section, what to do first (the primary's reach,
  the data endpoint's refusal, `manage_forms` and the roles, the Odoo audit actor) and
  then what needs nothing, each point checked against the code.
- docs/feature-requests: the filings SM1373, SM1374 and SM1375 had none; each is written
  from its commit and CHANGELOG entry.

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking and
the support period.

# Found at the walk

- **The 403 page's group names were not escaped.** SM1375's commit says the stash
  escapes the `auth_*` values (SM709); it escapes `auth_user`, `auth_name`,
  `auth_email` and `auth_groups`, not `auth_required_groups`. Measured on the tip
  through the test helper: a read list naming `@<i>bad</i>` renders
  `<li><i>bad</i></li>` on a refused visitor's 403 page. It predates SM1375 and is
  written only by an account that can already put markup in a page, so the walk judges
  it no vulnerability. Ruling 141 fixes it in 0.16.6 (escaped where the stash is built,
  t/integration/356, its own register entry).
- **SM1373 against the vulnerability-handling row.** `extension-read` answered the rest
  of `lazysite.conf` to a cookie session holding `manage_config`. No shipped extension
  keeps a credential in that file (each keeps its own), and the reader is trusted with
  the site's settings, so it is a hardening, not a fix: 0.16.6 stays edge and not
  security-critical.
- No register entry was missing for a security-relevant change other than SM1375 and
  SM1378; SM1376 is a filing and SM1350's commit a row in its umbrella.
- **The upgrade's template-call rename said nothing about a directory it could not
  read.** The 0.16.5 edge deploy printed raw Perl warnings, "Can't
  opendir(<docroot>-lazysite-private/sites): Permission denied" and the same for another
  folder of the private store. `install.pl`'s `rewrite_template_calls` (SM1345) walks
  the docroot, the lazysite directory and the private store with a plain
  `File::Find::find`, so an unreadable directory printed that warning and its old
  `visitor.in_list` / `visitor.in_any` calls were silently left unrenamed (false at
  render) with nothing in the summary. Fixed at the walk: the walk's "Can't opendir",
  "Can't stat" and "Can't cd to" warnings are collected, as `lazysite-check.pl`'s
  `find_noting` does (Q16g), and become one ADDRESS PROFILES warning naming each
  unread directory and its error, saying any old call below it was not renamed, and to
  run the upgrade again as root or the site's owner, then `lazysite check`. The step is
  then not recorded, so the next upgrade tries again. install.pl's other File::Find walk
  (`invalidate_rendered_html`) walks only `lazysite/cache`, which the private store is
  not under, and is left as it is. No register entry: the fix adds a warning and changes
  no access.

# Tests

t/tools/331 builds a site, makes a private-store folder holding an old call mode 000
(skipped as root), and runs the real upgrade: no raw File::Find line on STDERR, the
summary names the folder, a readable file is still renamed, the step is not recorded,
and a second upgrade with the folder readable renames what was left. It fails with the
change reverted.


The compliance check run alone on the branch (tmp/n761-compliance-check.sh): with the
records at 0.16.5 it refuses on the two rows above, and passes with them at 0.16.6. The
SBOM strict check on the same stage exits 0 with 462 components; sbom-deps.json is
unchanged in the range.
