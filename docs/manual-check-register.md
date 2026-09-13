---
title: "Manual check register"
subtitle: "What has actually been walked, when, and on which version. A pass nobody wrote down has to be repeated."
brand: plain
standard-margins: true
---

# Why a register

The suite records its own result; a manual pass does not. Without somewhere to
write it down, the honest answer to "has the Domains page been reviewed?" is
always "I think so, at some point", and the safe response to that is to do it
again. Two or three repetitions of that and the pass stops happening at all.

So: one row per chunk per round. A round is tied to a **version**, because a
pass against 0.10.6 says nothing about a panel that shipped in 0.10.7.

This register mirrors the security-check register kept for the adversarial
rounds, and for the same reason - the next round needs to know what the last one
covered so it extends rather than repeats.

# How to use it

Walk a chunk of `docs/manager-ui-guide/`, or a tier of the batch pass in
`docs/MANUAL-CHECKS.md`. Add a row saying what you found. **Record a partial
pass as a partial pass** - "steps 1-3, stopped at 4" is a useful record and
"done" is not, if it was not.

Findings go where findings go: a defect becomes a filing, not a note here. This
register says *what was looked at*, not *what was wrong*.

# Rounds

```datatable
columns: Date | Version | Chunk / tier | Result | By
widths: 2.4cm | 1.8cm | X | 3.4cm | 2cm
bold: 3
tone: medium
---
2026-08-11 | 0.10.7-pre | Manager guide: Domains | PASS | operator
2026-08-23 | 0.10.26+ | Manager guide: Data tables (DM-7) | walked 2026-08-24 (operator, all 10 steps pass; findings filed as SM502) - pass written; server half is the site agent's, browser half is the operator's | claude
2026-09-12 | 0.13.15 | Tier A / A1 - hide a section, then publish it (1315S-01) | PASS - draft set in the browser, 404 to a signed-out visitor (not a sign-in prompt), Publish flipped the badge draft->gated and the row was retained | claude-code (site agent)
2026-09-12 | 0.13.15 | Tier A / A2 - remove protection completely (1315S-02) | PASS - the remove confirmation is clearly distinguishable from Publish's and names the extra consequence (drops the read list); rule removed | claude-code (site agent)
2026-09-12 | 0.13.15 | Tier A / A3 - apply a site package, then undo it (1315S-03) | FAIL - preview tracks the target correctly (241 new / 13 overwritten, and byte-identical when switched back) and the apply applies; but a fully confirmed undo left the target unchanged, its content root holding the primary's files. Filed; two defects confirmed and fixed for 0.13.16 | claude-code (site agent)
2026-09-12 | 0.13.15 | Tier A / A4 - name a person the same way in four places (1315S-04) | FAIL on one clause - pickers are real selects, not free text, and do not submit the form; an unknown configured principal IS kept (no silent access loss); but it is never MARKED as unknown - `mgRights.chip` (layout.tt:539) takes no existence argument. Kept: pass. Marked: fail | claude-code (site agent)
2026-09-13 | 0.13.16 | Tier A / A3 - apply a site package, then undo it (1315S-03 re-walk) | PASS - target returns to exactly its pre-apply contents (listing diffed, identical); prerestore snapshot scoped at 5.07 MB against 17.38 MB on 0.13.15; primary untouched | claude-code (site agent)
2026-09-13 | 0.13.15 | Tier B / B4 - a draft section 404s and is absent from the sitemap | PASS - discriminated: unprotected the page IS in /sitemap.xml (3,415 B), drafted it is absent (3,334 B) and 404s signed-out. Note: a GATED section is also absent from the sitemap, which the check does not mention | claude-code (site agent)
2026-09-13 | 0.13.16 | Tier B / B5 - a scoped non-operator manager sees only sections inside their scope | PASS - discriminated with two live sessions on the same two rules: unconfined 7 sections, scoped 1 (the in-scope rule only). Out-of-scope acl-get/list refuse 403 naming the scope, and refuse IDENTICALLY for a path that does not exist, so the boundary is not an existence oracle. Note: the "panel"/"card" B5 names was retired by SM635 - protection now shows as a padlock on the folder row | claude-code (site agent)
2026-09-13 | 0.13.16 | Tier B / B6 - readiness warning when the apply target is a domain that is not pointed here | FAIL - no warning; the apply sheet reports "notpointed-1315b.example.com is resolving and served" in green for a host `domain-check` reports as not resolving (no DNS, no HTTPS, no connection). The apply is still allowed, which is the half that passes. Two surfaces of one engine disagree about the same host | claude-code (site agent)
2026-09-13 | 0.13.16 | Tier B / B7 - "keep this site's theme" is honoured on apply | PASS - discriminated both ways after putting edge2 on a distinct theme: ticked, theme unchanged (`lumen-backup-20260818T211110Z`); unticked, theme became the package's `lumen`. Content arrived in both runs (30 -> 31 entries) | claude-code (site agent)
```

