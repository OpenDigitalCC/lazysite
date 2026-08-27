---
title: "SM608: a group does not say whether it shipped with the engine or was added here"
subtitle: "The Groups page lists what an install came with and what an operator built, in one undifferentiated list. Not material to behaviour; material to knowing what is safe to change."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). A `seeded` flag written AT SEED TIME - the only moment the answer is known for certain; inferring it later from a name would be a guess that gets more wrong as an estate ages and operators name things after the shipped ones. ABSENT MEANS OPERATOR-MADE, deliberately: every group predating the marker is on an instance somebody had already shaped, and claiming those shipped would be the confident wrong answer. Surfaced as a TOOLTIP rather than a column, as the operator asked - it is a fact you want when about to change something, not one to read on every visit - and each badge says what changing it risks, since the whole reason the distinction matters is that renaming or deleting a shipped group breaks something the engine expects while renaming your own breaks only what you built. MY FIRST CUT MARKED THE SEED BEFORE THE MANAGER GROUPS WERE FOLDED INTO IT, so it missed precisely the group whose deletion would break the most; t/unit/users/39 caught it by asserting 'everything a fresh install created' and meaning it. RAISED BY THE OPERATOR 2026-08-26 as a note to file, and filed as one - it is a FEATURE, so it waits for the 0.11.0 stable cut rather than riding on it. The ask: mark each group as a SYSTEM group (it came with the install) or a USER group (somebody here made it), possibly as a tooltip rather than a column. WHY IT IS WORTH HAVING even though the operator called it immaterial: the two kinds carry different risk on exactly the operations that are hardest to reverse. Renaming or deleting a shipped group breaks something the engine expects; renaming one an operator built breaks only what that operator built. Today the page gives no way to tell them apart, so a cautious operator treats every group as load-bearing and a hurried one treats none of them as. It also answers a question that comes up on every handover - which of these did we do? WHERE THE ANSWER ALREADY LIVES, so this is labelling rather than tracking: install.pl seeds a known set, and SM576 part 3 added `assignable` to the group settings store, so a per-group flag has somewhere to live and a precedent for how it is written and read. The honest default for a group that predates the flag is UNKNOWN rather than either answer - the same shape as SM576's backfill, where 'the flag has never been seen' had to mean 'this store predates it' and not 'no'. DESIGN NOTE, unresolved: whether the mark is derived (compare against the shipped list at render) or stored (a flag written at creation). Derived cannot be wrong but cannot distinguish a shipped group an operator has since modified; stored survives a rename but needs the backfill. Derived is probably right, and the shipped list already exists in install.pl. NOT A BLOCKER for anything, and explicitly not part of the 0.11.0 stable cut."
---

# What it changes

| Group | Today | Proposed |
|---|---|---|
| `lazysite-admins` | a group | a group, **shipped** |
| `content-write` | a group | a group, **shipped** |
| `jpm-stock-staff` | a group | a group, **added here** |

# Why it earns its place despite being immaterial

The mark carries no permission and changes no behaviour. What it changes is
what an operator does next: a group the install came with is one the engine
may expect by name, and a group somebody here made is one only local work
depends on. Rename or delete is where that difference bites, and it is
exactly the operation the page offers with no such warning.

# The default that is not a lie

A group carrying no mark, on a store that predates the flag, is **unknown** -
not "added here". SM576 part 3 learned the same lesson with `assignable`:
absence must mean "this store is older than the question", or an upgrade
silently answers it for every existing group at once.
