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
status-note: "SHIPPED (0.15.5): resolve_binding's own-rows read - (mine), a signed-in viewer and the caller's mine_reads_own opt-in, which only the processor's per-viewer render passes - reads created_by = viewer past may_read; everything else refused as before (t/unit/data/71). SM982's `where:` applies to it too (ruled; t/unit/data/72)."
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

# The row condition (SM982): ruled 2026-10-12

SM982 (P1d, on the security stack n380..n387, not under this one) adds an
optional row condition to published tables (`where: field = value` or
`field != value`). The release manager ruled how the two meet, in these words:
"Apply where: too" - a `(mine)` own-rows read still applies the published
table's row condition, so a moderator-hidden row disappears for its author too.

**The requirement.** The own-rows read is a visitor surface like any other: the
table's `where:` is ANDed into its list, its `_total`, `.count` and `.field`,
and a filter in the binding cannot widen it. A row the condition holds back is
not shown to its author, not counted, and not reached by its key.

**How it is met.** SM982 sets `$opt{condition}` from the descriptor in
resolve_binding, in the one `%opt` every binding reads with, below the read
gate - the own-rows read included; it builds no options of its own. So the two
stacks meet it as they are, with no code here. Checked on this branch by
applying SM982's data-layer change (e8b3dec6: Descriptor.pm, SQLite.pm,
Tables.pm) uncommitted: it applies cleanly, the condition line lands in that
`%opt`, and t/unit/data/72 and 71 pass.

**What binds it.** t/unit/data/72 skips while the tree has no `where:`
(`Descriptor::_check_where` absent) and runs once both are in: ann's own rows
of a table read only by @editors, with `where: status != hidden`, leave out her
hidden row - list, total, count, `.field` by its key, a binding filtering for
`status=hidden`, and a rendered page. Two sabotages over the applied SM982,
each failing all three subtests: the condition line removed, and the condition
dropped for an own-rows read only (`&& !$own_only`). Files restored by cp,
checked by cmp (tmp/sab-bak/P17-where/).

Whoever lands the second of the two stacks re-runs t/unit/data/72: if the
rebase moved the condition out of the shared `%opt`, it fails.

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
