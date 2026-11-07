---
id: SM1388
title: "SM1388: a folder rule's history needs the folder to exist, and says so"
subtitle: "A rule with history: true is refused until its folder exists. The docs did not say so, and the refusal named the path as not a folder, which read as a file."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent (0.16.7 small fixes)"
area: access
status-note: "SHIPPED (PENDING) on n764: action_acl_set's history check tells a folder that does not exist from a file; OPERATOR.md and the access-control model say the folder must exist. t/unit/manager/420."
---

# What happened

A folder rule may say `history: true` (SM1324), and `action_acl_set` refuses it
unless the path is a folder in the document root or the private store. Setting
the rule before creating the folder was refused with "'X' is not a folder. Set
it on the rule of the folder that holds it", which reads as if the path were a
file and points at a different rule. The protected-history docs did not say the
folder had to exist.

# What shipped

**The refusal says which.** A path that exists and is not a folder keeps the old
words. A path where nothing exists yet is refused with "the folder 'X' does not
exist yet. Create the folder first, then set history on its rule. Nothing was
changed." Same kind (`invalid`) and field (`history`); nothing is written.

**The docs say so.** `docs/OPERATOR.md` (logging and history) and
`docs/architecture/access-control-model.md` (a folder's own history) say the folder
must exist before its rule can say `history: true`.

# Tests

t/unit/manager/420: a folder that does not exist is refused naming the field,
saying it does not exist and to create it first, and writes nothing; once the
folder exists the same call is written. A single file is still named as not a
folder. With Files.pm as on main the new subtest fails on the wording.
