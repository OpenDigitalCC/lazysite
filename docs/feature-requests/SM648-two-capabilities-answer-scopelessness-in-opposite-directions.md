---
title: "SM648: a grant with no dav_scopes reaches no site package and every data table - one absence of scope, two opposite defaults"
subtitle: "Site agent, 2026-08-26, measured on one instance in one request: SM578 made the package verbs fail closed for a scopeless caller; the table reader fails open for that same caller"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), measured by the site agent 2026-08-26 on build 0.10.34 with partner claude-code-2 in group edge-testing-2 - a group with no domain access, so the grant resolves to NO dav_scopes. Two capability rows, same instance, same request: manage_domains reached NO site package (all four verbs refused - SM578 working exactly as designed), manage_data listed and read ALL NINE unscoped tables. THE AGENT RULED OUT THE INNOCENT EXPLANATION: it is not owner-visibility, and the brief shows the working. THIS IS A DEFAULT, NOT A BUG IN THE CODE, and the severity follows from that: on a single-domain instance the table behaviour is exactly right, and on the multi-domain instance SM151 and SM593 exist to serve it is wrong and SILENT - an operator who dutifully sets `domain:` on every table has done nothing whatever to the grants already reading them. EITHER OUTCOME RESOLVES IT: make a scopeless grant reach only tables that name no domain, matching what manage_domains already does for packages; or decide the behaviour is deliberate and say so in the SM593 migration note, plainly, that setting `domain:` has no effect on unscoped grants and grants must be scoped separately. What should not ship is the present state, where two capabilities on one instance answer the same question in opposite directions. RELATED: SM578 (the package half, shipped), SM593 (the table namespace, shipped), SM611 (a table belongs to a site - candidate, and the natural home for the decision)."
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

# Where the decision belongs

SM611 asks whether a data table should belong to a site, with an instance-wide
table as the deliberate exception. That is the same question one level up, and
whichever way SM611 goes should settle this - which is an argument for deciding
them together rather than patching this one first.
