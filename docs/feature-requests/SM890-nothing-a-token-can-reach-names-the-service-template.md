---
id: SM890
title: "SM890: nothing a token can reach names which service template a site runs"
subtitle: "Two releases in a row, the decisive question about a stale site has been 'is it pooled or CGI?' - and two releases in a row the agent measuring it could not answer. The only template-shaped marker on the wire names the front proxy, not the backend unit."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-15
raised-by: sites agent
area: operations
status-note: "ABSENT BY MEASUREMENT, NOT BY OMISSION - the reporter looked. Asked for in the 0.14.1 test plan ('per site: which service template') and again in the 0.14.2 plan, and reported both times as the one fact they cannot read: 'Nothing on the public surface or the token API names the unit.' The `x-lazysite-front` response header is the only template-shaped marker a request carries, and it DISCRIMINATES THE WRONG THING: of the seven sites that were running stale engines, three carry `hestia-proxy/acl` and four carry nothing, so it names the front proxy and not the backend. Both times the question mattered because the answer would have said whether a stale reading was a pooled worker holding old code or something else entirely. It no longer blocks 0.14.2 - every site is current - which is exactly when to fix it, rather than during the next incident."
---

# Why it keeps coming up

The last two releases both turned on the same question. 0.14.1 shipped a
FastCGI pool restart; 0.14.2 shipped it again on the path the estate actually
takes. Each time a site read an old version, the first question was **is this a
pooled worker still holding the old engine, or something else?** — and each
time it was answered by inference rather than measurement.

The 0.14.1 test plan asked for it per site. The 0.14.2 plan asked again, saying
it was the one fact I could not see from here. The answer both times:

> Nothing on the public surface or the token API names the unit.

# What exists, and why it is not this

`x-lazysite-front` is the only template-shaped marker a request carries. It does
not answer the question, and the 0.14.2 walk demonstrated that rather than
assuming it:

| | |
| --- | --- |
| Sites that had been running a stale engine | 7 |
| …carrying `hestia-proxy/acl` | 3 |
| …carrying nothing | 4 |

If it named the backend unit, those seven would agree. They do not, because it
names the **front proxy**. A marker that splits 3/4 across a set defined by a
backend property is measuring something else, and reading it as the answer would
have produced a confident wrong conclusion.

# What is actually wanted

Somewhere a token-holding partner can reach, one field saying which service
template the site runs — pooled (`lazysite@`), persistent (`lazysited@`), or
plain CGI.

It is not a new fact. The installer knows it, the upgrade path knows it well
enough to decide what to restart ([[N142A]]), and `lazysite check` can see it
from a shell. The gap is that **none of that is visible to the only party who
routinely measures the estate from outside.**

## Where it should live

Open, and worth deciding rather than assuming:

- **`/.well-known/lazysite-instance.json`** already exists, already answers with
  `Cache-Control: no-store`, and already reports the live engine version rather
  than the render's. It is the natural home: the question is about the running
  instance, and that endpoint exists to describe the running instance.
- **The token `whoami` / capability surface**, if it should be restricted to an
  authenticated partner rather than public.

The first is simpler and consistent with what that endpoint is for. The second is
the safer default if naming the runtime is judged to be information a stranger
should not have.

**That judgement is the decision in this filing**: a service template is a fact
about how a site is hosted, and whether that is public-ish or partner-only is not
mine to assume.

# Why now rather than at the next incident

Every site is current, so nothing is blocked. That is precisely the moment to
add a diagnostic — the alternative is discovering for a third time that the
question cannot be answered, while something is broken and the answer is urgent.

# Related

[[N142A]] (the upgrade restart, which knows the template), [[SM886]] (the render
dependency, whose field confirmation ran into this gap), [[SM283]] (what
`x-lazysite-front` actually exists to mark).
