---
title: "SM575: ownership is a pattern, or it is two cases"
subtitle: "ACLs enforce per-file ownership and themes enforce creator ownership. Briefs and data tables have never been asked. Either ownership is a rule every store follows, or it is two stores that happen to check, and nobody has said which."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-25 out of the SM570 two-principal walk on edge: a non-owner could not read, set or remove another principal's ACL rule (proven with a second principal issued by the operator), and themes refuse a delete with 'not created by this account'. Those are two stores. The briefs store (list_briefs, delete_brief - SM508, SM515) and the data tables (drop, rebuild, migrate) are UNVERIFIED: nothing says whether one partner can delete another partner's brief or drop another partner's table. QUESTION for the operator: is ownership a pattern across stores, or two isolated cases? Proving test, whichever way it is answered: a two-principal unit test per store (brief store, data tables) asserting the non-owner is refused; where the answer for a store is 'no ownership by design', the filing records that decision and the test pins the shared-store behaviour instead. The site agent will run the field version once the operator grants manage_content on a second principal. PLANNED for 0.10.33 under SM516: S if the tests only confirm what the stores already do; M if ownership must be added to a store."
---

# Two stores check, two are unasked

| Store | Ownership today | Evidence |
|---|---|---|
| ACL rules | per-file owner; non-owner refused on get, set, remove | two-principal walk on edge, 2026-08-25 (SM570) |
| Themes | creator; "not created by this account" | theme delete refusal |
| Briefs | unverified | SM508 / SM515 shipped list and delete with a capability gate only |
| Data tables | unverified | drop, rebuild and migrate gate on manage_data only |

# The question

Can one partner delete another partner's brief with `delete_brief`? Can
one partner drop another's table? If the answer is meant to be no, two
stores are missing a check the other two have. If the answer is that
briefs and tables are site-shared by design, that decision has never
been written down, and a partner reading the theme refusal will assume
the same protection everywhere.

# Proving test

A two-principal unit test per store - the brief store and the data
tables - asserting the non-owner is refused. Where the operator rules
"no ownership by design" for a store, this filing records the decision
and the test pins the shared-store behaviour instead, so the answer is
the same on every channel and stays that way.

The site agent runs the field version once the operator grants
`manage_content` on a second principal.
