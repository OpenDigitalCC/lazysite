---
id: SM821
title: "SM821: whoami mixes account metadata into the capability map, and names two different things alike"
subtitle: "1310E-01, reported as an observation rather than a defect and accepted as one. MCP's whoami returns 49 keys under `capabilities` against the control API's 27; the extra 22 are account-record fields - email, created_at, groups, mfa_enrolled, token_expires_at, disabled - sitting among the capability flags. Nothing is missing and no authority differs. But `manager_ui: true` beside `ui: false` on the same account reads as a contradiction until you know one is a channel capability from a group and the other is this channel."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: sites agent
area: api
---

# The finding

Under `capabilities`, MCP returns 49 keys and the control API 27. Every key the
token surface has, MCP also has, so **nothing is absent and no authority
differs** - this is a shape complaint, not a gate complaint, and the reporter was
right to file it as an observation.

The 49 is exactly the `effective_settings` map, which is why the number is
familiar: [[SM685]]'s equivalence proof compared "all 49 settings keys" between
the old implementation and the new. So MCP hands back the whole settings hash
under a key that says `capabilities`, while the control API hands back a filtered
subset.

# Why it costs something

`manager_ui: true` sitting beside `ui: false` on one account, in one object,
reads as a contradiction. Both are real and both are documented in
`effective_settings`:

- `ui` - "interactive login is allowed", from `$s` with an inverted default.
- `manager_ui` - `$caps->{ui}` under another name ([[SM127]]), meaning the `ui`
  capability GRANTED BY A GROUP: real manager access.

Two different things named four characters apart, in one map, with opposite
values on a legitimate account. The map's own source comments call these "the
only entries where the mapping is not the identity" - so the engine already knows
they are the awkward pair, and publishes them side by side anyway.

# What is asked

1. **Separate account metadata from capability flags** in what `whoami` returns -
   `capabilities` carrying only `@CAP_KEYS`-derived booleans, and an `account`
   block carrying email, created_at, display_name, groups, mfa_enrolled,
   token_expires_at, disabled and the rest. Additive first: publish the split
   alongside the flat map, deprecate the flat one, per [[SM786]]'s shape.
2. **Or, at minimum, stop naming those two alike.** `manager_ui` is not a UI
   flag, it is "holds the ui capability by group". If the map is to stay flat
   then the name should say which of the two it is.
3. **And say why the two surfaces differ**, because that is undocumented today:
   MCP returning 22 more keys than the control API for the same account is either
   deliberate or drift, and nothing states which. If deliberate, the reason
   belongs in the practice document; if drift, they should converge.

Recommendation: 1, with 2 falling out of it. The two surfaces converging matters
more than the naming, because an agent written against one and run against the
other currently sees a different shape for the same account.

# Provenance

`inbox/2026-09-10-1310E-results-0.13.10.md`, ref 1310E-01, "one observation, not
a defect". The 49-key identity with `effective_settings` and the `ui` /
`manager_ui` definitions were read here.
