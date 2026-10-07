---
id: SM939
title: "SM939: a fresh install puts lazysite's own docs on the owner's domain, and part of it cannot be removed"
subtitle: "A new site arrives carrying the demo pages and the whole `/docs/` tree - around seventy pages - publicly served and in the sitemap from the first minute. Worse, the installer creates `docs/features/`, its three children and `docs/integrations/` with permissions the server cannot write, so that content cannot be deleted through any surface the product offers."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-02
raised-by: sites agent, measured on stuartjmackintosh.com after a fresh 0.14.4 install
area: installer
status-note: "PARTIAL in 0.15.2 (tag v0.15.2): SC1 closed by SM933 A2 (371606be), SC3 `--no-starter` in d0ba81b2; SC2 - a non-empty collection DELETE answers 500 - is still open. NOT YET RULED, and it has two independent halves. THE DEFECT: the installer creates `docs/features/` (plus `authoring/`, `configuration/`, `development/`) and `docs/integrations/` with permissions the server cannot write, while `/docs/` itself IS writable - measured as a DELETE table on one grant in one session, 204 at depths 1 and 2 and 507 at depths 3 and 4. The 507 is `lazysite-dav.pl`'s `_write_failure` doing its job and naming the cause; the reporter is explicit that 'this filing is not about the DAV layer, which behaved better than the thing it was reporting on'. THE CONSEQUENCE ON A NAMED LIVE SITE: four pages in the sitemap, three of them lazysite's own docs, and they cannot be taken out of it through the product - removing them needs shell access. THE DIFFERENTIAL IS THE USEFUL PART FOR DIAGNOSIS: whatever makes `/docs/` writable does not make `/docs/features/` writable, so the fault is in how the second level is created rather than in the docroot. THAT IS ALMOST CERTAINLY SM933's MECHANISM and the two should be measured together once rather than twice: SM933's fixture pass must record owner, group and mode for `docs/` as well as `lazysite/`. THE ASK, separately: an install-time flag for a site with NO starter content - an empty docroot plus the system pages the engine genuinely needs - which the reporter rates 'low priority next to item 1'."
---

# BUILT 2026-10-03 (d0ba81b2)

- **SC1 (permissions)**: closed by SM933 A2 - the directories were always 2775
  and now take the docroot's group.
- **SC3 (E2)**: `--no-starter` on `lazysite provision` and `install.pl`. The
  starter set is declared in `classification.json` (`starter_content`, with a
  `keep` list for forgot and logout), marked in the manifest, skipped by the
  installer, and **recorded in the install state** so a later run keeps to it -
  docs/ is bucket code, so without the record the first upgrade would ship it.
  `t/tools/95`; four sabotages (flag ignored; choice not recorded; choice not
  read back; keep list ignored) each fail a named subtest. The read-back case
  passed at first, because the test re-ran with a same-version `upgrade`, which
  does nothing - it now re-lays with `reinstall`.
- **SC2** (a non-empty collection DELETE answers 500) is unchanged and was rated
  low by the reporter next to SC1; with writable directories the per-file
  deletes work.

# RULED 2026-10-03

- **R15: keep the default, add an opt-out flag (SC3/E2).** The permissions half closes with SM933 A2 (R13), which gives these directories the docroot's group.

# Measured, on a live site

stuartjmackintosh.com, 0.14.4, fresh install 2026-10-02. All deletes on the same
grant (`manage_content`, scope `/`) in the same session:

| path | depth | DELETE |
| --- | --- | --- |
| `/contact.md`, `/members.md`, `/lazysite-demo.md`, `/payment-demo.md`, `/payment-members-demo.md`, `/search-index.md`, `/search-results.md` | 1 | **204** |
| all 30-odd files directly in `/docs/` | 2 | **204** |
| `/docs/features/index.md` | 3 | **507** |
| `/docs/integrations/figma.md`, `/docs/integrations/index.md` | 3 | **507** |
| `/docs/features/authoring/*.md`, `features/configuration/*.md`, `features/development/*.md` | 4 | **507** |
| `/docs/` (collection, non-empty) | - | **500** |

**Grade: observed and measured on a live site (A).**

The site is a one-page personal calling card. It went live with a navigation offering
Demo, Install, Develop, Members and Login, and a `/docs/` tree explaining how to
configure lazysite. Its sitemap holds four URLs, three of which are lazysite's own
documentation and cannot be removed.

# Two faults, independent of each other

**SC1 - the installer creates starter subdirectories the server cannot write.**
Whatever makes `/docs/` writable should make `/docs/features/` writable. This is a
bug regardless of the flag below: it affects any site that tries to **reorganise**
the shipped docs rather than delete them.

**SC2 - a non-empty collection DELETE answers 500.** Recursive collection DELETE is
what a WebDAV client expects, and a 500 says nothing. If it is deliberately
unsupported, 405 with a body saying "delete the contents first" lets a client act.
The reporter rates this low next to SC1, because with writable directories a
depth-first manifest works - which is how the first two rows of the table were
cleared.

# The ask

**SC3 - an install-time flag for no starter content**: an empty docroot plus the
system pages the engine genuinely needs (`404.html`, `robots.txt`, `assets/`,
`.well-known/`, `forgot`, `logout`), and nothing else.

For a site that is going to be lazysite's own documentation, shipping the docs is
exactly right. For anything else it is someone else's content on the owner's domain.
Deleting it afterwards is the wrong shape of work - seventy-odd individual deletes to
undo something the install did on purpose, and it does not fully work.

The natural default stays as it is; the flag is opt-in.

# MEASURED 2026-10-02 (plan E1), WITH SM933: SAME CAUSE, AND THE PREMISE NEEDS CORRECTING

It was right to measure these together - SM933's A1 answers this filing's second
fault outright - but the mechanism is **not** the one stated here.

**These directories are NOT created non-writable.** Measured on a fresh provision
into a fixture, `docs`, `docs/features`, `docs/features/authoring` and
`docs/integrations` all come out **mode 2775: group-writable, with setgid**, in
both of SM933's runs. The mode is right and always was.

What is wrong is the **group**. `install.pl` never sets a group on anything it
writes, so every created path takes whatever the kernel gives it - the docroot's
group under a setgid docroot, the installing process's primary group otherwise.
On the live site that group is not the server's, so the server cannot write to a
directory that is, in every other respect, writable.

The two runs separate it cleanly: with the fixture's docroot group set to the
serving group, the same directories come out in the serving group and the health
check passes; with it not set, the same directories come out group-writable by a
group the server is not in.

**So the obvious remedy here would have changed nothing.** Making these
directories writable is not the fix, because they already are. E1 is closed by
whatever closes SM933's PR2, and nothing separate needs building for it - which
is the opposite of the conclusion a fix driven by this filing's wording would
have reached.

The first fault - that the install ships ~70 pages of lazysite's own
documentation onto the owner's domain at all - is untouched by this and remains
exactly as filed. It is a content decision, not a permissions one.

# Why this should be measured with SM933 rather than beside it

[[SM933]] is the same class: provision wrote a tree the engine could not use and
reported success. Here the evidence is sharper because it is **differential** - one
level writable, the next not - which is a strong discriminator between the candidate
mechanisms SM933 lists. One fixture pass recording owner, group and mode for every
created path answers both, and doing it twice would be the waste.

# Related

[[SM933]] (the same class, and the measurement that should cover both),
[[SM284]] (WebDAV write-failure reporting, which is what produced the honest 507),
[[feedback_absence_is_a_finding]].
