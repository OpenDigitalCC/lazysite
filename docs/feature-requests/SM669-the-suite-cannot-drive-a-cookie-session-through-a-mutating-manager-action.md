---
title: "SM669: the suite has no way to drive a cookie session through a mutating manager action, so cookie-side capability gates are asserted as text and not as behaviour"
subtitle: "Found building SM660's test, 2026-08-28: the test was written, passed, and was deleted when sabotage showed it proved nothing"
brand: plain
standard-margins: true
status: candidate
---

# What happened

SM660 required BOTH `manage_forms` and `read_submissions` for three destructive
verbs. The gate is on the COOKIE path - token clients are refused those verbs
outright (SM214). So proving it needed a real manager session.

An integration test was written: mint a session cookie the way `lazysite-auth`
does, grant one capability, call the action, expect a refusal; grant the second,
expect no capability refusal. It passed.

Then the evaluator was sabotaged - the branch that ORs capabilities replaced
with a flat refusal - and the test still passed. It had never reached the gate.
Every request the fixture made was answered before the capability check ran, and
the assertions were reading the wrong failure.

It was deleted rather than kept, and SM660's declaration is asserted in
`t/unit/manager/136` on the `+` separator instead - which sabotage DOES catch.

# Why this matters beyond one filing

Nothing in the suite currently proves a cookie-side capability gate by
behaviour. `%COOKIE_CAP` is large, it now carries two different separators
meaning opposite things, and every assertion about it in the suite reads the
table as text. A table is a claim about behaviour; the two can diverge, and
SM662 is the filing about how easily they do.

The specific failures encountered, recorded so the next attempt does not
rediscover them:

- A cookie minted once at file scope verifies for early calls and stops
  verifying later in the same file. Minting per call is WORSE - it fails from
  the first request. The cause was not established.
- Mutating POSTs answer `Authentication required` where reads succeed with the
  same cookie, which points at the CSRF path rather than the capability gate,
  but was not confirmed.
- `TestHelper::grant_caps` writes `groups-settings.json` directly, and the users
  tool seeds on ordinary use; a hand-written group can be rewritten mid-run.
  Driving group setup through the CLI avoids it (the fixtures-agree-with-readers
  rule), and is what the deleted test ended up doing.

# What would fix it

A harness that logs in the way a browser does - obtains a session through the
auth CGI rather than forging a cookie, and carries the CSRF token - exposed from
`t/lib` so any test can drive a manager action as a named user with a named
capability set. That is the missing instrument, and it is the reason several
gates in this area are asserted as text.

# Related

[[SM660]] (the filing whose test this was), [[SM662]] (a capability's reach in
six places, of which the gate is one and the table another), SM214 (why these
verbs are cookie-only at all), [[feedback: fixtures agree with readers]].

# Not started
