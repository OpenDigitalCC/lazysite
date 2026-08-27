---
title: "SM417: a visit is one actor, not one address"
subtitle: "The visitor token is hmac(ymd|ip), so every agent on a shared host - and every person behind one NAT - shared a single visit. The field measured a four-page walk arriving merged into one 22-step trail. Sessions now key per source, as SM392's promotion already did."
brand: plain
standard-margins: true
status: shipped
status-note: "TWO LATENT DEFECTS FELL OUT OF THIS, both of the same family - SM392 keyed some things on the promotion key and left others on the counting token: (1) pkey reached only the FIRST-PARTY ingester, so per-source promotion had silently never happened on a server-log site; (2) scanner_by is WRITTEN under the promotion key and was READ under the counting token, so on every first-party site since SM392 that lookup missed and `scanner_inferred` was silently 0 - an operator could not tell a behavioural promotion from a signature match, which is the only thing the field exists for. Neither was caught by the suite because the sweep test drives the server-log path (where pkey was absent and the two keys happened to be equal) and the trail tests drive the first-party path: two ingesters, each test exercising one, and the gap living in whichever one it was not. SHIPPED 2026-08-20, the release manager choosing per-source separation over decay and contradiction-escape (the filing's own warning: contradiction is the rule a spoofing scanner would aim at, and decay is one a patient scanner waits out). SM392 already keys the PROMOTION on token+user-agent for exactly this reason; the SESSION key now uses the same separation, so each actor's walk is its own visit and its own trail. COUNTING IS UNCHANGED and deliberately so - unique_visitors stays on the bare token, because SM392's rule is that one person with two browsers must not become two visitors. COUNTING-BASIS BUMP TO 3 (SM338): visit counts RISE on shared-address traffic, and the day file must say it counts the new way so the step in the series is attributable to rules rather than traffic. A LATENT GAP FOUND WHILE BUILDING IT: SM392 added pkey to the FIRST-PARTY ingester only, and every consumer falls back to the bare token when it is absent - so per-source promotion had silently never happened on any site whose stats come from the web server's own log. Fixed here; the sabotage matrix is what exposed it, because removing pkey from the server-log record broke no test until the test grew a server-log fixture."
---

# What the field measured

Four pages walked deliberately by one agent, arriving as part of a single
22-step trail merged with every other agent on the same host. The trail was not
wrong about the token - it was wrong about what a token means. On a
multi-agent host, or behind corporate NAT, "one visitor" was the ADDRESS.

# The rule now

- **Counting** stays on the token: one address, one visitor.
- **A visit** keys on token + user-agent: one actor, one session, one trail.

Two identities, deliberately, and SM392 wrote the reasoning down before this
was built: putting the user-agent into the counting token would make one
person with two browsers two visitors, which breaks the number the feature
exists to produce.

# The gap this uncovered

`pkey` reached only the first-party ingester. Consumers fall back to the bare
token when it is absent - a silent, correct-looking fallback - so on a
server-log site SM392's separation had never happened at all. One rule, two
ingesters, one of them obeying it.

::: widebox
Only the sabotage matrix found it: deleting `pkey` from the server-log record
broke nothing, because every test drove the first-party path. A fixture that
covers one of two code paths reports on that one and is silent about the other,
however confidently the assertions read.
:::
