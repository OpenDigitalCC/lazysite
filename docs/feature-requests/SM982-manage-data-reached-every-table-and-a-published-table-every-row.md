---
id: SM982
title: "SM982: manage_data reached every table, and a published table every row"
subtitle: "A table's own read and write rules did not bind a holder of manage_data, and publishing a table published every row in it. The rules now bind it (the operator is unaffected), and a table may name the rows its visitor surfaces show."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox, 2026-10-11-a-manage-data-holder-reaches-every-table-and-a-published-table-is-public-to-the-last-row.md (a members' area on a local 0.15.3 site)
area: security
status-note: "SHIPPED (0.15.5): ruled 2026-10-11, Table ACLs bind it + row filter. Manager::Data::table_rule_refusal asks the table's read or write rule of every non-operator on every row read and write (manager, API, MCP, data endpoint); a descriptor's `where: field = value` / `field != value` is applied to page bindings and the data endpoint. t/integration/127."
---

# What was wrong

Reported, four measured behaviours (the fourth - a read ACL naming only @sysops
blinding a page that renders the table - is the rule working: a page is never
the operator):

1. A member holding `manage_data` changed rows in `categories` and `people`,
   whose write rules did not list them.
2. The same member read, through the control API, a table whose read rule
   excluded them.
3. A table published for page bindings served every row - rows a moderator had
   marked hidden or spam included - to an anonymous request at the data
   endpoint.

## Root cause

- **Reads**: every row read in `lib/Lazysite/Manager/Data.pm`
  (`action_data_rows`, and the downloads beside it) called `read_rows(...,
  as => 'operator')`, and `Lazysite::Data::Access::may_read` answers `'operator'`
  with 1 before looking at any rule - "every action in this module has already
  passed the manage_data gate". So the capability decided, and the table's read
  rule was never asked for a `manage_data` holder on the manager, the API or MCP.
- **Writes**: nothing asked a table's WRITE rule at all. `row_write_refusal`
  applies the descriptor's `writable_by` and the capability; the ACL store's
  `write` list for `lazysite/db/tables/<name>` had a setter
  (`data-table-acl-set`) and no reader.
- **Rows**: publication (`public: true`) is a property of the whole table; there
  was no way to hold back a row.

Reproduced on main (41967751): t/integration/127 run against main fails 33
assertions (`tmp/sec-evidence/sm982-t127.main.out`): the member's row write,
delete, read and download all succeed, and the hidden and spam rows are served
by the endpoint and rendered by a page binding.

# The ruling

Release manager, 2026-10-11, "Table ACLs bind it + row filter":

a table's read and write permissions apply to manage_data holders too (operator
unaffected); published tables gain an optional row condition (e.g. `where:
status = ok`, a simple equality/inequality on a declared field - keep the grammar
minimal and safe, no expressions) applied at the data endpoint and to page
bindings, so hidden rows stay hidden. Docs (data-tables) updated.

# The fix

## The table's rule binds manage_data

`Manager::Data::table_rule_refusal($table, $mode)` asks the table's ACL
(`_acl_allows` on `lazysite/db/tables/<name>`, longest prefix and the site-wide
rule included, as for a file) with the caller's account and its own groups
(`groups_for`, from the store). The **operator** - `_is_operator`: `local`, an
unsecured site, a cookie session holding `manage_users` - is not asked; a token
never is the operator. A table with no rule refuses nobody.

| Action | Rule asked |
| --- | --- |
| data-rows (MCP read_data_rows), data-export, data-safety-export-read | read |
| data-row-save, data-row-delete (MCP save/delete_data_row, the data endpoint), data-import, data-safety-export-restore, data-rebuild, data-table-drop | write |

The data endpoint asks the write rule itself as well, so its refusal is a 403
like its other refusals. Its reads already asked the read rule (`may_read` with
the visitor's identity) and are unchanged. Declaring, migrating and reading a
table's descriptor are schema work and stay `manage_data`'s; the table-rule verbs
keep their own owner check.

## A row condition

A descriptor may carry `where: <field> = <value>` or `where: <field> != <value>`
(`Data::Descriptor::_check_where`): one comparison on a declared field, the value
read as that field's type reads a row value (an enum's value must be one of its
values; a boolean is yes/no). Anything else - another operator, `AND`/`OR`, an
undeclared field, no value - is refused when the descriptor loads, with
`rule => 'where'`. `resolve_binding` (`Data::Tables`), which page bindings and the
data endpoint both go through, passes it to the SQL builder (`Data::SQLite::
_where`), which ANDs it with the binding's own filters as a bound parameter -
the count included, so `.count` and the endpoint's `total` count only what is
shown, and `.field` by a hidden row's key answers nothing. `!=` shows a row whose
field is empty (`col IS NULL OR col <> ?`): an unmarked row has not been hidden.
The manager, the control API and MCP read every row - the surfaces a moderator
uses to find the hidden ones.

# Behaviour changes

- A `manage_data` holder that a table's read rule excludes no longer reads its
  rows (manager, API, MCP downloads included), and one its write rule excludes no
  longer writes, deletes, imports, restores, rebuilds or drops it. A site-wide
  rule (`/`) reaches tables as it reaches files, so a write rule there now binds
  `manage_data` holders' row writes too. `write_data` holders are bound by a
  table's write rule as well (it narrows, as `writable_by` does).
- New descriptor key `where:`.

# Evidence

t/integration/127 (the reported writes and reads over the cookie API, MCP and the
data endpoint; the named writers and the operator still reach; the condition at
the endpoint and in a page binding, `=` and `!=`, the count, `.field`; the
grammar). 33 assertions fail on main. Sabotage: 16 cases (`sm982-sab*.out`), each
bit; the declared-field check first did not (the type check refused the same
values) and the test now asserts the refusal by name.
