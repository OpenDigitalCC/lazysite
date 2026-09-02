---
id: SM728
title: "SM728: a control declares its impact, so rules about it can be checked"
subtitle: "The manager had no way to enumerate what an action DOES, so every rule about meaning - a destructive action must confirm, red destroys - was unenforceable however well written down. data-impact is that subject, declared where the control is written and derived into the appearance so the two cannot disagree."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL BY DESIGN. THE MECHANISM IS BUILT AND ENFORCED: six impacts, styled from the attribute in all three sheets, documented in the style guide, and t/lint/109 holds four rules that could not previously be asked - the vocabulary is closed, a declared impact does not wear another's class, a destroying control reaches a confirmation, and an editing control marks the form dirty. All four sabotage-verified. sessions.md is converted as the exemplar (4 of 4). WHAT REMAINS: 199 controls across 17 pages, held at a measured per-page ceiling that may fall and never rise - the t/lint/95 and t/lint/108 treatment, chosen because converting 234 controls in one change is the wide untestable UI edit that produced ninety-five review items last time. Conversion is deliberately NOT scheduled here; the release manager asked for the mechanism and the documentation first, then a decision about where to apply it."
---


# Decided: the conversion goes on the next EDGE cut

**Release manager, 2026-09-02.** The mechanism and its documentation land
whenever they land; **the page conversions ride an edge cut, not a beta one.**

The reasoning, recorded so it is not relitigated: the last change that touched
every manager page - the 0.11.8 design pass - produced ninety-five review items
in the round that followed, and three of its fixes changed nothing at all,
silently. Our own gate is weakest on exactly this class: 75% of those ninety-five
items had no test, `t/lint/96` holds classes rather than behaviours, and coverage
counts statements. A beta is about half the fleet.

So: **build on a branch, cut edge, have the site agent walk it, then promote.**
That is the ladder working as designed rather than a concession.

**The conversion is done against a check, not against a memory.** The ratchet
exists first, so each page converted is verified as it lands rather than
reviewed by eye afterwards. Converting first and enforcing later is how the two
expander idioms happened.

# The problem this solves

`docs/architecture/manager-behaviour-rules.md` inventoried the manager's rules
and found the same gap under most of the unenforceable ones: **there was no
subject.** "A destructive action must also be confirmed" cannot be checked while
"a destructive action" is not something the code can enumerate. The rule was
written down, agreed, and unheld.

# What was built

**`data-impact`, declared where the control is written**, with a closed
vocabulary of six:

| Impact | The act |
| --- | --- |
| `commit` | writes what the operator has entered |
| `change` | puts a prepared thing into effect, or rewrites stored state |
| `edit` | changes what WILL be saved, writing nothing |
| `destroy` | destroys, and must reach a confirmation |
| `retrieve` | takes something out of the page - clipboard, file |
| `inert` | changes nothing at all |

**The appearance is derived from the declaration.** The stylesheets select on
`[data-impact]`, so a control is red BECAUSE it is declared destroying, not
because someone also remembered the class. The modifier classes remain as
aliases while pages convert, and the lint fails if a control declares one impact
and wears another's.

That is the answer to the question that prompted this - *can the subject be
declared in the code at creation, so it is verifiable?* It is verifiable three
ways: statically, because the attribute is in the source; in the browser,
because it is in the DOM and the layout check can compare declared impact
against computed colour; and by construction, because the declaration is what
does the styling.

# The four rules it makes askable

`t/lint/109`, all sabotage-verified:

1. Every declared impact is in the vocabulary.
2. A declared impact does not wear another impact's class.
3. **A destroying control reaches a confirmation.** The style guide has said
   "the colour is a warning, not the guard" since SM-DS1 and nothing could
   check it.
4. **An editing control marks the form dirty**, which is where this meets
   SM726 - a control that changes what will be saved without saying so leaves
   the dirty note it should have triggered unshown.

# Two things the exercise turned up

**A mislabelled control.** `deleteTarget` on Plugin Config wore the destroying
colour for an act that destroys nothing: it splices a row out of an unsaved list
and marks the form dirty. Relabelled `edit`. It was the first control examined
against the vocabulary.

**And it did not fit.** The vocabulary started at five, and that control fitted
none of them - it is neither inert nor a rewrite of stored state. Rather than
force it, the vocabulary grew a sixth value. **A control that fits no value is
still the signal the guide says it is; sometimes it is the vocabulary that is
wrong**, and a scheme with no way to discover that would have buried the finding
instead of producing it.

# Deliberately not done

**199 controls across 17 pages remain undeclared**, held at a measured ceiling
per page that may fall and never rise. Converting them all in one change is the
wide, untestable UI edit that produced ninety-five review items last time, and
the ratchet is the treatment `t/lint/95` and `t/lint/108` already use - both of
which held, where the two expander idioms drifted because nothing counted them.

Which pages to convert, and in what order, is the next decision and is not taken
here.
