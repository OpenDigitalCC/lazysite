---
title: "SM630: grant authority was derived from HOLDING, so an operator who practised least privilege on their own account lost the ability to delegate what they gave up"
subtitle: "Operator: 'I can't issue grants that I don't have, and I don't want all grants. I thought setting Scope ceiling would mean I could issue grants I don't have'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (edge, 2026-08-26). FILED RETROSPECTIVELY during the 0.11.2 filing sweep, which found this ref stamped into the changelog with NO FILING BEHIND IT - the worst of the three so found, because it is a change to the permission model. THE DEFECT: _may_confer returns true if the actor HOLDS the capability, or if one of its groups lists it as `grantable`. The seed set grantable to exactly ['api','mcp'] - the two channels SM467 knew a manager group would not hold - and let holding cover the other twenty-one. That works for an administrator who holds everything for ever, and fails the moment one narrows their own account: give up `purge` and you lose the authority to delegate it, with no warning, and no control in the manager that names grant authority at all. THE OPERATOR HAD DONE THE RIGHT THING AND BEEN PENALISED FOR IT, then reasonably tried the control that looked relevant - Scope ceiling, which governs a different axis entirely (how far an account REACHES, by intersecting its domain scopes with every ancestor's) and was never going to help. THE FIX: the bootstrap manager group is seeded with grant authority over EVERY capability, in both paths that create it - I had first patched only the one that does not run on a fresh site. No power is added at bootstrap, since the group already holds all but the two channels and holding implies conferring; what changes is that the authority SURVIVES the operator narrowing what they hold. So the one setup-manager command stays the only shell step, and handover is adding the next administrator to that group from the UI. STILL CONFERRED FROM ABOVE AND NEVER SELF-ASSUMED: `grantable` remains operator-only to SET, because a delegate that could widen its own grant authority would have no ceiling at all. WHAT IS NOT MEASURED: nothing here was field-verified; it is unit-tested and sabotage-verified only. The operator's original ask - that the CLI should not be needed at all - is met for the bootstrap case and not for changing grant authority later, which remains a shell operation by design."
---

# Two axes, and the interface offered the wrong one

| | Governs | Lever |
|---|---|---|
| **Scope ceiling** | how far an account reaches - domains and paths | per-account, operator-only |
| **Grant authority** | which capabilities it may confer without holding | `grantable` on a group, CLI-only to set |

The Groups page said nothing about the second, which is why the first was tried.

# Least privilege should not cost delegation

Holding and conferring are different questions. SM467 established that and
answered it for two capabilities; this answers it for all of them.
