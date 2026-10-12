---
id: SM1018
title: "SM1018: a signed-in member's form post names the member"
subtitle: "SM1010 phase 1a (Q1, ruled 2026-10-12 as recommended): a form delivery carries the verified session account as its actor, in the context and never as a field."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1010 Q1, ruled 2026-10-12 ("All other SM1010 open questions as the brief recommended")
area: forms
status-note: "SHIPPED (PENDING): the form handler passes the account a verified session cookie names as the delivery's actor (blank otherwise); a personal table row is owned by its member, the audit names them; no field carries it and X-Remote-User is never read. t/unit/forms/07, 08, 62."
---

# The ruling

SM1010 Q1 asked: may a form delivery carry the verified signed-in account as its
actor? The brief recommended yes, as context only (never a field), by the same
verification the rate-limit waiver already does. The release manager ruled on
2026-10-12 that every open question not otherwise ruled goes as the brief
recommended.

# What changed

`plugins/form-handler.pl` already verified the session cookie
(`Lazysite::Auth::Session::verify_session_cookie`, HMAC over the payload,
registry and account checks) and used the answer as a boolean for the SM425
rate-limit waiver. It now keeps the account name and passes it as `actor` in
every `Handlers::deliver` call and in the submission's own audit line. A
visitor without a verified session - including a forged cookie - is still
`actor => ''`.

What this gives, each measured in `t/unit/forms/62` through the CGI:

- a table handler with `row_policy: personal` writes a row owned by the member
  who posted (`created_by`), as SM857 designed it; an anonymous or forged post
  still belongs to nobody;
- the audit trail's actor column names the member for their submission and
  each delivery (`t/unit/forms/08`);
- a notification rule (SM1019) can tell who caused the event.

# The SM402 line, redrawn

SM402 removed an UNVERIFIABLE name: the client's own `X-Remote-User`, which
reached the audit trail's actor column. That stays removed - the handler never
reads the header (`t/unit/forms/07`), and a forged header plus a forged cookie
names nobody (`t/unit/forms/62`). The stored submission still carries no name:
nothing adds a field.

# Sabotage

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S5 | the actor is never carried (`my $actor = ''`) | 62 (row owner), 08 (audit) |
| S6 | the actor falls back to X-Remote-User | 62 (the forged row) |
