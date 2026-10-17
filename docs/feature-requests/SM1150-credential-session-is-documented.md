---
id: SM1150
title: "SM1150: `credential: session` is documented"
subtitle: "starter/docs/odoo.md describes a person signing in to Odoo through the page and running bindings as themselves, as the code does, and lists it no longer under "Not available yet"."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (OOM Lab L-7), accepted by the release manager 2026-10-17 ("all rulings accepted")
area: odoo
status-note: "SHIPPED on n641: starter/docs/odoo.md; t/unit/odoo/47 holds the page to the code."
---

# What happened

From the lazysite-sites agent, OOM Lab findings for the Odoo extension, 2026-10-17 (inbox/2026-10-17-oom-lab-findings-for-the-odoo-extension.md), finding L-7:

> The Odoo binding guide does not yet document `credential: session` (its own
> "not available yet" says so). It works: the lab's CRM runs entirely on it.

# What shipped

A section, "A person's own Odoo account (`credential: session`)", written from
`Lazysite::Odoo::Session`, `Lazysite::Odoo::Identity`, `Lazysite::Odoo::Binding`
and the endpoint:

- what a session binding is as saved (authenticated mode only; no callers, no
  visitor key), and that it never falls back to the connection user;
- the sign-in and sign-out requests, the limiter, and the refusals
  (`signin-refused`, `two-factor`, `rate`);
- the two cookies, with their attributes and lifetimes, and that the session id is in
  no body, log or record;
- what a call carries (the visitor token), plan ownership by session, the actor
  in the record, an ended session;
- the doors that refuse a session binding (a page binding, a form, the schedule,
  the control API and MCP);
- a generic example binding and a page.

The bullet under "Not available yet" is removed (the parameter form remains). The
page also gains the `odoo_ca_file` setting (SM1149), the `?csrf=1` identity
(SM1145), the batch call (SM1146), the helper's name element, `who` and `batch`,
and the form's treatment of an apply that reports `apply-incomplete` (SM1148).

t/unit/odoo/47 reads the code for the names the page gives (both cookie names,
the refusal kinds, the batch cap) and fails if the page and the code part.
