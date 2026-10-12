---
id: SM1003
title: "SM1003: (mine) shows a viewer their own rows of a table they may not otherwise read"
subtitle: "To show a member their own follow list the member had to be able to read the table, which let every member read every row."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11 20:00, correction: members can already own rows, item 1); WORK-PLAN-0154 P17; ruling of 2026-10-12
area: data
status-note: "SHIPPED (PENDING): resolve_binding's own-rows read - (mine), a signed-in viewer and the caller's mine_reads_own opt-in, which only the processor's per-viewer render passes - reads created_by = viewer past may_read; everything else refused as before (t/unit/data/71)."
---

# The ruling

"Allow own rows": `(mine)` returns only rows whose created_by is the signed-in
viewer even when the table's read rule excludes them; anonymous gets nothing;
the data endpoint and listings still follow the rule. SECURITY-sensitive: prove
no other row leaks (other viewers' rows, totals, counts).

# The change

`Lazysite::Data::Tables::resolve_binding` asks `Access::may_read` first, as
before. When the answer is no, the read goes on only as an **own-rows read**,
and only when all three hold:

1. **the caller opted in** with `mine_reads_own => 1`. Only the processor does
   (`resolve_db`, lazysite-processor/sources.pm), and only for a render marked
   per-viewer - a page whose own front matter binds `(mine)`, never cached and
   sent `no-store` (SM857). The data endpoint (lazysite-data.pl) builds its
   binding from table, order_by, order, limit and offset and passes no opt-in;
   the manager, the API and MCP read through other paths. They all still follow
   the rule.
2. **the binding is `(mine)`** - by the shape parse, and again by the
   descriptor parse, which also refuses a table with no `created_by`
   (`mine_needs_timestamps`) and a literal `created_by=` beside `(mine)`.
3. **there is a signed-in viewer.** Anonymous gets the `no_such_table` answer
   any unreadable table gives, before anything is read.

Otherwise the answer is the `no_such_table` refusal it always was.

# What cannot leak

The (mine) branch writes `created_by = <viewer>` into the query's filters, last,
so no filter in the binding can replace it, and SQLite's `_where` ANDs every
filter. Every shape a binding has reads through that one filter: the list, its
`_total` (`count_sql` with the same `where`), `.count` and `.field(column,
<key>=K)`. So another viewer's row, the table's total or count, and a row by a
key the viewer does not own each answer over the viewer's own rows only - the
test asserts each. Rows with an empty `created_by` match nobody.

# Noted for the security stack

SM982 (P1d, on the security agent's stack, not on main) adds an optional row
condition to published tables. When it lands, whether the own-rows read also
applies that condition is a question for its author; this read adds
`created_by` and nothing else.

# Tests

t/unit/data/71: a table readable only by @editors, rows by ann, bob, carol and
nobody. Through the real render: ann sees her two rows, count 2 and total 2,
bob his one; a filter narrows; a binding without (mine), a bare `.count`, bob's
row by key and a table without created_by show her nothing; her own row by key
is hers; anonymous and a forged X-Remote-User see nothing; an editor reads
every row and (mine) is still hers. Directly: without the opt-in (the data
endpoint's call) `follows`, `follows(mine)` and `.count(mine)` are refused as
absent and carry nothing; the opt-in without (mine), or for nobody, is refused;
with both, the rows are the viewer's and the total is theirs; a literal owner
beside (mine) is refused. Six sabotage cases, each failing.
