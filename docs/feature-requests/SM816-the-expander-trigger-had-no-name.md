---
id: SM816
title: "SM816: the expander trigger had no name, so Delete could not be found"
subtitle: "An operator could not delete a connector and reported there was no interface for it. There is: Save and Delete are in the row's expander, and the expander's only trigger was an empty anchor with no text, no aria-label and no title - rendering as a `+` beside a New connector button. The capability was never the obstacle. The style guide's own exemplar taught the omission, which is why this is a lint and not a one-line fix."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-09
raised-by: sites agent
area: manager-ui
status-note: "BUILT 2026-09-09 on claude/sm816-the-expander-has-no-name. The trigger is named on all four pages that use it, the name changes with the state, and the style guide's two exemplars are fixed and now state the rule - because connectors.md was written from the guide and inherited the guide's omission. t/lint/123 covers every .mg-chev trigger in starter/manager, the guide included; it was checked by removing the name again and watching it name connectors.md:162. NOT CHANGED: the glyph, which is a decision - see below."
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
