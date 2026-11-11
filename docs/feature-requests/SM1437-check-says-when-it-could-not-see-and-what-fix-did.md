---
id: SM1437
title: "SM1437: the check says when it could not see, and what --fix and repair did"
subtitle: "Four findings from the operator's 0.16.10 check and repair runs (Y5, O-4, O-5, O-6): a page check that said ok about pages it could not read, a shadow check that looked at one domain, and two summaries that did not say what had been done."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the operator's check and repair runs on 0.16.10 (Y5, O-4, O-5, O-6), read by the lazysite developer agent on n814"
area: check
status-note: "SHIPPED (PENDING): the page check names what it could not read and the user to run as, and no longer says ok (O-4); the /docs shadow check covers every domain's content root (Y5); --fix prints 'nothing to change' (O-6); repair says 'nothing to repair' (O-5). t/tools/582 to 585."
---

# What happened

O-4: run as the site user, `lazysite check` printed `[ ok ] 0 public page(s), each with
a title and a description of its own`. Run as root, the same docroot had 17 undescribed
pages and 4 shared titles. The processor's page walk opened each directory with
`opendir ... or next`, so a directory the user could not open was left out in silence,
and an empty set read as a clean one.

Y5: edge2 held its own copies of /docs pages under `sites/edge2/` with the old titles,
and the check printed no "site page(s) shadow a newer version of the engine's /docs
manual" line. It compared the manual with the primary's `docs/` only.

O-6: `check --fix` with nothing to fix printed the same report as `check`, with only the
hint gone. The operator asked whether `--fix` is a real option.

O-5: repair printed "-> repaired. Left for you to decide, not a fault:" while its tally
said "0 repaired".

# Ruling 206

A fault is refused or reported, never passed off as fine. A check that could not read
what it checks says so.

# What changed

- The page walk hands back what it could not read (a directory, an engine docs tree
  behind one, a page it left out). The check names each path and the user, says the
  count covers the rest of the site only, says to run as root or the site's owner, and
  does not print the ok line. It is the only check that starts from the page set; the
  JSON-LD and sitemap-freshness checks read their own sources.
- The shadow check runs for the primary and for each declared content root, and names the
  domain on its line when the site has more than one.
- `check --fix` prints `--fix: nothing to change` when it applied nothing.
- repair says `-> nothing to repair.` when no change was applied, and `-> repaired.` when
  one was; the tally is as it was.
