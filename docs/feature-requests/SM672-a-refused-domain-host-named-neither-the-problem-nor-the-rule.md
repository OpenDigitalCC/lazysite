---
title: "SM672: `Invalid domain host` was returned for two different problems and stated neither, which blocked a security measurement"
subtitle: "Site agent, 2026-08-28: 'a fresh agent/operator adding a domain cannot tell what a valid host is. BLOCKS SM647.'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). The refusal now distinguishes an ABSENT host from a MALFORMED one, quotes what it was given, states the rule, and - for the absent case - says where to put it, because domain-set and domain-add read `host` from the JSON body only while domain-check reads the query string. Three copies of the host pattern collapsed to one: _valid_host, a regex in domain_preview, and a third in the manager API's domain-check, which could answer differently for the same host on different actions. t/unit/manager/140 covers both halves and pins the pattern to one place."
---

# What it cost

The site agent, measuring SM647 on edge 0.11.3, could not create a throwaway
domain. Every host they tried came back `Invalid domain host` with no rule and
no indication of what was wrong. They tried three plausible names, ruled out the
operator's hypothesis about missing fields, and filed it as a blocker.

The measurement they were trying to make is the one that found SM647's two
claims OPEN. It went ahead only because MCP's `domain_set` accepted what the
control API refused.

# What was actually wrong

Two different problems shared one message.

No host supplied
: `domain-set` and `domain-add` read `host` from the JSON **body**. `domain-check`
  reads it from the **query string**. An agent that sent it the other way got
  `Invalid domain host` - a message blaming a value it had checked carefully,
  which sends the caller to inspect the host rather than where they put it.

Malformed host
: The real case, which the message described adequately only if you already knew
  the rule.

Neither said which had happened, and neither stated the rule. This is SM237's
class exactly: two conditions pointing in opposite directions - fix your
request, versus fix your value - answered with one sentence.

# Three copies of one rule

Found while fixing it: the host pattern existed in `_valid_host`, again as a
literal regex in `domain_preview`, and a third time in the manager API's
`domain-check`. Three copies can answer differently for the same host on
different actions, and nothing compared them. They are one rule now, and the
test pins the pattern to a single occurrence. It is also a PUBLISHED name -
`valid_host` and `host_refusal` rather than the underscore-prefixed originals -
because reaching across a module boundary for a private sub is what perlcritic
refused, and rightly: a private name is a promise that nothing outside depends
on it, and the manager API now does.

That is SM662's subject appearing somewhere nobody had counted it.

# Related

[[SM237]] (two conditions, one message, opposite remedies), [[SM662]] (one fact
in many places), [[SM647]] (the measurement this blocked), [[SM670]] (the other
response-shape finding from the same run).
