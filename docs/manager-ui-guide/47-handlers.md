---
title: "Handlers"
brand: plain
---

# Handlers

A handler is a named function a form or the schedule calls: it sends email,
keeps each submission in a file, stores a row in a data table, or sends through a
connector. One page holds the three things that name a handler - the handlers,
which forms call which, and what the timer calls - and the control API, MCP and
`lazysite-handlers.pl` do exactly what it does, through the same code (SM842).

The page is offered to an account holding any of Forms, Data or Connectors.
What that account may change depends on **where each handler sends**: a table
handler needs Data, a connector handler Connectors, an email or file handler
Forms.

## Make a handler

Where
: System -> Handlers -> New handler

Do
: Choose "Store in a data table", give it an id and a name, choose the table from
  the list and map form fields to columns (`name=name,email=email`). Create it.
  Then do the same with an account that holds Forms but not Data.

Expect
: The table is chosen from the site's own tables, not typed; a field the type
  does not take is never offered. With Data the handler is created and listed,
  saying which capability governs it and that nothing uses it yet. Without Data
  the refusal names the capability that would work.

Negative
: A mapping to a column the table does not have, or a table that is not
  declared, is refused when saved - naming the columns or tables that exist -
  rather than accepted and failing at a visitor's submission.

## Bind a form

Where
: System -> Handlers -> Forms -> a form's Handlers

Do
: Tick the handlers the form should call and save. Submit the form on the public
  site.

Expect
: The form calls every ticked handler; the visitor is thanked when at least one
  delivers. The audit log has one `deliver` line per handler, naming the form and
  the handler and never the fields. The form's other settings (rate limit,
  uploads, quarantine) are unchanged.

Negative
: Binding a form to a connector handler whose connector does not permit public
  invocation is refused, because it would refuse every submission. A form whose
  only handler is switched off refuses the visitor rather than thanking them.

## Schedule a handler

Where
: System -> Handlers -> Schedule -> New schedule entry

Do
: Choose a handler, an interval (at least 300 seconds) and the fields it is
  called with, one `name = value` per line. Create it, with the daemon running
  and its job account holding the capability of the handler's destination.

Expect
: On the next tick after the interval, the handler is called with exactly those
  fields; the schedule row says how often, what it calls and which capability
  runs it. The daemon's run record says what each entry did.

Negative
: An entry the job account may not run is refused by name and retried on the
  next tick once the grant is given - it does not wait a whole interval. A
  handler still called by a form or the schedule cannot be deleted; the refusal
  names what uses it.

## After an upgrade from before 0.13.13

Do
: Run `lazysite-check`.

Expect
: Every form and schedule names a handler the engine reads. The upgrade converted
  inline form targets into named handlers, webhook handlers into connectors and
  `db` handlers into `table`; anything it could not convert (a plain `http://`
  webhook to another host) is reported here and by the upgrade, with the command
  that repairs it once the cause is fixed.
