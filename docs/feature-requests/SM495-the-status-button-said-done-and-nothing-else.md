---
title: "SM495: the Status button said 'Done.' and nothing else"
subtitle: "The data plugin's status returned three useful fields and no message, and the Plugin Manager shows message or the literal 'Done.'"
brand: plain
standard-margins: true
status: candidate
status-note: "FROM THE FIELD 2026-08-23, on 0.10.27, minutes after SM477 made the Status button work at all: it now says 'Done.' - true, and useless. The plugin's status() returns modules (present/missing), store (exists/bytes) and the table list; plugin-config.md renders data.message || 'Done.', so the structured reply is shown as its absence. FIX: status() composes a one-line message, worst news first - missing modules (the reason nothing else will work), then no-store-yet, then 'N table(s): names; store size'. The structured fields stay for tooling. SIZE S. The general shape is SM479's family: a true reply that omits what the asker needed."
---

# The finding

SM477 fixed the Status button running the usage fall-through. The button now
succeeds - and prints `Done.`, because the UI shows `data.message` with
`Done.` as the fallback, and `status()` returns no `message`. Three fields
(modules, store, tables) are computed, returned, and never seen.

# The fix

`status()` composes `message`, one line, worst news first:

- `missing Perl module(s): DBD::SQLite` - the one thing that explains every
  other failure, so it goes first;
- `no store yet - it is created on the first declared table` - absence of
  the store is a state, not an error;
- `3 table(s): events, products, team; store 48 KB` - the healthy answer.

The structured fields are unchanged; the message is FOR the button.
