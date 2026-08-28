---
title: "SM660: `manage_forms` can delete a submission it may not read"
subtitle: "Exposed by SM652, which made manage_forms definition-only for reads and left three destructive verbs behind"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING), option 1: BOTH capabilities. The three destructive verbs now require manage_forms AND read_submissions - you may not destroy what you may not see. %COOKIE_CAP gained `a+b` (all named) beside the existing `a|b` (any named); the refusal names both. NO CONTROL STARTS REFUSING: reaching these buttons means opening the submissions viewer, which needs form-submissions, which SM652 already gated on read_submissions - so anyone who can see a row holds it. What this closes is the direct call that never read anything. Token clients were already refused all three outright (SM214 keeps them interactive), so this is a cookie-side change only. WHAT IS NOT PROVED: the live refusal. An integration test was written against a real cookie session and DELETED after sabotage showed it vacuous - breaking the evaluator left it passing, because the fixture never reached the gate. The declaration is asserted instead in t/unit/manager/136 on the separator specifically (a `|` there would mean the opposite and look almost identical), and that assertion IS sabotage-verified. The behavioural gap is real and is recorded in SM669 rather than papered over."
---

# The shape after SM652

| Action | Capability | |
|---|---|---|
| `form-submissions` (read) | `read_submissions` | narrowed by SM652 |
| `form-list` (names + counts) | `read_submissions` | narrowed by SM652 |
| `form-submission-delete` | `manage_forms` | unchanged |
| `form-submission-confirm` | `manage_forms` | unchanged |
| `form-submissions-delete-bulk` | *manager UI only* | unchanged |

A grant holding `manage_forms` and not `read_submissions` can delete a
submission row and clear a quarantine flag, and cannot read either.

# Why it was left

Two of the three destroy personal data. Re-gating them changes what an
existing integration can do, and the failure mode of getting it wrong is an
automation that stops working in a way nobody notices until a queue backs up.
SM652 was an inconsistency fix between two channels; this is a question about
what one capability should mean, and it deserves its own decision.

# The options, none free

- **Require `read_submissions` too.** Coherent - you may not destroy what you
  may not see. Breaks any integration that deletes handled rows under
  `manage_forms`, which is the documented pattern for a form-processing agent.
- **Leave it, and say so.** `manage_forms` carries submission *lifecycle*
  without submission *content*, which is arguably a real least-privilege shape:
  an agent that files and clears submissions never reads them.
- **A third capability** for submission lifecycle, separate from both. Most
  precise, most to explain.

The second is more defensible than it first looks, and if it is chosen the
capability's description must say it plainly - which is the SM427 rule, and the
reason this is worth deciding rather than leaving as an accident of two
filings.
