---
id: SM1224
title: "SM1224: a rows key's declared max raises its cap"
subtitle: "lazysite held every request value, rows included, to 1,000 characters, so a rows key an operation declares with max 5000 (OOM 0.38) was refused past 1,000 though OOM alone accepts it. A declared max now raises the cap for that key; the body cap follows it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "SM1216's Not done list, ruled by the release manager 2026-10-20 (OOM Lab questions): yes"
area: odoo
status-note: "SHIPPED (0.16.1) on n709: a rows key's declared max (to 1,048,576) is its cap; undeclared keys keep 1,000. A JSON body over 64 KB names its binding in the query and is held to that binding's budget (20 MB ceiling). t/unit/odoo/95."
---

# What happened

[[SM1216]] vendored OOM 0.38, where a rows declaration may give a key its own
`max` (`note => { type => 'str?', max => 20000 }`, at most 1,048,576). lazysite's
rows check runs OOM's `Odoo::Ops::Rows->check` first (which honours the key's
`max`) and then lazysite's plain-value rule on every value (`_plain_problem`,
`$MAX_VALUE` = 1,000). The second check refused what the first had accepted, so a
declared `max` above 1,000 had no effect on a request. SM1216 recorded it as not
done, for the release manager.

# The ruling

"yes" (tmp/rulings-2026-10-20.md, OOM Lab questions): a key's declared `max` raises
lazysite's per-value cap for that key; undeclared keys keep 1,000.

# Where $MAX_VALUE applies

Two places, both in `lib/Lazysite/Odoo/Binding.pm`: the plain-value rule
(`_plain_problem`, line 381 before this change), called for a single request value
in `assemble` and for each row value in `_rows`. A single value (not a rows key) has
no declared `max` of this kind and keeps 1,000. Nothing else holds a length to
`$MAX_VALUE`.

# What shipped

- `key_limit($row, $key)` is the key's declared `max` (never below 1,000, never
  above 1,048,576); `_rows` passes it to the plain-value rule. A key without one
  keeps `$MAX_VALUE`. The refusal says the limit that applied.
- **The body cap.** The endpoint refused a JSON body over 64 KB before it knew the
  binding, so a declared 1 MB value could not arrive. A request over 64 KB now
  names its binding in the query (`?binding=ID`, as a multipart request already
  must), and is held to that binding's budget: 64 KB plus its rows parameters'
  most (rows times each key at its limit, six bytes a character for escapes), never
  above 20 MB (the endpoint's file ceiling). The budget is granted only after the engine's gate (mode, callers, groups, domain, sign-in, switch) and the binding's address rule pass for this caller, decided before the body is read; anyone else stays at 64 KB and is refused 413 unread. The rate caps are taken by the call itself, after the body. A binding whose keys declare nothing
  above 1,000 has budget 64 KB, as before. A body over its budget is refused `413
  too-large` before one byte is read; a batch, a request with no binding in the
  query and a body naming another binding are held to 64 KB. This is the only cap
  raised, and only for bindings whose operations declare the room.
- starter/docs/odoo.md says both.

# Tests

t/unit/odoo/95 (test pack `LazysiteTest::OdooOps::Notes`): a key declared max 5000
accepts 4,000 and 5,000 and refuses 6,000; an undeclared key accepts 1,000 and
refuses 1,001, and so does an operation declaring nothing; the same through
`Binding::_rows` on OOM's light check (SM1198); the budget for a 5000 key, a 200,000
key, a 50-row 1 MB key (the ceiling) and a `rows_max`; a 100,000-character value
reaches the binding that declares it, and is refused 413 to one that does not, with
no binding in the query, with a body naming another binding and as a batch.
