---
title: "SM845: the way into a row is named and styled differently on every list, and opens an expander on some and a modal on others"
subtitle: "Release manager, 2026-09-11, on 0.13.12 in the modern style: Actions, Configure, More, Configure, edit, and a + with a click on the line - six lists, six answers"
brand: plain
standard-margins: true
status: candidate
---

# As reported

| List | Trigger | Opens |
| --- | --- | --- |
| Files | *Actions* | expander |
| Domains | *Configure* | modal |
| Data tables | *More* | expander |
| Connectors | *Configure* | expander |
| Users | *edit*, in a different style | modal |
| Groups | *+*, and a click on the line | expander |

Recorded as reported and not yet re-measured.

# What this reopens

[[SM816]] gave each list's trigger a visible word and chose the word **per list**
- Configure, More, Settings, Actions - on the argument that each should name what
its panel contains. This report reads the result as inconsistency across the
manager, which is a fair reading of the same facts from the operator's side: a
word chosen per list is a word the operator has to learn per list.

It also names what SM816 never addressed: **two lists SM816 did not touch** (Users,
Groups), and a **second axis** - the same kind of control opening an expander on
one page and a modal on another.

# The decisions

1. One word for "into this row" across the manager, or a word per list with a
   rule for choosing it.
2. One container - expander or modal - for a row's detail, or a rule for which
   and when.
3. Whether Users and Groups join the row idiom at all.

These are a vocabulary and an interaction model, not a stylesheet fix, and the
style guide is where the answer should be written so that the next list inherits
it.

# Related

[[SM816]] (the per-list word), [[SM819]] (the three-column row), [[SM841]] (the
trigger on a phone), [[SM847]] (modal chrome).
