---
id: SM816
title: "SM816: the expander trigger had no name, so Delete could not be found"
subtitle: "An operator could not delete a connector and reported there was no interface for it. There is: Save and Delete are in the row's expander, and the expander's only trigger was an empty anchor with no text, no aria-label and no title - rendering as a `+` beside a New connector button. The capability was never the obstacle. The style guide's own exemplar taught the omission, which is why this is a lint and not a one-line fix."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-09
raised-by: sites agent
area: manager-ui
status-note: "PARTIAL. BUILT 2026-09-09: the trigger is NAMED on all four pages using the idiom, the name changes with the state, and the style guide two exemplars are fixed and now state the rule - connectors.md was written from the guide and inherited the guide omission. t/lint/123 covers every .mg-chev trigger, the guide included. BUILT 2026-09-10: the GLYPH is a rotating chevron rather than a plus, in all three styles - a bare plus beside a New connector button reads as add another, which is how an operator came to report that a connector could not be deleted. t/lint/124 guards the glyph and the row template together, because both are shared across three stylesheets a reader edits one at a time. WHAT REMAINS: whether a row surfaces its own actions rather than putting them one level down. NOT built on connectors alone, deliberately - .mg-row is shared by four pages and the guide, and a one-page fix to a shared-idiom complaint is the defect this filing is about. It is also a real trade: Delete on every row is destructive one click from a list. The ambiguity that motivated it is gone either way."
---

# The finding

The operator created a connector and could not remove it. The sites agent
deleted it over the control API in one call, which establishes that the
capability was never the obstacle.

Every connector rendered as a row whose only interactive control, besides a
status tag, was this:

    <a href="#" class="mg-chev" onclick="return toggleRow(this,'uicheck')"
       aria-expanded="false"></a>

Measured by the reporter: `textContent` empty, `aria-label` null, `title` null,
`aria-expanded` correctly present. **`aria-expanded` on a control that cannot be
named says a thing is open or closed without ever saying what.** The whole page
offered two named buttons, New connector and Refresh; nothing said delete.

`Save` and `Delete` were both present inside the expander, and calling
`toggleRow` directly opened it and revealed them. Nothing was broken. There was
simply nothing to tell anybody the control was there.

# Why the guide is in scope

`.mg-chev` is an empty element by design - the glyph is the stylesheet's
(`.mg-chev::before { content: '+' }`, becoming U+2212 open), so the element has
no text of its own and is unnamed unless the page names it.

Checked across the four pages that use it:

| Page | Trigger name before this |
| --- | --- |
| `data.md` | `title="More for this table"` |
| `files.md` | `title="Folder actions"`, `title="File settings & permissions"` |
| `connectors.md` | **none** |
| `style-guide.md` | **none, in both exemplars** |

So the two older pages had it right and the newest one did not - and the file it
was written from showed the unnamed form twice. **A defect in an exemplar is a
defect in everything copied from it.** That is the whole reason this carries a
lint: fixing one page leaves the source of the mistake in place.

# What was built

- **`connectors.md`**: the trigger carries `aria-label` and `title`, and
  `nameChev` changes them with the state - "Show details for X" / "Hide details
  for X". It carries `data-conn` so the reset loop can rename every closed
  trigger without re-deriving the id.
- **`style-guide.md`**: both exemplars named, and the rule written beside the
  idiom it governs rather than left to be inferred.
- **`data.md`, `files.md`**: `aria-label` added alongside the existing `title`.
  A title alone is an accessible name but a weak one - hover-only for a sighted
  user, and not every reader announces it.
- **`t/lint/123`**: every `.mg-chev` trigger in `starter/manager` carries a name.
  It matches trigger elements rather than every mention of the class, because
  the pages also name it in `querySelectorAll` and `classList` calls, which are
  not elements and have nothing to announce.

# The glyph is a decision, not a defect

The reporter also observes that at the rendered size the `+` reads as *add
another one*, sitting next to a New connector button that does exactly that, and
proposes a rotating chevron instead.

**Not built, because it is a design change across three stylesheets** -
`manager-modern`, `manager-classic` and `manager-accessible` all define
`.mg-chev::before` - and four pages, and `+`/`−` is a real disclosure convention
rather than a mistake. The ambiguity the reporter found is contextual: it is a
`+` *beside a New button*, which is a connectors-page problem more than a glyph
problem. Their third suggestion, surfacing a row's actions on the row itself, is
the same decision from the other end and would remove the ambiguity without
touching the glyph. Recorded in `docs/decision-register.md`.

# Credit, and what the reporter corrected

The confirmation behind Delete was singled out as better than most: it names
what goes with the connector rather than asking "are you sure". So 139E-02 step
4 passes on wording; it could not be reached, which is the finding.

The reporter also corrected their own 139E filing, which had recorded these
steps as "not driven" and attributed it to their screenshot rig. Their words are
worth keeping: **when a rig limitation and a missing affordance would look the
same, check which it is before writing off the step. A control the test harness
cannot reach is often a control a person cannot find either.**

# Provenance

