---
title: "SM369 - the security headers cannot reach a static on a stock front end"
subtitle: "SM352 made the engine emit one header set on every response path including statics. On a stock proxy template the engine never answers a static at all, so the fix is unobservable there - and so was the defect it fixed."
brand: plain
status: shipped
status-note: "FILED 2026-08-18 from the site agent's 0.10.13 validation. They measured statics on edge carrying NO security headers - not HSTS, not Permissions-Policy, and not even the nosniff SM352 described as the prior state - and correctly concluded this instance cannot verify that half of SM352 either way. It is one cause with three symptoms: no engine headers on statics, no X-Lazysite-Front, and SM331's gating residue. Filed as a question about what the project can honestly claim, not as a defect in SM352. CLOSED 2026-08-18 by narrowing the claim rather than by building anything. Both the SM352 filing and the changelog now say the headers reach every response THE ENGINE ANSWERS, and name the consequence: on a stock template that is pages only. Nothing else in this filing was actionable without an instance that routes statics through the engine, and there is not one to hand - so the honest close is the text, not a measurement that cannot be taken. The other two items stay written down: measure on an SM283-template instance or the one-rule front door if one ever exists, and consider whether a health check should report 'statics on this site are answered by the front end, so engine response headers do not apply to them' - turning an invisible architectural fact into a stated one, the move SM337 made for layouts and SM360 for ACL keys."
---

# What was measured

On edge, cache-busted, on the theme mirror, `/assets/qrcode.js` and
`/favicon.ico`: **no security headers at all**, plus `max-age=315360000`.

Not the HSTS SM352 added. Not the Permissions-Policy. Not the
`X-Content-Type-Options: nosniff` that SM352's own filing describes as the state
before the fix.

# Why that is consistent rather than alarming

Only what the engine renders carries engine headers. On a stock proxy template
every static is answered by the front end, which never consults lazysite. So the
absence is total rather than partial, which is exactly what you would expect and
is *not* the "short by two" state SM352 was fixing.

One cause, three symptoms, all on the same instance:

- no engine headers on any static
- `X-Lazysite-Front` absent
- [[SM331]]'s cache-window gating residue, which [[SM368]] was mistaken for a
  front-end extension rule

# The question this raises

**SM352's static half is currently unverifiable in the field.** Its integration
test drives the engine directly and passes; no deployed instance the project can
reach answers a static from the engine, so nothing outside the suite has ever
seen those headers on a stylesheet.

That is not an argument that the fix is wrong. It is an argument that the
project should be careful what it claims: "every response path now carries the
set" is true of the engine and true of an instance on the SM283 template or the
one-rule front door, and says nothing about the majority of the fleet.

# What would settle it

Measure on an instance that routes statics through the engine
: either the [[SM283]] proxy template or `lazysite-front.pl`, the one-rule front
  door. Until one exists to hand, the claim rests on the suite alone.

Say which deployments it applies to
: the SM352 filing and the changelog both read as though the headers reach every
  response. They reach every response *the engine answers*, which on a stock
  template is pages only. That distinction belongs in the text.

Consider whether the engine should say so
: a health check that reports "statics on this site are answered by the front
  end, so engine response headers do not apply to them" would turn an invisible
  architectural fact into a stated one. That is the same move [[SM337]] made for
  layouts and [[SM360]] for ACL keys.

# Related

[[SM352]] (the header set), [[SM286]] (self-sufficiency - the engine asks
nothing of the front end, which is why it cannot make one hand statics over),
[[SM283]] (the proxy template that would route them), [[SM293]] (the one-rule
front door), and `inbox/archive/2026-08-18-validation-0.10.13.md`.
