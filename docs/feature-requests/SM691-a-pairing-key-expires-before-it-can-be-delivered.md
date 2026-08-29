---
id: SM691
title: A pairing key expires before it can be delivered, and the only delivery that works spends it
raised: 2026-08-29
raised-by: edge-testing agent
area: auth
status: shipped
status-note: "SHIPPED in 0.11.7 - pairing_key_ttl is settable, floored at a minute and ceilinged at a day. THE DEFAULT IS UNCHANGED at fifteen minutes: raising it loosens a credential handover and that is the operator's decision, not something to change while fixing their report about delivery. The message quotes the value in force rather than the default. ORIGINALLY: OPEN. Onboarding three edge accounts over the control-API/WebDAV path hit three frictions at once: keys minted at 20:32 all returned 401 'Invalid or expired pairing key' the next working window; the agent could not be handed a key by file because the stubs it wrote were 0600 owned by the agent's user and the operator is a different user; and the fallback - pasting keys into chat - is marked spent by the brief's own rule. So the only delivery that worked also invalidated the keys. The exchanged token is fine (about 24h confined, about 30d full); the entire fragility is the pairing step. MINTING STAYS WITH THE OPERATOR - this is about TTL and delivery, which are engine concerns."
---

# The three frictions, in one sitting

1. **Expiry before use.** Keys are single-use AND short-lived. Any gap between
   mint and exchange - a compaction, an overnight pause, an operator minting
   ahead of the run - spends the window. All three keys minted at 20:32 returned
   HTTP 401 the next working window.
2. **The file hand-off ran the wrong way.** The agent prepared config stubs for
   the operator to fill; they were mode 0600 owned by the agent's user, and the
   operator is a different user, so the operator could neither read nor fill
   them. The direction was backwards: the party who OWNS the secret should drop
   the file, not the party who consumes it.
3. **The delivery that worked spent the keys.** The fallback was pasting them
   into the conversation, and the brief's own rule says a key that has appeared
   in any transcript should be treated as spent. So the successful delivery was
   also the one that invalidated what it delivered.

Once exchanged, tokens behaved: about 24 hours for the confined accounts, about
30 days for the full one. Nothing here is about token lifetime.

# What would fix it

Any one of these removes the failure; together they remove it comfortably.

- **Mint inside the agent's window.** Generate immediately before the run and
  exchange at once. Minting in advance is the single biggest cause of the 401,
  and it is a practice change rather than an engine change - free.
- **Lengthen the pairing-key TTL, or make it configurable.** The exchanged token
  already carries the real session life, so the pairing key is only a handover
  device. A key surviving an hour rather than minutes absorbs a compaction or a
  pause. This is the engine change being asked for, and it wants a deliberate
  number rather than a bigger one: the key is single-use, so its window is the
  whole of its exposure.
- **Deliver by a file the OPERATOR drops**, at an agreed path, group-readable to
  the agent's user. The agent consumes it with `curl -K` and never echoes it: no
  key in the transcript, no owner mismatch. This inverts the direction that
  failed.
- **Prefer the connector token where a connector exists.** The operator puts a
  generated token in connector settings and no secret crosses the conversation.
  It does not cover per-account negative tests - a connector is one identity -
  but it is the clean path for the full account.

# The boundary this respects

Minting stays with the operator. The request is about the key's LIFETIME and its
DELIVERY MECHANISM, both of which are engine and brief-generation concerns. Who
may mint a credential is not in question here and should not be changed as a
side effect of fixing this.

# Related

[[SM690]] (the brief overstating the grant, which compounded this: an exchange
spent discovering the caps were wrong is an exchange to be minted again),
[[reference_edge_client_testing]]-adjacent practice: whoami preflight per run.

# Not started
