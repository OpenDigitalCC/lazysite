---
id: SM822
title: "SM822: the connector call record is never pruned, and outlives the connectors it describes"
subtitle: "1310E's closing note. The call record on edge holds 47 entries from connectors that no longer exist, including ones deleted days ago, and nothing prunes it. The reporter's judgement is that this is probably right for an audit and wants a deliberate decision rather than a default - which is the correct read, because every test run adds to it and no policy has ever been stated."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: sites agent
area: connectors
---

# The finding

    connector-list returns []
    the call record still holds 47 entries

From connectors deleted days ago, including four probe connectors and four
jitter connectors removed during 1310E itself. Nothing prunes the record, and
every test run adds to it.

# Why it is a decision and not a bug

The reporter says it "is probably right for an audit", and that is the crux: a
call record whose rows vanish when their connector is deleted is a record an
operator can erase by deleting the thing it describes. [[SM771]] established
that every refusal is a row; a record that can be emptied by a delete undoes
that.

But an unbounded store on a request path is its own problem, and this one grows
from ordinary use rather than from incidents. The question has three answers and
no default is obviously right:

- **Never prune.** It is an audit trail. Consistent with the audit ruling of
  2026-09-10 ([[SM222]]): the record outlives the subject and the deletion is
  itself recorded. Cost: unbounded growth, and no operator-facing way to see how
  large it is.
- **Prune by age**, with the window configurable and the pruning recorded. Keeps
  the property that a delete does not erase history, while bounding the store.
- **Prune on connector delete.** Simplest, and the one to refuse: it makes the
  record erasable by the act it should be recording.

Recommendation: **prune by age, and say the window in the UI.** It keeps the
audit property that matters - a deleted connector's calls survive the deletion -
while bounding a store that otherwise only grows. And whatever is chosen, the
record's size should be visible somewhere, because "47 entries from things that
do not exist" was discovered by a tester rather than shown by the page.

# The general shape, worth noting

This is the third store in the campaign whose retention was never stated: the
visitor log ([[SM222]] L0), the audit trail, and now the call record. A store
that grows from ordinary use and has no stated retention is a decision deferred
rather than a decision made, and it surfaces as a surprise later.

# Provenance

`inbox/2026-09-10-1310E-results-0.13.10.md`, "State left on edge". The count and
the observation are the reporter's; they also confirmed all test artefacts were
removed and the passwordless account deleted rather than disabled.
