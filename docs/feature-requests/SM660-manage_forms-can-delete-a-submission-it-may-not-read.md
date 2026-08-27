---
title: "SM660: `manage_forms` can delete a submission it may not read"
subtitle: "Exposed by SM652, which made manage_forms definition-only for reads and left three destructive verbs behind"
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-27 while shipping SM652, and deliberately NOT fixed there. SM652 narrowed form-submissions and form-list to read_submissions on both channels, so manage_forms is definition-only for READS. Three verbs were left on manage_forms alone: form-submission-delete, form-submission-confirm and form-submissions-delete-bulk. So the capability can now DESTROY a submission it is not allowed to look at, which is incoherent with what its title claims and is a strange shape for personal data. NOT FIXED IN SM652 ON PURPOSE: those are destructive operations, two of them on personal data, and re-gating them is a larger decision than an inconsistency fix should take on its own authority - it changes what an existing manage_forms integration can do, in the direction that breaks things silently rather than loudly. The two channels currently AGREE about these three, so nothing is inconsistent between surfaces; what is inconsistent is one capability's reach against its own description."
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
