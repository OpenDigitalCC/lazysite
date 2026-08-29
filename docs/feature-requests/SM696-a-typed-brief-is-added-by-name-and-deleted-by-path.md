---
id: SM696
title: A typed brief is added by name and deleted by path
raised: 2026-08-29
raised-by: edge-testing agent
area: briefs
status: shipped
status-note: "SHIPPED in 0.11.7 as option 1: brief-delete now accepts type/table/key and resolves them through typed_rel, the same function the append uses, so the two verbs cannot hold separate ideas of where an entry lives. The path form is unchanged for callers holding one from briefs-list. The validation matters as much as the convenience - the parts COMPOSE a path, so a delete accepting a slash where the append refuses one would reach entries the append could never have written. ORIGINALLY: `brief-append` takes `type=row&table=NAME&key=KEY`; `brief-delete` refuses that and needs the explicit path as `briefs-list` reports it (`/.typed/row/<table>/<key>`), sent as POST. So an agent that knows exactly which row's brief it wants must LIST first to learn the path it already has the parts of. Either the delete should accept the same three parameters that created the entry, or the asymmetry should be documented where an agent will meet it - the field agent hit it and worked it out, which is one run spent on a round trip."
---

# What was measured

Adding a typed brief:

```
brief-append  type=row  table=sm657test  key=r1     -> ok, stored at
                                                       /.typed/row/sm657test/r1
```

Deleting it:

```
brief-delete  type=row  table=sm657test  key=r1     -> "brief-delete needs an
                                                       explicit path"
brief-delete  path=/.typed/row/sm657test/r1  (POST) -> ok
```

# Why it is worth fixing rather than only documenting

The three parts (`type`, `table`, `key`) are exactly what the path is built
from - `Manager::Briefs` composes `$TYPED_PREFIX/$type/$table/$key` from them,
with both segments validated. So the delete refuses arguments it could resolve
by calling the same function the append uses.

The cost is a round trip an agent should not need: it holds the row's identity,
which is what it used to write the brief, and must ask for a listing to learn a
path it could have derived. On a data-driven site where rows are deleted
constantly - the case SM657 was built for - that is the common path, not an
edge case.

# Two honest options

1. **Accept the same three parameters.** `brief-delete` resolves them through
   the existing key builder, keeping the path form for callers that have one.
   Small, and it makes the verb pair symmetrical.
2. **Document the asymmetry** in the briefs reference and in the tool
   description, so an agent meets the rule before it meets the refusal.

The first is better and cheap; the second should happen regardless, because
even after the fix a caller may hold a path rather than the parts.

# Related

[[SM657]] (typed briefs), and the practice note in the authoring guidance that
now describes `orphan` correctly - the same document should describe how a typed
entry is removed.

# Not started
