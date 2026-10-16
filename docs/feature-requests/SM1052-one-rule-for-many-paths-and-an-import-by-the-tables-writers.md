---
id: SM1052
title: "SM1052: one rule for many paths, and an import by the table's writers"
subtitle: "acl-set takes a list of paths with one rule, checked whole before anything is written and audited per path; data-import follows writable_by as a row write does, and the table's owner may import past it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-6, P-7)
area: security
status-note: "SHIPPED (0.15.5): acl-set paths list (scope- and carve-out-checked each, validated all before any write, one audit row per path); data-import asks row_write_refusal; the owner of a table's access rule imports past writable_by (t/integration/211)."
---

# The report and the ruling

P-6: bulk-loading a table with `writable_by` - the partner cleared the list,
loaded, and restored it. P-7: 1,745 posts given owner rules one `acl-set` each.

The release manager, 2026-10-12, in their words: "acl-set with a path list,
Import respects writable_by, Owner bypass on import": (a) acl-set accepts a list
of paths with one rule - each path scope-checked (after the P-9 fix), one audit
row per path, all-or-nothing (validate all first, write none if any fails); (b)
data-import is allowed to anyone the table's writable_by names (so the partner
is added to writable_by rather than weakening it) - document it; (c) the
table's OWNER may import past writable_by - define "owner" from the code.

# (a) acl-set with `paths`

- `paths`, a JSON list in the body, 1 to 2,000 non-empty strings, in place of
  `path`; `read`, `write`, `owner` and `draft` carry the one rule as before. A
  request with both `path` and `paths` is refused (`conflict`); a list that is
  not one is `invalid`. Duplicates are written once.
- **Each path is checked as one path is.** The dispatcher's SM1047 resolution
  takes the list (`@ACL_PATHS`) before the scope check, and the scope check and
  the carve-out check iterate it, so one path outside the caller's scope refuses
  the request naming that path.
- **All or nothing.** `_acl_set_many` runs `action_acl_set` on every path with
  `dry_run` - every check a write makes (ownership, the first rule's write
  access, wildcards, blocked paths, names that exist, draft) and nothing written
  - and one refusal refuses the request, kind `refused`, listing each refused
  path with its reason. Only then is each rule written. A write that fails after
  validation (the store, or SM650's partial move) is reported in `results`; the
  ones before it stand, and the reply is `partial`.
- **One audit row per path**, action `acl-set`, target the path, detail what the
  rule was and became (SM465), written by the dispatcher in place of the one row
  a request writes.
- MCP's `set_permissions` is unchanged (one path); the list is the control
  API's.

# (b) An import is a row write

`data-import` asks `Manager::Data::import_write_refusal`, which asks
`row_write_refusal` as a row save does: on a table with `writable_by`, an
account the list names imports and one it does not is refused - `manage_data`
or not. Until now import asked nothing about `writable_by`, while a row save
refused a `manage_data` holder the list did not name: the partner who cleared
the list was working around the row path, and the import would have let any
`manage_data` holder past the list. Documented in /docs/data-tables: add your
group to `writable_by` to load such a table. The gate is unchanged
(`manage_data`): a `write_data` grant still does not import (an import updates
any row, and write_data's own-rows rule, SM857, is the row save's).

# (c) The table's owner

A table has an owner where it has an access rule: `data-table-acl-set` keeps
one under `lazysite/db/tables/<table>` with an `owner` - the account that set
the first rule, or the one the operator named (`action_table_acl_set`). The
descriptor records no creator. So the owner is that rule's `owner`
(`Manager::Data::table_owner`), and a table with no access rule has no owner and
nobody bypasses. The owner may import past `writable_by`; nothing else changes
for it.

# Interaction

The unlanded security stack's SM982 (n387) makes a table's ACL bind
`manage_data` for writes, import among them (`table_rule_refusal`). Both checks
apply when it lands; neither widens the other. Its owner is this owner: the
same rule record.

# Tests

t/integration/211: two paths written with one rule and audited one row each;
one path out of scope refuses the request and writes neither; a path whose rule
another account owns refuses the request (`refused`, naming it) and writes
nothing; path and paths conflict; a non-list and an empty list are invalid. A
`manage_data` holder not in `writable_by` is refused an import and loads
nothing; one in it imports; the table's owner imports past it; another account
is still refused; the descriptor never changes. Sabotage: the scope check
skipping the list, no validation before writing, import ignoring
`writable_by`, no owner bypass - each fails 211.
