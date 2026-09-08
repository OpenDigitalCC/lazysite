---
id: SM778
title: "SM778: one register of people - display names wherever a login is handed back, and people who never sign in"
subtitle: "From familyhq.explore: a site rendering bylines had no route from a login to a display name except for its own viewer, so it kept a person table of its own - and the two registers drifted until every byline read as a bare login. The operator's ruling: the same fact in two places is tech debt, and the answer is one register, not better synchronisation."
brand: plain
standard-margins: true
status: candidate
---

# The ruling, recorded

"As soon as the same fact lives in two places it is tech debt, and the
answer is not better synchronisation. One register of people, with metadata
tables hanging off it, rather than two registers that must be kept level."
(The operator, 2026-09-08, relayed by the sites agent.)

The reason the site kept its own list is a person who never signs in - a
grandmother in the photo strip, the gratitude entries and the Hygge
readings, with no account. Once that list existed, the account-holders'
names were copied into it too, and the copies drifted.

# What is asked, in the order the field ranks it

1. **The user register carries people who cannot sign in** - an account
   record with no credentials and no login route - so there is one list of
   humans, and an app's table holds only app data (a colour, a school class,
   an ambition, display order) keyed to that record.
2. **The display name wherever a login is handed back** - audit rows, form
   submission attribution, ACL and group membership listings, `principals`,
   the users tool's listings. (`holds` is done: SM779.)
3. **A read-only name lookup a page can call with an ordinary session**, for
   logins the viewer can already see: login and display name, nothing more.

Items 2 and 3 stand on their own; item 1 is what stops every site with a
non-login person building its own register.

Stays app-side either way: an aggregate row ("All of us") is not a human.

# What deciding it needs

Item 1 is a shape change to the account store (a record without a credential
is today an invalid account; `add` requires a password; listings, the
permissions grid, `users-detail`, the sysop's own audit of who can sign in,
and the AI/partner distinction all read the store) and wants a plan before a
branch: what such a record is called, what it may hold, what may be granted
to it (nothing), how it is created and removed, and how the manager Users
page shows it apart from an account. Items 2 and 3 are a morning each once
the shape of item 1 is settled, or on their own if it is not.

Held for the release manager's word on scope and order.
