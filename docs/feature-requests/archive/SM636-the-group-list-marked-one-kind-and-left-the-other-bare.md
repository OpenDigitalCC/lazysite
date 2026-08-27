---
title: "SM636: the group list badged backend groups and left roles bare, so a row with no mark could be a role or a group older than the flag"
subtitle: "Operator, 2026-08-27: 'on groups page, add marker on the list to identify if assignable or not. maybe a person icon, or backend icon when not assignable'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). SM576 marked the BACKEND groups and left the assignable ones unmarked, which reads as 'some groups are special' rather than 'every group is one of two kinds'. That was tolerable while the shipped set was six flat groups. SM631 seeded TEN backend bundles beside nine roles, and at that point the absence of a badge stopped carrying information: a bare row could be a role, or a group that predates the flag entirely. Both states are marked now - a PERSON for 'you can give this to somebody', a BOX for 'this only holds things'. THE WORD STAYS BESIDE THE ICON: an icon alone is a guess for anyone meeting the page for the first time, and this is the distinction that decides whether an operator can act on the row at all. The role badge also says WHERE to act - assignment happens on an account's card on the Users page, not here - because a marker that says 'you may do this' and not 'here is where' sends the reader looking."
---

# Every group is one of two kinds

| | |
|---|---|
| **role** | you can give it to a person |
| **backend** | it only aggregates capabilities and other groups |

Before this, only the second was marked.
