---
title: "SM842: a form cannot be pointed at a data table from any granted surface, while it can be pointed at any URL"
subtitle: "Sites agent, 2026-09-11: the documented form-to-table route ends in a file no surface can read or write; the same grant may send every submission to an arbitrary external webhook. A proposal, and a tension between two rulings"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING) 2026-09-11, all four rulings, in 0.13.13. ONE WAY TO DELIVER: Lazysite::Handlers is the one reader and writer of handlers.conf (three parsers, which disagreed about an absent enabled, are gone), the one deliverer (the form handler and the schedule both call deliver()), and the one set of actions every surface calls - the new Handlers manager page, the control API (handler-*, schedule-*, form-targets-*; token-callable now, reversing SM799's cookie-only rule), MCP (list_handlers, save_handler, delete_handler, list_schedule, save_schedule, delete_schedule, bind_form) and tools/lazysite-handlers.pl. THE DESTINATION DECIDES: a table handler needs manage_data, a connector handler manage_connectors, smtp and file manage_forms; changing a type needs both; binding a form to an existing handler needs manage_forms alone. Types are smtp, file, table (with keep_copy, replacing db) and connector; webhook/api merged into connectors (a URL alone is enough; format: slack added). Forms name handlers and nothing else: inline targets are refused by bind_form, form-targets-save and a WebDAV PUT (422), and bind_form keeps the form's other settings. The timer calls handlers: lazysite/forms/schedule.conf entries {handler, every, payload}, run by one closed-set job (schedule-run) whose per-entry gate is the same cap_for_type; connector schedule_every/schedule_payload are refused by name. The upgrade converts once (install.pl runs lazysite-handlers.pl convert from the installed tree): db -> table, https webhooks -> connectors, inline targets -> named handlers (reusing one that delivers to the same place; inline targets beside a handler never delivered and are dropped, not woken), connector schedules -> schedule entries; a plain-http webhook to another host is left and reported, and lazysite-check reports anything left. Every delivery is one audit line. Found while building: the form handler read its forms from inside the docroot even on a site whose engine tree SM293 moved out (fixed here); the data store has the same shape (filed SM850)."
---

# The gap, as measured

`/docs/data-tables` tells an author to point a form handler at a table with a
`type: db` or `type: table` handler. Handlers live in
`lazysite/forms/handlers.conf`, engine-owned and refused on every surface: WebDAV
answers 403 to read as well as write, the control API has no handler action, the
manager has no handler page, and MCP answers *"Path is blocked"*. Measured on
edge 0.13.12 with an account holding every relevant capability. The documented
feature is reachable only from a shell.

This is by design as written: SM590 documented that `db` and `table` delivery is
handler-only, *"because a form writing rows into a declared table is exactly what
the operator should vet"*.

# The tension, which is the part to decide

`bind_form`'s inline target refuses `table` and accepts `webhook` - measured on
sites.lazysite.io, same account, same minute. So a manage_forms holder may send
every submission, the submitter's IP included, to any URL on the internet, and
may not send it to a local table it can already write row by row.

That is not a defect by the record: **SM421, ruled 2026-08-20**, settled that
where manage_forms is granted every surface delivers inline targets in full. But
**SM579, ruled 2026-09-08**, made "where site data goes" a conferral of its own -
a connector is a disclosure destination, so it needs manage_connectors rather
than a site grant. An inline webhook is a disclosure destination with no
credential. The two rulings now pull against each other, and which one governs an
inline webhook is the release manager's to say.

# The proposal: declare intake on the table (Option A)

The sites agent's recommendation, and it follows the engine's own idiom:

```yaml
public: false         # anonymous visitors cannot READ it
form_intake: true     # a bound form MAY write to it
```

`bind_form` accepts `{type: "table", table, fields}` only when the table declares
`form_intake: true`, the caller holds manage_data, and every mapped column exists.
The declaration is the vetting - on the object it governs, visible in
`data-table`, default false, so no existing table starts taking public writes
because a form was bound to it. The alternatives filed alongside are handler CRUD
over the remote surfaces (B) and a second, grantable handlers file (C).

Requirements whichever is chosen: `fields` stays required as the allow-list;
declared types still refuse rows that do not fit and the visitor is told so; the
binding is audited with the table name; `list_form_handlers` reports table
handlers; a refusal names which precondition failed.

# It lands with escaping, and only with it

A form feeding a table a public page renders is **stored XSS** on any engine that
renders db values raw - 0.12.x does (see [[SM844]]). SM786's escape at the sink
closes that in 0.13.x. This must never reach a site without it.

# The case that prompted it

A community site moving off Odoo: two live forms and two migrated tables with
identically named columns, and no way through the product to join them.

# Related

[[SM590]] (the position this contests), [[SM421]] and [[SM579]] (the two rulings
in tension), [[SM786]] and [[SM844]] (why it needs escaping), [[SM843]] (the key
a form-fed table needs).
