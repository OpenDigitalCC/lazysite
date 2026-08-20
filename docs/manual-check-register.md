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
Groups | never | grant authority is the one with teeth; the 0.10.10 member picker is tier A4, including that selection must not post
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
