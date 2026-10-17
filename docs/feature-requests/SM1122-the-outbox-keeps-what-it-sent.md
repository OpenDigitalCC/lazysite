---
id: SM1122
title: "SM1122: the outbox list keeps what it sent"
subtitle: "A sent entry is listed from the ledger after the job has removed its file, for the ledger's eight days, and a lookup by its id finds it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.9 walk (edge.explore.lazysite.io), row X3 / finding F-2
area: notifications
status-note: "SHIPPED on n625: Lazysite::Outbox _ledger_events, _outbox_read, outbox_list; t/unit/notify/09."
---

# What happened

The 0.15.9 walk, row X3, finding F-2:

> a sent outbox entry is deleted rather than kept as `sent`. Listing by rule
> shows nothing, and by id says not-found.

Three events were listed queued; after the next tick all three were delivered;
then `notify-outbox-list&rule=zz59-mail` returned `"entries":[]` and a lookup by
id answered `404 not-found "no event '71ab9cfbc057f8aa' in the outbox you can
see"`.

SM1105 made the list show an entry as sent from the ledger, but only for an
entry whose file was still there: it assumed the removal had failed. The job
removes an entry after a send, which is the normal case, so in the normal case
the list had nothing to show, and its test (a directory the job could not write
to) never took the normal path.

# What shipped

- The list reads the ledger for events whose file is gone. Each is listed with
  state `sent` (or `handled` when every recipient was refused or folded into a
  held message), its rule, event id, `sent_at` and `recipients`, newest first,
  after the entries still in the outbox.
- `recipients` is a count by channel and outcome, for example
  `{"email":{"sent":2}}`. The ledger keeps a hash of each recipient, never an
  address (SM877), so the list says how many were reached and not who.
- A lookup by id finds such an event and answers with the same entry and the
  counts; an id the ledger never saw is still not found.
- The window is the ledger's: eight days (`$LEDGER_DAYS`). The list ignores a
  row older than that even before the job next prunes the file.
- A sent entry is not counted as queued, retrying or waiting in the rule's row
  or the list's `waiting`, and the same caller filter applies (a confined caller
  does not see another domain's rule).
- An entry whose file is still there, or that sits in failed, is listed once, from
  its file.

t/unit/notify/09 drives the normal path (the send succeeds, the file is removed);
t/unit/notify/07 and 08 now expect the sent entry to stay listed.

# Ruling

A sent entry shows how many recipients each channel reached, not who: the
ledger keeps only a hash of each recipient (SM877). The release manager,
2026-10-17: "keep the recipient counts, no addresses".
