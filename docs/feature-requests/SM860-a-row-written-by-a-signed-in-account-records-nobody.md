---
id: SM860
title: "SM860: every row written through the data endpoint records no author, on the one surface that exists for an app's own users"
subtitle: "`created_by` is stamped from an actor the endpoint never supplies. `lazysite-manager-api.pl` and `lazysite-mcp.pl` both set `Manager::Data::$auth_user`; `lazysite-data.pl` never does, so it passes the empty default, and `_stamp` writes undef. The field is not wrong - it is absent, and absent is exactly what the engine uses to mean 'written anonymously by a public form'. So a signed-in account's row is indistinguishable from a stranger's."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.14. `lazysite-data.pl` sets `Manager::Data::$auth_user` from the verified session, with `local` beside the DOCROOT it already localises and AFTER the require - assigning a package global before its module loads is silently undone by the module's own `our`. The fix passes the identity rather than filling the column, so an anonymous write still records nobody, and t/integration/98 asserts that direction too. t/lint/137 holds the 'set by each surface' contract a comment had been carrying alone: any top-level script calling the row writers must assign the actor, proven by removing the assignment, and it asserts it found at least three surfaces so a rename cannot leave it passing against nothing. Existing rows are NOT backfilled - see [[SM857]], whose ruled design treats an absent policy as shared for exactly that reason."
raised: 2026-09-12
raised-by: engine (found while sizing SM857)
area: data
---

# What happens

Reproduced in `tmp/probe-created-by-on-the-data-endpoint.pl`. One table with
`timestamps: true`; one row written through `lazysite-data.pl` by the signed-in
account `writer`, holding `manage_data`, over a verified session cookie with a
valid CSRF token; one row written through the same library call with the actor
supplied, as the control:

```
POST status=200 ok=1
row r1  created_by=NULL/EMPTY      <- through the endpoint, as `writer`
row r2  created_by='writer'        <- through insert_row, actor => 'writer'
```

The write succeeded. The engine simply did not record who made it.

# Why

`Lazysite::Data::Tables::_stamp` takes the author from `$opt{actor}`:

```perl
my $who = defined $opt{actor} && length $opt{actor} ? "$opt{actor}" : undef;
```

`Manager::Data::action_data_row_save` passes the package global `$auth_user`,
declared `our $auth_user = '';` with the comment *"set by each surface"*. Two
surfaces set it - `lazysite-manager-api.pl:438` and `lazysite-mcp.pl:397`, both
marked SM468 for schema-history rows. **`lazysite-data.pl` sets it nowhere.**

So the value passed is the empty-string default, `$who` is undef, and the column
is written NULL.

The identity was available the whole time. `lazysite-data.pl` verifies the
session cookie and has the account in `$user` before it dispatches - it deletes
forged identity headers and rebuilds the environment from the verified session,
precisely so that what follows can trust it. It then calls the row writer
without it.

# Why this is worse than a missing field

`_stamp`'s own comment states the contract:

> Empty when the writer was not a signed-in account (a public form): an absence,
> never a guess.

Absence is therefore **load-bearing**: it means "anonymous". A signed-in
account's row arriving with the same absence does not read as missing data, it
reads as a positive claim that nobody was signed in. Two different facts share
one representation, and the wrong one is the one a reader will believe - the
[[feedback_a_boolean_has_four_states]] shape, on a provenance field.

# Why it blocks SM857

[[SM857]] confines a write to rows whose `created_by` is the caller, and calls
that stamp "the one field in a row a caller cannot forge". That is true of the
mechanism and false of the data: on the surface an app's own users actually
write through, the field is empty.

Two consequences, and the second is the one that decides sequencing:

1. Turning on confinement would lock **every existing row** away from the person
   who created it, because NULL matches no caller. Not a refusal anybody could
   diagnose from the message.
2. So SM857 needs a decision about existing rows - backfill, or treat NULL as
   unowned and say so - and that decision cannot be made well while the field is
   still being written wrong. **Fix this first, in its own right.**

# The fix

Set `$Lazysite::Manager::Data::auth_user` from the verified session in
`lazysite-data.pl`, beside the other environment the endpoint rebuilds from that
same session, so the actor comes from the one identity the endpoint has already
proved.

Then hold it with a lint rather than a comment. `our $auth_user = '';  # set by
each surface` is a declaration the code relies on three callers to honour, and
one of them did not - the [[feedback_a_declaration_the_code_ignores]] shape. A
check that every surface reaching `action_data_row_save` sets the actor first is
what stops the fourth surface repeating it.

# Related

[[SM857]] (which rests on this stamp), SM468 (which introduced `$auth_user` for
schema history and set it on two surfaces), [[SM852]] (where a gated write
lands - the same question of whose write this is),
[[feedback_a_boolean_has_four_states]], [[feedback_a_declaration_the_code_ignores]].
