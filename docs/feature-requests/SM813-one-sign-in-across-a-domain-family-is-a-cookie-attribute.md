---
id: SM813
title: "SM813: one sign-in across a domain family is a cookie attribute, not an architecture"
subtitle: "Measured on 0.13.9 edge: one manager session authenticates on three different hosts and returns a byte-identical CSRF token, because the session store, the user store and CSRF are already instance-wide. The only barrier is that the cookies carry no Domain attribute. Asked for as a per-instance key defaulting to today's behaviour. The trade is cookie tossing from any host under the name, and the answer depends on who can obtain a subdomain - which is the operator's question, not the engine's."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-09
raised-by: sites agent
area: auth
---

# What was measured

One manager session for `ai-ui-tester` on 0.13.9 edge, its cookies presented
explicitly to three hosts on the same instance:

    edge.explore.lazysite.io       ?action=csrf-token -> {"ok":true,"token":"4142bf5b…"}
    edge2.explore.lazysite.io      ?action=csrf-token -> {"ok":true,"token":"4142bf5b…"}
    providers.explore.lazysite.io  ?action=csrf-token -> {"ok":true,"token":"4142bf5b…"}
    edge2.explore.lazysite.io, no cookie -> {"ok":false,"error":"Authentication required"}

The same token from all three, and on the manager path the same session turns a
`302` into a `404` on a domain it was never issued for. So identity is not
partitioned by domain anywhere: **the server already accepts the session
everywhere, and the browser is simply not offered it.**

Verified in the source rather than inferred from the measurement.
`lazysite-auth.pl:334` and `:338`:

    Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=…
    Set-Cookie: lzs_session=1; SameSite=Lax; Path=/; Max-Age=…

No `Domain` attribute on either, so both are host-only. That is the whole
barrier - there is no session federation to build and no store to share.

# What is asked

A per-instance configuration key for the cookie domain, defaulting to today's
host-only behaviour: unset changes nothing for any existing site; `.example.com`
offers the cookies to every host under that name.

**Default-off is the load-bearing part.** This must be something an operator
turns on for an estate they own, never a behaviour that arrives with an upgrade.

# The trade, with one correction

The report states it plainly and correctly: with a `Domain` attribute, any host
under that name can also **write** a cookie the parent will read, which is the
classic session-fixation route.

**The correction is to what it costs.** The report says choosing to share means
giving up `__Host-`, which forbids a `Domain` attribute. True, but nothing is
given up today: neither cookie carries the `__Host-` prefix now, and the names
are `lazysite_auth` and `lzs_session`. So the cost is **foreclosing a hardening
step not yet taken**, not surrendering one in place. That is a smaller price
than the report claims, and it is worth stating accurately in both directions -
it also means adopting `__Host-` is a live option for instances that do NOT
turn this on, and this key would permanently divide the estate into those that
can and those that cannot.

How much the tossing risk costs depends on one question the engine cannot
answer: **who can obtain a subdomain?** An estate where every host belongs to
one operator, close to nothing; a shared instance where a customer might be
given a host, real - and the edge instance already serves nine domains, several
client-facing. Which is exactly why a per-instance key is the right shape: the
operator who knows the answer for their estate is the one who should make the
call.

# What does not change

A shared session shares identity, never authorisation. `allowed_groups` and
`locked_users` are per-domain and are evaluated per request, so signing in once
does not admit an account to a domain its groups do not reach.

# Decisions this needs

- **Whether to offer it at all**, given it divides the estate on `__Host-`.
- **Where the key lives** - this is an instance-wide property rather than a
  per-domain one, so it does not belong on the domain record with the thirteen
  settings in [[SM814]].
- **Whether the value is validated against the instance's own domains**, so a
  typo cannot scope cookies to a name the operator does not control.

# Provenance

`inbox/2026-09-09-shared-sign-in-across-a-domain-family.md`. The measurement is
the reporter's, on 0.13.9 edge; the absent `Domain` attribute and the absent
`__Host-` prefix were read from `lazysite-auth.pl` here. [[SM814]] depends on
this one: a subdomain intranet only feels like one place if the sign-in is
shared.
