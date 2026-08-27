---
title: "SM643: setting a group's grant authority replaces the whole list, so adding one capability means first knowing every other"
subtitle: "Operator, 2026-08-27: 'cli grantable is a problem as it requires first to know all existing grants, as if not specified, removes all and just adds the specified... this is blocking me from fixing permission issues'"
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-27 by the operator, and BLOCKING them: they cannot fix a live permission problem without first reading out an entire capability list and retyping it. `group-set GROUP grantable a,b,c` is a whole-list REPLACE - anything omitted is removed - so the only safe way to add one capability is to read the current set, append to it, and write it all back. A read-modify-write the operator has to perform by hand, against a live access-control list, under time pressure, is a mistake waiting to happen: mistype one existing entry and grant authority silently disappears. THE ASK: add and remove verbs that act on the list given and leave the rest alone, so no knowledge of the existing set is required. The replace form stays - it is the right shape when the intent really is 'exactly these' - but it stops being the only form. This is a CLI ergonomics fix over an operator-only setting; it changes no ceiling and no capability meaning, and add/remove is strictly SAFER than the replace it supplements because neither verb can silently drop an entry the operator never mentioned."
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
