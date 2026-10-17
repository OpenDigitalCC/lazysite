---
id: SM1146
title: "SM1146: a batch call: several Odoo calls in one request"
subtitle: "`POST {calls: [{binding, params}, ...]}` answers each in order, up to ten, each checked, authorised, recorded and audited exactly as a single call."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (P2), accepted by the release manager 2026-10-17 ("all rulings accepted"; SM1082 Q2)
area: odoo
status-note: "SHIPPED on n641: lazysite-odoo.pl _batch and _post_one, starter/assets/lazysite-odoo.js batch; t/unit/odoo/42, 44."
---

# What happened

From the lazysite-sites agent, "The 200 ms before an Odoo call starts", 2026-10-17 (inbox/archive/2026-10-17-the-200-ms-before-an-odoo-call-starts.md), option P2:

> **A batch call on the endpoint.** `POST {calls: [{binding, params}, ...]}`
> returns each result in order, each checked and recorded as a call today. A
> page's three reads (the lab's lead page) become one request. Useful now, before
> P1, and still after it.

A page with N reads started the endpoint N times.

# What shipped

- `POST {calls: [...]}` on the page endpoint, at most 10 calls (`$MAX_BATCH`); an
  empty list, more than ten, or `calls` that is not a list is `400 invalid` and
  says "a batch holds 1 to 10 calls", before any call reaches Odoo.
- The answer is `{ok: 1, results: [...]}`, one result per call in the order sent;
  each is the answer that call would have had alone, plus its own `status`.
- Each call goes through the same function as a single POST (`_post_one`): the
  token check for what that call's binding needs, the engine's gate (mode, domain,
  switch, OOM, connection), the key, the parameters, the rate cap, one call-record
  line and the engine's audit line. A call that fails does not stop the others.
- Writes follow the plan/apply rules of their binding: a confirm-write returns a
  plan, an `apply: immediate` write applies, and `{plan, confirm: true}` is a call
  too.
- The request carries one token (`visitor_token`, or the session token). A call
  cannot bring its own. A sign-in, a sign-out or a nested `calls` in a batch is
  refused for that call.
- If Odoo ends the person's session during a batch, the cookies are cleared once
  and the calls after it do not run on the dead session.
- The helper has `LazysiteOdoo.batch(calls)`: one POST; the calls refused for a
  stale token are sent again once, alone, with fresh tokens; those refused for want
  of a sign-in are sent again once, alone, after the person has been asked once.

t/unit/odoo/42 holds each of those through the real endpoint: order and statuses
with a mix of reads, an immediate write, a plan, an unknown binding, a binding the
caller may not run and a refused field; one call-record line per call that named a
binding; a plan made in a batch confirmed in one, once, and not by another visitor;
the cap, with Odoo not asked; no token, a token inside a call, a token without the
cookie; and the ended session. t/unit/odoo/44 runs the helper's half under node.

Found on the way and left (a finding, not changed here): a POST of a session
binding by someone with no Odoo session at all is answered `403 csrf`, because the
token check runs first and there is no session for it to fit; a GET is answered
`401 signin-required`. The helper's sign-in prompt is keyed to the 401.
