---
title: "SM474: a JSON boolean was refused, and misdescribed"
subtitle: "`{\"live\": false}` answered \"a value cannot be a list or mapping\". The strings, the integers and even \"yes\" were all accepted - the one representation a JSON client naturally sends was the only one rejected."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED 2026-08-22 from edge. CAUSE: `ref $v` is TRUE for a JSON::PP::Boolean, so the guard that refuses lists and mappings caught a scalar wearing an object. The field named the giveaway themselves - the coercion was correct and nothing stored was inverted - which places the fault in the guard rather than the conversion. FIXED by unwrapping to 1/0 before anything else looks at the value, so every type sees a plain scalar: a boolean field normalises it as usual, and a boolean sent to a TEXT field is now a type error with the right message rather than a shape error with the wrong one. WHY THE TESTS MISSED IT: every fixture wrote booleans as strings or integers, because that is what a Perl test naturally produces. The one caller that sends a real JSON boolean is a JSON client, which is every agent."
---

# Accepted and refused

```datatable
columns: Sent as | Result
widths: 6cm | X
bold: 1
tone: medium
---
`"true"` / `"false"` (strings) | accepted
`1` / `0` (integers) | accepted
`"yes"` / `"no"` | accepted
`true` / `false` (**JSON booleans**) | **refused** as "a list or mapping"
```

The rejected spelling is the one a JSON client sends by default, which is to
say the one an agent sends.
