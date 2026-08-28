---
title: "SM677: every row save writes an audit line, and on a big table that is the log"
subtitle: "Release manager, 2026-08-28: 'data row save doesnt need to log, for big tables it fills the log' - which reopens a trade this project has now made twice"
brand: plain
standard-margins: true
status: candidate
---

# What happens now

Every mutating control-API action writes one audit line, and `data-row-save`
writes a `row=<key>` detail with it. On a data-driven site each edited row is
one line, and a table with thousands of rows produces thousands.

# THIS REVERSES A DECISION, TWICE MADE

The code says so in as many words: *"ROW KEYS LAND IN THE AUDIT LOG - the
release manager's decision, the SM465 trade accepted again"*. SM505 argued that
"someone edited that table" is half an answer when the question the trail gets
asked is WHICH row, and SM465 had accepted the same trade before it.

So this filing is not correcting an oversight. It is the volume cost of a
deliberate choice arriving in the field, and the resolution has to keep what
that choice was protecting or say plainly that it is giving it up.

# The distinction that resolves it

An interactive row save and a bulk load are different events, and only one of
them is worth a line each.

A person editing one row
: The row key is exactly the answer an auditor needs, and one line is the right
  cost. This is what SM505 was about.

An import writing ten thousand rows
: The auditable event is THE IMPORT - who ran it, against which table, how many
  rows, and from what file. Ten thousand lines saying a row changed do not
  answer a question anybody asks, and they bury the lines that would.

`data-import` is already its own action with its own audit line. So the volume
comes from row saves driven in a loop - by an app page, an agent, or a client
writing a table row at a time - each of which the engine cannot currently tell
apart from a person at a keyboard.

# The shapes, in preference order

1. **Coalesce a run.** A sequence of row saves to one table by one actor inside
   a window becomes one line naming the table, the count and the key range. The
   auditor keeps "which rows", loses nothing, and the log stays readable. Most
   work, best answer.
2. **Audit the SESSION, not the row, for token clients.** A person in the
   manager keeps per-row lines; an agent or app writing in a loop gets one line
   per table per session. Splits on the distinction that actually matters and is
   cheaper than (1).
3. **A per-table setting.** `audit_rows: off` in the descriptor, defaulting on.
   Simple, and puts the decision where the volume is known - but an operator has
   to find it, and will do so after the log has already filled.
4. **Drop the row detail entirely.** Cheapest, and gives up exactly what SM505
   and SM465 twice decided to keep. Only worth doing if the release manager now
   judges that answer not worth its cost - which is a legitimate call, but should
   be recorded as reversing those, not as a tidy-up.

# What must not happen quietly

Whatever is chosen, the audit trail's own guarantee holds: `t/unit/lib/16`
requires every registered mutating action to audit. Making row saves silent
means changing that registry deliberately, with the reason written down - not
removing a call and letting the test be updated to match.

# Related

[[SM505]] (row keys in the trail - the decision this reopens), SM465 (the same
trade, accepted earlier), SM343 (reading stats truncates the day - the other
place where an audit/telemetry cost surfaced in the field), the audit guarantee
in `t/unit/lib/16`.

# Not started