## Committed before the next promotion

Decided 2026-08-19, **amended 2026-08-20**: all four tier-A checks are run
before edge is promoted to **stable**. They gated beta for one day; the
amendment is a judgement about what the channels mean - beta is bedded in by
people who know they are running a beta, while stable reaches sites that did
not choose to be early, and these four stand behind that second promise.

None has ever been recorded at any version - the single row above is a
manager-guide walk, not tier A, and predates the line. The work is unchanged
and still owed; what moved is which promotion waits for it.

They cannot be run from here. Tier A is explicitly "against a deployed EDGE
build, not against a released site", so the sequence is: cut edge, deploy, walk
them, then promote to stable. A row per check goes in the table above, naming
the tester who walked it.

```datatable
columns: Check | What it governs | Why it cannot be automated
widths: 2cm | X | 6.4cm
bold: 1
tone: light
---
A1 | Hide a section, then publish it | The panel exists only after a cut and a deploy
A2 | Remove protection completely | Destroys access rules; the data path is tested, the button wiring is not
A3 | Apply a site package, then Undo | Writes and then reverses a whole site
A4 | Name a person, the same way, in four places | **The sharpest.** The principal picker governs who may read protected content, and a silent failure grants a section to nobody while reporting success. No automated test reaches it
```

# Coverage state

What has been walked at least once against the current line, and what has not.
Nothing here is a promise that it still holds - it is a record that it held once,
on a stated version.

```datatable
columns: Chunk | Last walked | Note
widths: X | 3cm | 6cm
bold: 1
tone: light
---
Domains | 0.10.7-pre | SM259 one-form consolidation confirmed; the 0.10.10 access pickers are NOT covered by that walk (tier A4)
Files | never | Protected sections panel (tier A/B), and the 0.10.10 principal picker on the section sheet (tier A4)
Navigation | never |
Appearance | never | the no-CDN check has no gate in this repo - manual only
Plugin Manager + Config | never | includes SM231 notification emission control, and the SM336 "Record internal search terms" checkbox added in the 0.10.13 line - the one new operator-facing control in that release, and the only setting that changes what is recorded about visitors
Users | never | connect-code regeneration (tier C), and the 0.10.10 add-group picker (tier A4)
Groups | never | grant authority is the one with teeth; the 0.10.10 member picker is tier A4, including that selection must not post; SM496 added the new-capability decision banner (Task 6, NOT WALKED)
Sessions and keys | never |
Site settings | never | includes the Services holder counts (batch tier B/C)
Cache, Backups, Audit, Stats | never | includes apply-confidence + Undo (tier A); SM363 added the SM336 blocks - visits, depth, entry/exit, devices and (where enabled) search terms - and none of them has been LOOKED at, only asserted
Agents and connectors | never | the largest gap: no channel walked end to end
```

# What this register does not do

It does not gate a release. `docs/MANUAL-CHECKS.md` tier A does that, and it is
deliberately three checks long. This register is the memory, not the gate -
conflating the two would make every release wait on a document that can never be
finished, which is how a manual pass turns into a formality nobody reads.
