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
Plugin Manager + Config | never | includes SM231 notification emission control
Users | never | connect-code regeneration (tier C), and the 0.10.10 add-group picker (tier A4)
Groups | never | grant authority is the one with teeth; the 0.10.10 member picker is tier A4, including that selection must not post
Sessions and keys | never |
Site settings | never | includes the Services holder counts (batch tier B/C)
Cache, Backups, Audit, Stats | never | includes apply-confidence + Undo (tier A)
Agents and connectors | never | the largest gap: no channel walked end to end
```

# What this register does not do

It does not gate a release. `docs/MANUAL-CHECKS.md` tier A does that, and it is
deliberately three checks long. This register is the memory, not the gate -
conflating the two would make every release wait on a document that can never be
finished, which is how a manual pass turns into a formality nobody reads.
