---
title: "lazysite - gate register"
subtitle: "What the full gate has actually returned, when, and on which commit. A pass nobody wrote down has to be repeated."
brand: plain
standard-margins: true
---

# Why a register

The same argument `docs/manual-check-register.md` makes for human
passes, made for machine ones.

Before this file existed, the only evidence of the last green full gate
was `tmp/gate-result.txt` - **gitignored**, so a promotion decision
rested on a scratch file any cleanup destroys. It was found by a
promotion review that then had to re-establish the answer from nothing,
which is the cost this file exists to stop paying.

::: widebox
**A result recorded here is a result somebody can disagree with.** It
names the commit and the tier, so a later reader can re-run exactly what
was run rather than trusting a remembered "it was green".
:::

# How to use it

- One row per full-gate run that a decision rested on. Not every local
  run: the ones that gated a landing, a cut or a promotion.
- Record the **commit**, not the branch - a branch moves.
- Record failures too. A run that failed and was fixed is more useful
  than a gap, because it says what the tree was like.
- `tier-release` is the ~80 minute one (suite + bench + coverage);
  `tier-review` is the ~2 minute full suite at `-j4`. Say which.

# Runs

```datatable
columns: Date | Commit | Tier | Result | Note
widths: 2.2cm | 2.2cm | 2.4cm | 2.6cm | X
bold: 1
tone: medium
---
2026-08-15 | (unrecorded) | tier-release | PASS, 380 files | Recovered from `tmp/gate-result.txt` before it was lost. The commit was not recorded, which is exactly the gap this register closes.
2026-08-19 | 187b689 | full suite -j4 | FAIL, 438 files | perlcritic: unreachable code and two unchecked opens, both introduced by the SM381 work in that commit. Fixed in the commit that follows.
2026-08-19 | 6f62c4f | full suite -j4 | **PASS, 438 files, 8050 tests** | The pre-cut run for items 1-8 of the pre-beta review: CSP rollout mode, the refusal paths, the snapshot fix, and this register.
---
```

# What this register does not do

It does not assert the gate is sufficient. It records what was run and
what came back. Whether that was the right thing to run is the
promotion review's question, and `docs/PATH-TO-STABLE.md` is where the
sequence lives.
