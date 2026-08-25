---
title: "SM579: connectors - a page can call an API the operator configured"
subtitle: "The engine can already POST a form to a URL. What it cannot do is hold a REUSABLE, credentialed connector that several forms, buttons and tables send through - the way smtp.conf holds the mail account once and every email handler references it."
brand: plain
standard-margins: true
status: candidate
status-note: "REQUESTED BY THE OPERATOR 2026-08-25: a plugin function a page can call out to an API with, set up like SMTP - configure connectors, then wire them on; triggered by a form post OR a user button press; the data coming from the form OR from a data table. WHAT ALREADY EXISTS, verified in plugins/form-handler.pl: a `webhook` handler type is declared (name, enabled, url, format json|slack) and dispatch accepts both `webhook` and `api`, calling dispatch_webhook - which POSTs the non-underscore form fields as JSON through LWP::UserAgent with a 10s timeout and logs a WARN on failure. So FORM -> one URL already works. WHAT IS MISSING is everything that makes it a connector rather than a URL field: (1) a NAMED, REUSABLE connector holding endpoint, method, headers and CREDENTIALS in the reserved tree the way lazysite/forms/smtp.conf does, referenced by name from any number of handlers, so a key is written once and never appears in a per-form config an author can read; (2) a BUTTON trigger - a page control that sends without being a form submission; (3) a DATA TABLE source - sending a row (or a query's rows) rather than only the fields a visitor just typed; (4) the delivery discipline the existing webhook lacks: retry/timeout policy, an audit entry per call, and a visitor-facing outcome. PLANNED as a design; the security section below is the part that decides the shape and wants the operator's ruling before anything is built."
---

# What exists, and what a connector adds

| | Today (`webhook` handler) | A connector |
|---|---|---|
| Where the endpoint lives | a `url` field in each form's own config | one named connector in the reserved tree |
| Credentials | none - the URL is the whole secret | headers/auth held once, never in a per-form file |
| Reuse | copy the URL into each form | reference the connector by name |
| Triggers | a form post | a form post, a button, a table row |
| Payload | the form's own fields | form fields, or a mapped table row |

# The security questions that decide the design

These are not caveats to a settled design; they are the design.

**Who may name a destination?** The URL is the whole exposure: an engine
that POSTs wherever an author says is an SSRF engine, reaching
`localhost`, a cloud metadata endpoint or a neighbouring site. The
existing `handlers.conf` pattern already answers this for forms - a
handler is operator-vetted and an author only *binds* to it - and a
connector must follow it exactly: **the operator writes connectors; an
author references one by name and can never supply a URL.** An allowlist
of destination hosts, checked at call time rather than only at config
time, is the belt to that brace.

**Where do the credentials live?** Beside SMTP's, in the reserved tree
(`lazysite/forms/smtp.conf` is blocklisted, capability-gated and never
echoed). A connector file must be the same, and the manager must show a
key as set-or-unset rather than as a value.

**What can a visitor cause?** A button that calls out is a relay: without
the discipline forms already carry (the timestamp+HMAC window, the
per-form rate limit, quarantine), a page becomes a way to make the site
send traffic to a third party on demand. A button trigger inherits the
form gates or it does not ship.

**What does the visitor wait for?** An outbound call in the request path
holds the response open. A timeout is mandatory; a queued/asynchronous
mode is the honest answer for anything slow, and the SM415 outcome
banner is the shape for telling a person what happened.

**Is a call a data-handling event?** Sending a submission - or a table
row - to a third party is exactly that. Every call is audited with its
connector, its trigger and its outcome, and never its payload.

# Sending table rows

A row source is a read of the data store, so it answers the store's own
rules: the table's `public` flag defaults closed (SM476), and a
connector sending rows needs the capability that reads them. A mapping
(`column=field`) is required rather than "send the row", for the reason
the `db` handler already gives: a table gaining a column must not
silently start sending it.

# Proving tests

- An author-supplied URL is refused; only a named connector resolves.
- A connector's credential never appears in any manager response, any
  form config, or any audit line.
- A button trigger without a valid form token is refused, and the
  per-form rate limit applies to it.
- A call is audited with connector, trigger and outcome; the payload is
  not in the audit line.
- A table-sourced call sends only mapped columns; an unmapped new column
  is not sent.
- A connector whose host is not allowlisted is refused at call time.

# Register

An outbound interface is a significant change: `docs/SECURITY.md` gains
an entry in the shape git-sync's egress entry uses (what changed / threat
delta), because this adds an SSRF-shaped surface and a credential at
rest.
