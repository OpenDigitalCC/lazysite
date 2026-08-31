---
title: "SM662: a capability's reach is described in up to six places, and changing one is never enough"
subtitle: "Release manager, 2026-08-27, from 0.11.3: SM633 touched six, SM652 touched six, and every instance past the second was found by a gate rather than by reading"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL, and the halves are now the other way round. THE DECLARATION IS DONE: %need entries are declarative (an arrayref is ANY-OF, 'ALWAYS' means none), the predicates are rebuilt from it, and the gate fingerprint is byte-identical before and after - proved twice, once at the change and once after rebasing onto a stack that had added an action. Six lint suites that each parsed the sub bodies with their own regex now read the table through one helper (TestHelper::gate_caps), which is the duplication this filing is about, removed from the tests as well as the code. WHAT REMAINS: ControlApi::Actions and the unlocks map are still hand-kept copies - CHECKED now rather than derived. t/lint/98 fails if the register and the gate disagree, so a drift cannot ship; generating them from the declaration is the last step and is now a small one, because the fact is already data. Evidence that it matters: adding ONE action (SM704) still took seven registration points, and two gates caught what review missed."
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

# CORRECTION after first real use (SM682, 2026-08-28)

The fingerprint printed a BITSTRING, one column per capability in @CAP_KEYS
order. Its first real use - introducing `write_data` - reported all 140 gates as
changed, because inserting a capability into the vocabulary lengthens every row.

An instrument that cannot tell "a gate moved" from "the vocabulary grew" cannot
answer the question it was built for, and the failure mode is the bad one: it
cries wolf on exactly the change it was meant to make safe, and a reader learns
to skim the diff.

It is now keyed by NAME: per gate, whether no capability grants it, whether all
together do, and which grant it on their own. Adding a capability then appears
only on the gates that actually admit it. Re-run across SM682 the diff is four
substantive lines - the two row verbs gaining `write_data`, and the three
deliberately-constant introspection gates that admit anything.

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
