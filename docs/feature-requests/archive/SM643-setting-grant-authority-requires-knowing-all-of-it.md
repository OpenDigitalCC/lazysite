---
title: "SM643: setting a group's grant authority replaces the whole list, so adding one capability means first knowing every other"
subtitle: "Operator, 2026-08-27: 'cli grantable is a problem as it requires first to know all existing grants, as if not specified, removes all and just adds the specified... this is blocking me from fixing permission issues'"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED. Raised 2026-08-27 by the operator as a BLOCKER - they could not fix a live permission problem without first reading out an entire capability list and retyping it - and built the same day. `grantable-add` and `grantable-remove` act on the capabilities named and leave the rest alone. The replace form `grantable` is unchanged, because \"exactly these and nothing else\" is a legitimate intent that add and remove cannot express; it simply stops being the only form. Removing a capability that is not held is a no-op rather than an error, so a script can converge on a desired state without first asking what the state is. AN EMPTY VALUE IS REFUSED on the new verbs and the refusal names the way to clear the list: `grantable ''` clears deliberately, and silently clearing on `grantable-add ''` would be the sharpest possible version of the defect being closed. Both new verbs are operator-only, like the one they supplement - grant authority is conferred from above and never self-assumed, and a delegate that could widen its own set would have no ceiling at all. The audit entry carries the DELTA (+x -y) and the resulting list, so an operator reading the trail sees what changed without diffing two full lists. Five sabotages, all fail; the tests read the STORE rather than the reply, because a verb that answers correctly and writes something else would pass every assertion made against its own return value. SEE ALSO SM644, filed alongside this: the operator also wants a reset to the shipped defaults, on the argument that the drift these sites have accumulated runs one way, towards over-granting."
---

# What the operator has to do today

To add one capability to a group's grant authority:

| Step | |
|---|---|
| 1 | read the current `grantable` list out of the store |
| 2 | retype it in full, plus the new one |
| 3 | hope nothing was missed |

    group-set ops grantable manage_content,manage_nav,manage_forms,manage_themes

Omit `manage_themes` and that authority is gone. Nothing warns, because a
replace cannot tell an intentional removal from a forgotten entry.

# Why this is worse than an ordinary API wart

Grant authority is what lets a delegate confer a capability it does not itself
hold. It is operator-only to set, precisely because it is the ceiling on
delegation. So the one list that most needs to be edited carefully is the one
list that can only be edited by retyping all of it - and it is edited exactly
when something is already wrong and somebody is in a hurry.

# The shape

Two additional verbs on the same setting, acting on the list given:

    group-set ops grantable-add    manage_themes
    group-set ops grantable-remove manage_themes

Neither reads or requires the rest of the set. `grantable` keeps its current
meaning - set the list to exactly this - because "exactly these and nothing
else" is a legitimate intent that add/remove cannot express.

Everything else about the setting is unchanged: still operator-only, still
validated against `@CAP_KEYS`, still audited. `remove` of something not present
is a no-op rather than an error, so a script can converge on a desired state
without first asking what the state is.

# What must be true of the result

- Adding a capability leaves every other one in place.
- Removing one leaves every other one in place.
- The audit entry says what CHANGED, not just the resulting list - an operator
  reading the trail should be able to see that one capability was added without
  diffing two full lists.
