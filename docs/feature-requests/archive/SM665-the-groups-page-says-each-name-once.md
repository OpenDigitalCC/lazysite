---
title: "SM665: the groups page says each name once, and each capability's label is its name"
subtitle: "Release manager, 2026-08-28: 'Agent AI (agent-ai) as well as tooltip - only needs tooltip', and 'Purge - destroy what no copy survives ... just needs to say Purge'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). Three edits, all removing a duplication rather than removing information: the housekeeping and purge labels dropped the em-dash explanation they were already serving through the '?' marker; the group heading moved its technical name from brackets into a tooltip; and the Users page group chips did the same, with their tooltip taught to name the group in every case rather than only when there was no description."
---

# What was duplicated

The capability labels
: `Purge - destroy what no copy survives` and
  `Housekeeping - destroy what a copy survives` carried their explanation in
  the label, while SM427's `?` marker beside each checkbox already carried a
  fuller sentence from `Capabilities.pm` on hover. The label was the shorter,
  worse copy of a sentence one hover away. Both are now just `Purge` and
  `Housekeeping`. Only the release manager named Purge; housekeeping had the
  identical defect and the two are written to read as a contrasting pair, so
  fixing one would have left the pair mismatched.

The group name
: The Groups page rendered `Agent AI (agent-ai)`, and the Users page group
  chips did the same beside a tooltip. SM642 added the brackets so an operator
  could see what every other surface, the CLI and the audit trail call the
  group. In a list where every row is a group, that is the same word twice on
  every row.

# What was kept

SM617's requirement is that the technical name stay DISCOVERABLE, not that it
stay visible. It moves into the tooltip in both places.

On the Users page that needed one extra change: the chip's tooltip was the
group's description, falling back to `Group "<slug>"` only when there was no
description. Dropping the brackets alone would have taken the technical name
away entirely from any group that HAD a description - which is most of them.
The tooltip now names the group in both cases.

# Not touched

The per-capability `?` marker and its sentence, which is where the detail
belongs and already was. The CLI's `list users` / `list groups`, which show the
display name with the login name in brackets by explicit request (SM642) - a
terminal has no hover, so the bracket is the only channel there.
