---
title: "SM662: a capability's reach is described in up to six places, and changing one is never enough"
subtitle: "Release manager, 2026-08-27, from 0.11.3: SM633 touched six, SM652 touched six, and every instance past the second was found by a gate rather than by reading"
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-27 by the release manager as the structural finding of 0.11.3, and named by them as the highest-leverage follow-up from it. TWO CHANGES IN ONE RELEASE EACH HAD TO VISIT SIX PLACES to change one fact about one capability, and in both cases the author (me) found two by reading and the remaining four by failing a gate. That is not a discipline problem that better care would fix: six hand-maintained descriptions of one fact will drift at whatever rate the code changes, and the only thing that has been catching it is the gates - which is lucky rather than designed, because a gate only exists where somebody was bitten before. THE EVIDENCE IS IN THIS RELEASE and is unusually clean: two independent changes, different subsystems, same count, same discovery pattern. SM654 already generates and lints the MCP half; the control-API half is blocked on %need holding PREDICATES rather than declarations, so which capability a gate tests cannot be extracted without restructuring a security-critical table. That restructure is the work this filing names. RELATED: SM654 (the unlocks map, partial - the MCP half done), SM633 and SM652 (the two measurements), SEC-2026-07 F3 (what a missed registry costs: a grant that resolves and then does nothing)."
---

# The two measurements

Both changed one fact about one capability. Both needed six edits.

**SM633** — the five service switches move to their own capability:

| Place | Found by |
|---|---|
| `%need` / `%COOKIE_CAP` | reading |
| `Auth::Settings::@CAP_KEYS` | reading |
| the hand-maintained `effective_settings` map | **`t/unit/users/21`** |
| `lazysite-check.pl`'s `@CAPS` | **`t/lint/81`** |
| `t/lint/76`'s core-versus-plugin list | **`t/lint/76`** |
| a test fixture's own copy of the capability list | **`t/unit/tools/41`** |
| `groups.md` grid + `users.md` PERM_LABELS | **`t/lint/19`** |
| `docs/reference/capability-map.md` (generated) | **`t/tools/26`** |

**SM652** — one capability reads a submission, on every channel:

| Place | Found by |
|---|---|
| `%need` | reading |
| `%COOKIE_CAP` | reading |
| `ControlApi::Actions.pm` | **`t/lint/86`** |
| `Capabilities.pm`'s `unlocks` map | **`t/lint/90`** |
| `docs/reference/capability-map.md` | **`t/tools/26`** |
| `docs/reference/control-api-actions.md` | **`t/tools/26`** |

# Why this is structural rather than careless

The pattern is identical in two unrelated subsystems: the author finds the
gates that *enforce*, and misses the descriptions that *advertise*. That is not
surprising - enforcement is where the change is being made, and the
descriptions are elsewhere by construction.

So the failure mode is not "somebody was not careful". It is that six
hand-maintained copies of one fact drift at whatever rate the code changes, and
what has been catching them is a gate happening to exist. **A gate exists only
where somebody was bitten before**, which means the coverage is a record of past
accidents rather than a design.

What a missed one costs is already on record: SEC-2026-07 (F3) was a grant that
resolved and then did nothing on every surface reading `effective_settings`,
because that map was maintained separately from `@CAP_KEYS`. SM633 reproduced
exactly that miss and `t/unit/users/21` caught it - the test written *because*
of F3.

# What is already done

SM654 generates nothing yet but LINTS the MCP half: every tool's declared
`cap`/`cap_also` is compared against that capability's `unlocks.mcp`, both
directions. That closes one of the six.

The two generated references (`capability-map.md`, `control-api-actions.md`) are
already generated and gate-checked, so they are not the problem - they are the
model. `t/tools/26` even names its own remedy in the failure message, which is
why regenerating them costs seconds.

# The work this names

**Restructure `%need` so a gate DECLARES its capability rather than testing it.**

Today an entry is a predicate:

    'form-submissions' => sub { $_[0]->{read_submissions} },

which is expressive - `manage_content || manage_briefs` is one line - and
opaque: nothing can extract which capability it tests without executing it. That
is why the control-API half of SM654 could not be linted and why
`ControlApi::Actions.pm` is a second, hand-kept copy of the same fact.

A declarative form - a list of capabilities plus a combinator - would let
`ControlApi::Actions`, the `unlocks` map and both generated references all be
DERIVED from the gate, which is the only copy that decides anything.

This is a security-critical table, so it is not a refactor to do casually, and
it is not one to do without a test that proves the resolved gate is identical
before and after for every action. That test is most of the work and is the
reason this is a filing rather than an afternoon.

# What would make it worth having

One fact, one place, and the rest generated - so that changing a capability's
reach is one edit, and a reviewer reading any description is reading the gate
rather than a copy of it made at some earlier date.
