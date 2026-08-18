---
title: "SM376: a promoted account is still drawn under its creator, with no control to move it"
subtitle: "account-promote clears managed_by to the empty string. Six places in the Users page read that as 'unset' and fall back to created_by, which is immutable - so the account is re-parented to its creator permanently, while the control that would move it is hidden because the account already is top level."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-08-18 on claude/sm376-promoted-user-still-nested, NOT in 0.10.14 - reported against that build from the manager UI. The parent question now has ONE owner, parentOfSettings(), and top_level is treated as the ANSWER rather than a hint. t/unit/users/29 EXTRACTS the function from the shipped page and runs it in node against the four states the CLI actually writes, because the defect is entirely in what an expression evaluates to and a test that grepped the source would pass on any string containing the right words. Restoring the original expression fails it on the promoted case alone."
---

# What was reported

On 0.10.14, from the manager UI: a human user **still doesn't have the
option to move to top level**.

# Why both halves of that were true at once

```datatable
columns: What the operator saw | Why
widths: 7.0cm | X
bold: 1
tone: medium
---
The account drawn **nested** under its creator | The tree computed the parent as `managed_by \|\| created_by`
**No** "top level (no parent)" control | The control is hidden when `top_level` is true - and it was true
---
```

`account-promote` clears `managed_by` to the **empty string** - a
deliberate "no parent". `created_by` is immutable by design and never
clears. In JavaScript `""` is falsy, so `s.managed_by || s.created_by`
reads a *cleared* parent as an *absent* one and falls through to the
creator.

So the page drew the account under a creator that no longer manages it,
and hid the only control that would move it - correctly by its own
lights, because by the API's reckoning the account already was at top
level. The operator is left looking at a nested account with no way to
un-nest it, which is indistinguishable from a missing feature.

::: widebox
**The control was never missing.** It was hidden by a condition that was
right, about an account the tree was drawing wrongly. Two facts about
the same account disagreed, and the disagreement was invisible because
each half looked correct on its own.
:::

# The shape, again

The expression was written out **six times** in `starter/manager/users.md`
- the tree build, the row render, the sub-count, the owner label, the
parent lookup and the editor sheet - and all six were wrong in the same
way. This is the duplication pattern this project keeps removing: the
fix is not to correct six copies but to give the question one owner.

`parentOfSettings(s)` is now that owner, and it treats `top_level` as the
**answer** to "does this account have a parent" rather than as a hint
about it.

# Verification

- `t/unit/users/29` extracts `parentOfSettings` from the shipped page and
  runs it under node against the four states the CLI writes: a sub-user,
  a promoted account, an operator-created account, and a reassigned one.
- The reassigned case is there deliberately: a fix that collapsed into
  "always use created_by" would pass the promoted case and silently stop
  showing reassignment. Both directions are pinned.
- Restoring the original expression fails the promoted case and nothing
  else.

# Related

[[SM194]] (promotion and scope emancipation as two distinct operator
decisions), [[SM233]] (the row label names the subject and the control
names the effect - the same page, the same concern with legibility).
