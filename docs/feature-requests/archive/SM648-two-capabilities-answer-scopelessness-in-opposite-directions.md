---
title: "SM648: a grant with no dav_scopes reaches no site package and every data table - one absence of scope, two opposite defaults"
subtitle: "Site agent, 2026-08-26, measured on one instance in one request: SM578 made the package verbs fail closed for a scopeless caller; the table reader fails open for that same caller"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED, as a THIRD STATE rather than a different default - which is what the worked examples changed about this filing. Empty @CALLER_SCOPES meant two opposite things: \"no confinement applies\" for the CLI and the render path, and \"confined to nothing\" for a grant with no domain access, and the second read every table because it presented as the first. FLIPPING THE DEFAULT WAS NEVER AVAILABLE: failing closed on empty would confine the CLI and the render path too, and a render path reaching no table serves a page with its data silently missing - on every site, not only multi-domain ones. That is very likely why packages could fail closed under SM578 and tables could not; packages have no render path and no CLI reading them through the same predicate. $CALLER_CONFINED is set by the two surfaces that serve a principal whose scopes were RESOLVED. A cookie operator never reaches that code - the block sits inside !_operator() - so operators, the CLI and the render path stay unconfined, which they genuinely are rather than accidentally. SM593'S UPGRADE-DAY PROMISE IS KEPT: a table naming no domain is still reachable by everyone, which is the SECOND escape in _may_reach and is deliberate. Three sabotages, all fail - and the one worth naming is \"confine everyone\", which fails on the CLI and render-path assertions: the test catches the over-correction as well as the defect. PART OF SM611 IS SETTLED BY THIS: the instance-wide table as the deliberate exception already exists and works; what was broken was only the first escape, and only for callers confined with nothing to be confined to."
---

# The measurement

| Capability held | Objects it governs | What a scopeless grant reaches |
|---|---|---|
| `manage_domains` | site packages | **none** - all four verbs refused, *"You do not have access to this package"* |
| `manage_data` | data tables | **all of them** - 9 unscoped tables listed and read |

One grant. One instance. One request. The same absence of scope producing
opposite defaults.

# Why this is worth a decision rather than a patch

Neither behaviour is obviously wrong on its own terms.

Failing closed is the safer default and is what SM578 deliberately chose for
packages, after a scopeless grant had previously reached all of them. Failing
open is the compatible default: `manage_data` predates per-domain tables, and
every grant holding it today was issued when there was nothing to scope.

What cannot be right is both, unexplained, in the same product. An operator
reasoning from one to the other will be wrong half the time, and there is
nothing on either surface to warn them which half they are in.

# The silent part is the dangerous part

Setting `domain:` on a table is the action an operator takes to confine it.
On a multi-domain instance they will take it deliberately, having read SM593,
and it will have **no effect at all** on the grants that were already reading
that table.

Nothing reports that. The table now names a domain; the grant still has no
scope; the read still succeeds. The operator has performed the documented
migration and acquired a confinement they do not have.

# Either resolution closes it

1. **Match the package behaviour** - a grant with no resolved dav_scopes
   reaches only tables that name no domain. Consistent, fails closed, and
   requires operators to scope grants they may have left unscoped for years,
   which is a migration with a real cost and must be announced as one.
2. **Declare it deliberate** - and say so in the SM593 migration note, in
   terms: setting `domain:` does not confine an unscoped grant, and grants must
   be scoped separately for the namespace to mean anything.

The second is cheap and honest. The first is safer and is not free. This filing
does not choose; it records that the choice is currently being made by accident,
differently, in two places.

# Worked examples, and why "flip the default" is the wrong instrument

Requested by the operator 2026-08-27, who could not direct the decision from
the filing as written. Reading the code changes the shape of it.

## The rule, in full

    sub _may_reach {
        my ($table) = @_;
        return 1 unless @CALLER_SCOPES;   # unconfined - the operator
        my $dom = _table_domain($table);
        return 1 unless length $dom;      # unscoped - as it always was
        return ( grep { $_ eq $dom } _caller_domains() ) ? 1 : 0;
    }

There are TWO escapes, and only the second is the migration story this filing
and SM593 discuss.

The first is the finding. `@CALLER_SCOPES` empty means *unconfined*, and the
source says why: **"EMPTY MEANS UNCONFINED, which is the operator - never 'no
domains'. The CLI and the processor's render path leave it empty and are
unaffected."**

## An overloaded sentinel, not a chosen default

Three different callers arrive as the same value:

| Caller | `@CALLER_SCOPES` | What it means |
|---|---|---|
| The CLI | empty | no confinement applies |
| The processor's render path | empty | no confinement applies |
| **A token grant with no domain access** | **empty** | **confined to nothing** |

Only two callers set it at all - `lazysite-manager-api.pl` and
`lazysite-mcp.pl`. Everything else leaves it alone and is unconfined by
construction.

## The three options, against one instance

Two domains, three tables: `contacts` (domain alpha), `stock` (domain beta),
`settings` (no domain).

| Caller | Today | Flip the default | Distinguish the sentinel |
|---|---|---|---|
| CLI / render path | all three | **breaks - reaches none** | all three |
| Grant scoped to alpha | contacts + settings | unchanged | unchanged |
| **Scopeless token grant** | **all three** | none | **settings only** |

**Flipping the default is not available.** It would confine the CLI and the
render path, and a render path that reaches no table serves a page with its
data missing - on every site, not only multi-domain ones. That is almost
certainly why packages could fail closed (SM578) and tables could not: packages
have no render path and no CLI reading them through the same predicate.

## What the fix actually is

A third state, not a different default:

- `undef` - unconfined. The CLI, the render path.
- `[]` - confined, to nothing. A token grant with no domain access.
- `[...]` - confined to these.

Two call sites set the value, so the change is small and localised, and the CLI
keeps working because it is genuinely unconfined rather than accidentally so.

**This also settles part of SM611.** "An instance-wide table as the deliberate
exception" is already implemented, as the SECOND escape - a table naming no
domain is reachable by anyone, which is the upgrade-day promise SM593 made and
should keep. The defect is only in the first escape, and only for callers that
are confined but have nothing to be confined to.

# Where the decision belongs

SM611 asks whether a data table should belong to a site, with an instance-wide
table as the deliberate exception. That is the same question one level up, and
whichever way SM611 goes should settle this - which is an argument for deciding
them together rather than patching this one first.
