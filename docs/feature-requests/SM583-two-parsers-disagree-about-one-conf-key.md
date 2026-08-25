---
title: "SM583: two parsers read the same conf key and disagree about its value"
subtitle: "`layout: my layout` is `my` to one reader and `my layout` to the other. Unifying them would have silently picked a winner, so the row was refused and the disagreement filed instead."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 during the SM516 cleanup wave, proven by probe (tmp/tlo3-probe.pl): the review's TLO-3 proposed folding _read_active_layout_and_theme onto Domains::_parse as duplicate conf reading. They are not equivalent - _read_active_layout_and_theme matches \\S+ then strips to [A-Za-z0-9_-], while Domains::_parse takes the whole trimmed line - so a value containing a space resolves differently depending on which reader asks. The agent refused the row rather than unify them, which would have chosen a winner silently. WHICH IS RIGHT IS THE QUESTION: a layout or theme name containing a space is almost certainly invalid, in which case the stricter reader is correct and the permissive one should refuse rather than truncate; but nothing currently says so, and an operator who writes one gets a different answer from each surface. PLANNED for 0.10.33: decide the rule (probably: reject the value, do not truncate it), state it once, and have both readers use it. ALSO NOTED, same shape, not filed separately: in Backups.pm the 'Filesystem paths are never exposed' comment heads _archive_scope but describes _scrub_paths."
---

# The proving test

One conf value with a space, read through both surfaces, gives the same
answer - or is refused by both with the same message.
