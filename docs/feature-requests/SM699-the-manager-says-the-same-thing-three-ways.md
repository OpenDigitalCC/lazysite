---
id: SM699
title: The manager uses 107 button labels, several saying the same thing
raised: 2026-08-30
raised-by: release manager
area: manager-ui
status: partial
status-note: "PARTIAL - the vocabulary is DOCUMENTED in the manager style guide; the 107 existing labels are NOT yet reconciled to it. Audited across every manager page: Save (13) / Update (2) / Apply (2) all mean commit; Cancel (8) / Close (8) / Dismiss (2) all mean stop; Delete (9) / Remove (1) / Clear (2) all mean destroy-or-not. An operator who learns one page has to relearn the next. Raised by the release manager while reviewing the system-wide style change, on the grounds that labels are part of the same contract as classes."
---

# What was measured

Every `<button class="mg-btn...">` across the manager pages and the layout:
**107 distinct labels.**

The collisions that matter:

| Meaning | Words in use | Count |
| --- | --- | --- |
| Write what I entered | `Save`, `Update`, `Apply`, `Save descriptor` | 13 / 2 / 2 / 1 |
| Stop, go away | `Cancel`, `Close`, `Dismiss`, `Cancel setup` | 8 / 8 / 2 / 2 |
| Get rid of it | `Delete`, `Remove`, `Clear` | 9 / 1 / 2 |

Plus an unresolved split between the bare verb (`Save`, `Add`) and verb-plus-
object (`Save descriptor`, `Add a row`, `Create content backup`), applied
inconsistently rather than by a rule.

# Why it is worth a filing rather than a tidy-up

Two of these carry real signal that inconsistency destroys:

- **`Cancel` versus `Close`.** An operator reads `Cancel` as "work will be
  lost" and `Close` as "nothing will". Using them interchangeably does not add
  a synonym, it removes a warning.
- **`Delete` versus `Remove`.** `Remove` reasonably means "take out of this
  list, it still exists"; `Delete` means destroyed. A page using `Remove` for a
  destructive action is understating what the button does, which is the
  direction that gets somebody hurt.

`Save` versus `Update` is milder - nobody is harmed - but it is the one that
makes the manager feel like several products.

# What is done

The style guide now carries the vocabulary as part of the same contract as the
classes: one word per action, with the reasoning, and `Apply` explicitly
reserved for putting a prepared thing into effect (a package, a preset) rather
than as a synonym for saving a form.

# What is not done

The 107 existing labels are not reconciled. That is deliberate: it touches every
page, it belongs with the class-collapse work the design drop requires
([[SM698]]), and doing it in the same pass means one review of each page rather
than two.

A lint is possible but wants care - a naive "approved labels only" check would
either be waived into uselessness by 107 grandfathered entries, or would refuse
legitimate specific labels like `What would migrating do?`. The narrower and
more useful rule is that **one page must not use two words for one action**, and
that is what to build when the labels are reconciled.

# Related

[[SM698]] (the design drop's class collapses - the same pass through every page),
[[SM697]] (the style guide as contract; this extends it from classes to words),
SM692 (explain a choice where the choice is - the same concern for the words
around a control rather than on it).

# Not started
