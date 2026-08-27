---
title: "SM399: the operator can see the journeys"
subtitle: "SM393 recorded the ordered trails and SM394 gave an agent a way to read them. The operator - the person the manager exists for - still could not see them at all. This is the third surface, and it shows only what trails uniquely answer."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19. A Visitor journeys panel on the manager Stats page, fed by a new parameterised plugin action. The day is a declared CHOICE built from the trail files that EXIST, which is what action_plugin_action's security property requires - nothing request-controlled reaches the command line - and which turns out to be the right shape anyway: only a day that is really there can be asked for, and an expired day stops being offered the moment it is deleted. The panel deliberately does NOT re-render entry pages, exit pages or depth, because SM363 already renders those from the aggregates over every visit and a second, differently-scoped copy would disagree on a busy site. Route counts cover the WHOLE day even when the visit list is capped, and the page says so. No inline event handlers are added, so the panel does not grow the CSP debt the manager conversion has to pay down."
---

# The gap

Three surfaces hold this data and the human one was last:

- the files on disk, which need host access
- `analyse_visitors`, which needs a partner agent holding `analytics`
- the manager Stats page, which is what an operator actually opens

An operator with a site full of visitors could not see a single journey.

# What it shows, and what it deliberately does not

The Stats page already answers **where visits started**, **where they ended**
and **how deep they went** - [[SM363]] renders all three from the aggregates,
computed over every visit there has ever been.

::: widebox
Trails are capped at 2,000 visits a day and expire after 30. Rendering those
same three figures from trails would put a **second set of the same numbers on
the same page**, scoped differently - and on any busy site they would disagree,
with nothing to tell an operator which was wrong.
:::

So the panel shows the one thing no aggregate can produce: the **order**. A
transition count says a hundred people went from `/pricing` to `/contact`. Only
the sequence says whether they arrived at `/pricing` first or reached it after
reading three other pages, and those are different stories about the same edge.

Two blocks:

Routes taken
: the ordered sequence, counted - three visits that took the same route are one
  row with a count of three

Individual visits
: each path with the gap after every step, and the class it was seen as

# Four decisions worth recording

The day is a CHOICE, not a parameter
: `action_plugin_action` accepts nothing request-controlled onto the command
  line except a `choice` it can match against the descriptor's own list. That
  looked like a constraint to work around and is actually the right design: the
  list is built from the files that exist, so the page can only ask for a day
  that is really there, and a day whose trails have expired stops being offered
  the moment the file goes.

The route counts cover the whole day; the visit list does not
: `_read_trails` caps what it returns. Counting routes from a capped 200 of a
  2,000-visit day would produce a headline that looks like the day and is not
  one. The counts are computed over every trail in the file, the capped list
  travels beside them, and **the page says which is which** - a reader must
  never have to work that out.

It does not re-scan
: the panel reads a file that is already on disk. Re-reading the whole access
  log to open a panel would make it as expensive as a full ingest.

No inline handlers
: the rest of this page uses `onclick` attributes, and those attributes are the
  **entire** thing that breaks the manager under an enforcing CSP - a nonce does
  not apply to event-handler attributes at all. New UI binds with
  `addEventListener` from a script block that already passes, so this panel adds
  nothing to the ~250 sites the conversion still has to pay down.

# A defect this found in its own test

The first version of the CSS-class check scanned only the classes the script
emits. The day picker lives in the card markup, so a deliberately broken class
on it passed. It now scans both - found by sabotaging the test rather than by
reading it, which is the only way that class of hole shows up.

# Verification

`t/unit/plugins/27-the-stats-page-shows-the-journeys.t`, 36 assertions, against
six sabotages each confirmed to apply and still compile: emptying the choice
list; computing the route counts from the capped sample instead of the whole
file; zeroing the whole-day figure; replacing the listener with an inline
`onchange`; using a CSS class that does not exist; and dropping the escaping on
a visitor-supplied path.
