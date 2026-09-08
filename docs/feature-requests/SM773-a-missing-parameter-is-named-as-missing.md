---
id: SM773
title: "SM773: a missing parameter is named as missing, across the control API"
subtitle: "Candidate, from the field's 136E-04 note: connector-delete with the id in the query string answered a charset complaint. The third time in one campaign that a parameter in the wrong place was answered as a wrong value (theme-copy twice before). Every action declares its parameters and where they go; the answer for an absent one should be '<name> is required (in the body)', generated once, from the declaration."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm773-a-missing-parameter-is-named-as-missing (stacked on SM770). The declarations carry `required => 1` where the handler ALREADY refuses an absent value - marked by reading the handler, so hoisting changes the message and never the behaviour - and the dispatcher answers an absent one before the branch runs, in one sentence generated from the declaration: `<name> is required (in the JSON body | in the query string | in the JSON body or the query string)`, with a `field` for a machine reader and an optional `note` carrying what the generated sentence cannot know. IT TESTS PRESENCE, NEVER LENGTH: `{\"value\":\"\"}` is a value (the deliberate clear) and `{}` is no answer - the four-states rule, SM784, caught while building this. Eight actions marked so far; the set grows by evidence. t/unit/manager/10 asserts the absent case, the sent-to-the-other-channel case, the empty case reaching the action, and an unmarked action untouched."
---

# What the field saw

```
POST ?action=connector-delete&id=probe
-> {"ok":false,"error":"connector id must be a-z, 0-9, - or _"}
```

`probe` is valid; it was in the query and the action reads the body. The
message sends the reader to fix the value when the fault is the location.
The same shape cost time twice on `theme-copy` (`path` meaning something
else; `new_name` in the query).

# What is done

The connector actions say `id is required (send it in the JSON body)` when
the id is absent (SM772's branch). That is one feature's fix.

# What was built

`Lazysite::ControlApi::Actions` already declared every action's parameters
with `in => 'body' | 'query' | 'query_or_body'`. Those declarations now
carry `required => 1`, and the dispatcher answers an absent one **before
the branch runs**, in a sentence generated from the declaration:

    id is required (in the JSON body)
    key is required (in the JSON body or the query string)
    value is required (in the JSON body; an empty string clears the start page)

with `field` for a machine reader and an optional `note` for what the
generated sentence cannot know. One check, written once, on both channels
(the cookie dispatch runs through the same point).

**Marked by reading the handler, never by guessing.** A parameter is marked
`required` only where the action ALREADY refuses an absent value, so
hoisting the check changes the message and never the behaviour. Eight
actions are marked (brief-append, brief-read, config-set,
connector-secret-set, connector-delete, start-page-set, theme-copy,
site-backup-delete - the ones the field has actually been bitten by); the
set grows by evidence. **An unmarked parameter is not "optional"** - it is
one nobody has established either way, and it reaches the branch as before.

**It tests presence, never length.** The first implementation tested
`length`, which broke `start-page-set`'s deliberate clear: `{"value":""}`
is a value and `{}` is no answer. That is the release manager's four-states
rule (SM784), caught inside the change that exists to prevent the same
collapse - `exists`, not truthiness.
