---
id: SM726
title: "SM726: a save behaves the same way everywhere"
subtitle: "Six behaviours for every control that writes a stored value - dirty marking, an unsaved note, a warning on leaving, feedback where the action was taken, an in-flight state, and a resolved modal. Written down in the style guide so they are a contract rather than a habit, and implemented on Domains as the exemplar."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL. THE CONTRACT IS WRITTEN and the exemplar is done: the style guide carries the six behaviours as a normative section, .mg-dirty and .mg-sheet-foot exist on all three sheets, and Domains implements all six. WHAT REMAINS is every other page with a save - Site settings, Users, Groups, Data, Plugin Config, Nav, Appearance - none of which has been brought to the contract. Nothing enforces it yet either: t/lint/96 holds the CLASSES, but no lint checks that a page with a save marks dirty fields or reports in its own modal. That lint is the next step and is what stops this drifting back."
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

# What was asked

Reported by the release manager, 2026-09-02, from the live manager:

> on domains: the modal needs warning when changes made and not saved. standing
> rule for anything that requires a save, maybe the field has outline to note
> all changed, and a note to say changes made not saved. also, on domains, it
> can take a couple of seconds for the action to complete, yet the modal stays
> open, and the underlayer gets the update to say changes saved. so either modal
> closes, or the saved is presented on the modal. record the standard behaviours
> in a document, so that they become standardised.

# What was actually wrong on Domains

Three defects, and the third explains the second.

**Nothing tracked what changed.** `saveDomain` counted fields that EXISTED, not
fields that had been altered - the variable was even called `changed`. So it had
no way to warn on close, and no way to mark a field.

**The answer landed behind the sheet.** It called `showStatus`, which writes to
the PAGE's status line. The sheet covers the page. So a save that worked looked
like nothing had happened, which is exactly what was reported.

**And it was slow for a reason that follows from the first.** The save chains
one round trip PER EDITABLE KEY, sequentially, whether or not the value changed
- so a domain with a dozen fields made a dozen requests to save one edit. That
is the "couple of seconds". Tracking what changed fixes the feedback AND most of
the delay, because unchanged keys are no longer posted.

# The six behaviours

Written into `starter/manager/style-guide.md` as a normative section, beside the
button-label vocabulary that is already there. Summarised:

1. **A changed control marks itself** - `mg-dirty`, an outline. It clears when
   saved, or when the value returns to what it was.
2. **Unsaved changes are stated** - `mg-dirty-note` beside the Save. The outline
   says WHICH, the note says THAT; a note alone on a twelve-field form is barely
   better than silence.
3. **Leaving with unsaved changes warns**, naming what is lost. Every route out
   - close control, backdrop, Esc - goes through the one guard.
4. **Feedback appears where the action was taken** - a `mg-status` inside the
   modal, never only the page's line behind it.
5. **A save in flight says so and cannot be repeated** - the button disables and
   changes its label.
6. **A finished save resolves the modal** - it closes, or it shows the
   confirmation in place and stops being dirty.

## What was reused rather than invented

`mg-dirty-note` already existed and was an ORPHAN - a rule in the stylesheet
used only by the style guide's own component listing. It has a purpose now.
`mg-status` works anywhere, so an in-modal status needed no new class.

Two classes are new: `mg-dirty`, and `mg-sheet-foot` - the sheet's own footer,
which has to sit OUTSIDE `mg-sheet-body` because the body is rewritten on every
open and a status the close handler wipes is a status nobody reads.

**`t/lint/96` caught the second one.** It was defined in the stylesheet and not
documented in the guide, and the lint refused - the direction of that contract
that exists to catch a component nobody wrote down.

# Not done

**Every other page with a save.** Site settings, Users, Groups, Data, Plugin
Config, Nav, Appearance. Domains is the exemplar and the rest are not converted.

**Nothing enforces the behaviours.** `t/lint/96` holds the classes, but no check
says a page with a save marks its dirty fields or reports into its own modal.
Without one this drifts back, the way the two expander idioms did. That lint is
the next step, and it is the part that makes this a contract rather than a habit.