`inbox/2026-09-09-connector-row-expander-has-no-name.md`. The four-page survey
and the stylesheet glyph were read here before the fix; the operator's report
and the DOM measurements are the reporter's.

# THE GLYPH, BUILT 2026-09-10 - and half of the recommendation deliberately not built

`.mg-chev` renders `\203A` and the open state rotates it 90 degrees, in all three
styles. That is what the field asked for - "make it look like a disclosure rather
than an add" - and it is what the class has always been called while rendering a
plus.

**Rotation rather than a second glyph**: one shape that turns is the disclosure
convention, and it cannot fall out of step with itself the way `+` and `\2212`
can. No transition, because a rotation that animates raises a motion question
this does not need to raise.

**The `+` on `summary.mg-acc-line` is left alone.** That one sits beside a text
label, so it is not ambiguous - the defect was a BARE plus with no name and no
label, which is why naming it (above) and reshaping it are two halves of one
problem rather than alternatives.

`t/lint/124` now guards it alongside the row template, for the same reason: three
stylesheets that a reader edits one at a time, where a glyph drifting in one
style is wrong only for whoever selected it. Verified by reverting one sheet to
`+` and watching two assertions fail.

## Not built: surfacing a row's actions on the row

This was the recommendation in the register, and it is the half I have not done,
because doing it on the connectors page alone would recreate the exact defect
this filing is about.

`.mg-row` is a **shared** idiom used by four pages and demonstrated by the style
guide. Putting Delete on the connector row means either changing the shared idiom -
a design pass across four pages, three stylesheets and the guide - or giving one
page its own arrangement, which is how [[SM806]] came to borrow the permissions
editor's components as generic layout and how this page came to hand-roll its
expander. **A one-page fix to a shared-idiom complaint is the thing that keeps
going wrong here.**

It is also a question with a real trade in it that the glyph change does not
have: Delete on every row is a destructive action one click from a list, and the
confirmation - which the field singled out as better than most - is the only thing
between a misclick and a deleted connector with its credential.

So it stays open, and it is now a narrower question than when it was filed: the
ambiguity that motivated it is gone, because the glyph no longer reads as "add"
and the trigger says what it opens. What remains is whether a list's management
belongs one level down, which is a design decision about every listing rather
than about connectors.

WHAT REMAINS: that decision.

# THE REMAINING QUESTION, set out properly - detail requested 2026-09-10

"Surface a row's actions on the row" was too compressed to decide on. Here is
what it actually means.

## What a connector row is today

    <div class="mg-row">
      <span class="mg-row-name">uicheck <span class="mg-row-meta">UI check</span></span>
      <span class="mg-row-meta">POST https://... · signed in · no rate cap</span>
      <span class="mg-row-actions">
        <span class="mg-tag mg-tag-off">no credential</span>
        <a class="mg-chev" ...>            <- the disclosure, now a chevron
      </span>
    </div>
    <div class="mg-expand" hidden>          <- Save, Delete, and the whole editor
    </div>

So the row shows **what it is** and **what state it is in**, and everything you
can DO to it - Save, Delete, and every configuration field - is inside the
expander. The only way in is the chevron.

## What "surface the actions" would change

The row would carry one or more real controls. Concretely, one of:

- **Delete on the row**, beside the state tag. The editor stays in the expander.
- **A named button** - "Configure" or "Manage" - replacing or joining the
  chevron, so the way in is a word rather than a shape.
- **Both.**

## The three sub-questions, which is why this is not one decision

**1. Which actions belong on a row?** Delete is the one the field could not find,
and it is also the destructive one. Putting it on the row means a destructive
action is one click from a list, where today it takes a deliberate open-then-read
first. The confirmation - which the field singled out as better than most,
because it names what goes with the connector - is then the only thing between a
misclick and a deleted connector with its credential. **A named "Configure"
button carries none of that risk and fixes most of the discoverability
complaint.**

**2. Which lists?** `.mg-row` is used by `connectors.md`, `backups.md`, `data.md`
and `files.md`, and demonstrated by the style guide. Their rows do not have the
same actions: a backup is restored or downloaded, a table is published or
migrated, a file has permissions. **A shared answer means designing for the
union**; a per-page answer means four arrangements of the same idiom, which is
how [[SM806]] came to borrow the permissions editor's components as generic
layout and how this page came to hand-roll its expander. **A one-page fix to a
shared-idiom complaint is the defect this filing is about**, so the honest
options are "change the idiom for everyone" or "leave it".

**3. What happens to the disclosure?** If the row carries its actions, the
expander still holds the editor - so the chevron stays and now competes with a
button beside it. If the chevron becomes a named button, the row has a word
instead of a shape and nothing else changes. These are different outcomes and the
second is much smaller.

## What I would do, if it helps

**The named button, for every list, and no destructive action on the row.** It
answers the reported complaint - a person could not find their way in - without
moving Delete closer to a misclick, and it is one change to the shared idiom
rather than four arrangements. The glyph fix already landed does part of this
work; a word does the rest.

**What it costs:** a row gains a control, so narrow-window layout wants checking
across four pages, and `t/lint/97` ("a button label says what the button does")
governs the wording.

Still open, and now three answerable questions rather than one compressed one.
