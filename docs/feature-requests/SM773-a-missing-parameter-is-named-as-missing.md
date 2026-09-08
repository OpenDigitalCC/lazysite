---
id: SM773
title: "SM773: a missing parameter is named as missing, across the control API"
subtitle: "Candidate, from the field's 136E-04 note: connector-delete with the id in the query string answered a charset complaint. The third time in one campaign that a parameter in the wrong place was answered as a wrong value (theme-copy twice before). Every action declares its parameters and where they go; the answer for an absent one should be '<name> is required (in the body)', generated once, from the declaration."
brand: plain
standard-margins: true
status: candidate
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

# What would close the class

`Lazysite::ControlApi::Actions` declares every action's parameters with
`in => 'body' | 'query'`. Add `required => 1` where it is true, and have
the dispatcher answer an absent required parameter before the action runs:
`<name> is required (send it in the JSON body)` / `(in the query string)`.
One check, written once, and no action can answer a missing parameter
with a complaint about its value again. The manager cookie channel's
dispatch would take the same table.
