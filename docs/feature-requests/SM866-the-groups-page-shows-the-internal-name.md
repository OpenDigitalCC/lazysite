---
id: SM866
title: "SM866: the Groups page shows the display name and hides the internal one in a tooltip, so a group cannot be matched to a backend request without hovering every row"
subtitle: "SM642 showed `Display Name (group-name)`. SM665 moved the name into the row's `title` attribute, reasoning that in a list of groups it was the same word twice. It is not - `cap-content` is labelled 'Capability: content', and the case where the two match was already excluded by an existing guard. This reverses SM665 and says so."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.15. The name is back in brackets beside the label, the tooltip is kept as well, the existing `info.label !== g` guard still prevents a group whose label equals its name being printed twice, and a group with no label shows no empty brackets. t/unit/manager/121 RUNS the fragment through node rather than grepping the source, following that file's own rule, and asserts all four cases; the visible-name assertion failed before the change."
raised: 2026-09-12
raised-by: release manager
area: manager
---

# What was reported

> "on groups page, should be Display Name (internal_name) - currently it doesn't
> show the internal name so hard to locate groups when connecting with backend
> requests."

# This reverses SM665, and the reversal is the interesting part

SM642 put the group name in brackets beside its label, so an operator could see
what every other surface calls it. SM665 took it out again and left it in the
row's `title`, with this reasoning recorded in the source:

> "SM642 put it in brackets so an operator could see what every other surface
> calls the group; in a list of groups that is the same word twice on every row.
> The requirement from SM617 is that the technical name stay discoverable, not
> that it stay visible."

Both halves of that turn out to be wrong in a way worth writing down.

**It was not the same word twice.** The seeded groups carry labels that differ
from their names - `cap-content` is labelled `Capability: content`, `ch-files`
and the rest likewise. And the one case where label and name really are the same
was already handled, one line above SM665's own change:

```js
var lbl = info.label && info.label !== g ? info.label : '';
```

When they match, `lbl` is empty and the bare name renders alone. So the
duplication SM665 removed could not occur on the rows it was worried about, and
what it actually removed was a second string that was genuinely different from
the first.

**"Discoverable, not visible" does not survive contact with the use.** SM617's
requirement is real - every other surface, the CLI, the audit trail and every
backend request name the group by its key - but a `title` attribute does not
satisfy it for what an operator does with that key. A tooltip:

- cannot be found with the browser's own search, so you cannot locate the group
  you already know the name of;
- cannot be copied, and the name exists to be typed somewhere else;
- does not exist on a touch device.

The release manager's sentence is the measure: *"hard to locate groups when
connecting with backend requests."* That is reading a name in order to use it
elsewhere. Hovering each row in turn to discover which one you meant is not
discovery, and it is the exact task SM617 wanted the name kept for.

# What shipped

`Display Name (group-name)`, inline in the row's name span, with the tooltip
kept as well - it costs nothing and states the relationship in words for anyone
who does hover. No new class: `mg-row-meta` is a separate row cell for secondary
facts like "8 members", not inline text inside a name, so using it here would
have put the key in a different column rather than beside the label.

Unchanged, and asserted: a group whose label equals its name renders once; a
group with no label shows no empty brackets.

# Not the same problem, checked

The **Users** page shows the group NAME with the label beside it - the opposite
arrangement - so it never had this defect, and its group picker is a place where
you choose by role rather than cross-reference a key. Left alone.

Noticed while checking: `groupLabels` in `users.md` is built and never read -
SM631 split the three facts into `groupMeta` and the old map survived with no
consumer. Harmless, and a separate tidy.

# Related

SM642 (which showed the name), SM665 (which hid it - reversed here), SM617 (the
requirement both were weighing), [[feedback_verify_what_renders_not_the_source]]
(why the test runs the fragment instead of grepping it).
