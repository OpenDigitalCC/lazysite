---
id: SM699
title: The manager uses 107 button labels, several saying the same thing
raised: 2026-08-30
raised-by: release manager
area: manager-ui
status: shipped
status-note: "SHIPPED. The vocabulary is in the manager style guide and the labels are reconciled to it. AUDITING THE 107 FOUND THAT MOST WERE ALREADY RIGHT, and that the interesting cases needed judgement rather than a rename: `Apply` on the data import genuinely puts a prepared thing into effect, `Remove` on a descriptor row is exactly a list it can be put back into, and both `Clear`s empty a field. TWO WERE WRONG. On Backups, `Dismiss` closed a notice - now `Close`. On Groups, `Dismiss` was the negative half of a capability decision: capDecide(...,false) WRITES value:off, so a button reading like closing a notice was denying an authority, and an operator could decide without knowing they had. Now `Deny`, paired with `Grant`. ONE FOUND THE GUIDE INCOMPLETE RATHER THAN THE BUTTON WRONG: appearance.md uses `Update` for bringing an INSTALLED layout to the catalogue version, paired with `Install` for a new one - a distinct act the vocabulary had banned without naming its legitimate use. The guide now carries `decide` and `install` alongside commit/abandon/destroy/object. t/lint/97 keeps the reconciliation from coming undone: it polices the words banned OUTRIGHT (a word earns that list only once every occurrence is reconciled, or the test just documents a backlog nobody runs) and checks the guide publishes the reason, because a ban with no published reason reads as arbitrary and the next author reinstates it."
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
