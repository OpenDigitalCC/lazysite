---
id: SM1106
title: "SM1106: a repeat unsubscribe says it is already stopped"
subtitle: "A POST for a rule and recipient already stopped answers the Already stopped page, not Unsubscribed again."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.6 test plan (edge.explore.lazysite.io), row R3
area: notifications
status-note: "SHIPPED on n614: lazysite-auth.pl handle_unsubscribe; t/integration/248."
---

# What happened

The 0.15.6 test plan, row R3:

> a repeat POST shows the same "Unsubscribed" page, not "already stopped".

SM1073 made the stop idempotent and audited a repeat as such, and the GET of a
stopped link already said "Already stopped". The POST recorded nothing the
second time but answered with the first time's page, so a person who followed
the link twice, or a mail client that posted it again, was told it had just
been done.

# What shipped

A POST for a pair already stopped answers 200 with the "Already stopped" page
the GET shows, naming the rule. Nothing is written twice and the audit row
still says `already stopped`. The first POST still says "Unsubscribed". A
token that does not verify is unchanged (400, audited as denied).

t/integration/248 covers GET, POST and the repeat POST.
