---
id: SM687
title: A table's access rule was enforced and unreachable at the same time
raised: 2026-08-29
raised-by: release manager
area: data
status: shipped
status-note: "SHIPPED in 0.11.6. The Data page's 'Who can read' surface returned `Path is blocked` for every table. A table's ACL is keyed `lazysite/db/tables/<table>` and the manager reached it through the generic acl-get/acl-set, which run is_blocked_path - that refuses everything under `lazysite/` outside two carve-outs. The rule was enforced (the data layer reads the store directly) and unreachable (the management surface could not). Fixed with data-table-acl-get/set/remove, which address a TABLE rather than a path; the blocklist is unchanged and still refuses the key to the file editor. The panel is now an expander in the Files page's own style, per the release manager."
---

# What the operator saw

Opening "Who can read" on any data table:

> Path is blocked

# Why

`Lazysite::Data::Access::acl_key` returns `lazysite/db/tables/<table>`, and
`may_read` consults that key through the shared `_acl_allows`. The manager read
and wrote it with the generic `acl-get` / `acl-set`, and those verbs run
`is_blocked_path`, which refuses **everything** under `lazysite/` outside two
carve-outs (`lazysite/forms/submissions/`, `lazysite/layouts/`).

So the rule was **enforced and unreachable at the same time**. The enforcement
side reads the ACL store directly and never consults the blocklist; only the
management surface goes through it. A rule nobody can inspect is worse than no
rule, because the page that cannot show it also cannot show that it is missing.

This was never working. The alert-box version that preceded SM678's panel
called the same refused verb, so the feature was broken from the day it was
added, and SM678 built a panel and then an editor on top of it.

# Why the tests did not catch it

SM678's tests asserted the page: the right key, the right chips, the right
markup, the button gated on the right capability. Every one passed, and none of
them called the API. **A test that reads the page cannot see a refusal that
happens in the verb.**

The standing rule already covers this - prove against the real thing, a source
match is not behaviour - and it was not applied because the change looked like
a UI change. It was a UI change on top of an API that did not work.

# The fix

`data-table-acl-get`, `data-table-acl-set` and `data-table-acl-remove`: verbs
that know they are addressing a **table**, not a path. The key is synthesised
from a validated table name through `Data::Access::acl_key` - the same function
the enforcement side calls - so the surface that sets a rule and the surface
that applies it cannot key it differently. That is the property the new test
pins hardest, because a rule written under a different key is a rule nobody
applies while still looking like protection.

**The blocklist is unchanged.** It guards the generic file editor from the
management tree, and a descriptor is exactly what it should keep out of reach:
writing one through the file editor would bypass the data plugin's own gates,
including SM682's authority check on `writable_by`. The test asserts the key is
still blocked for the file verbs.

What was ported from the file writer, and what was not: the owner rule and the
SM464 read-any split are ported; `draft` is not (it is a property of a
published section); the private-store move is not (a table has no file content
to move - that is SM611's territory).

Gated on `manage_content`, matching a file's rule rather than inventing a
separate policy for tables. Reaching the Data page needs `manage_data`, so in
practice a person holds both.

# The UI, per the release manager

An **expander in the Files page's own style** rather than a modal: the same
chevron, the same `mg-perms-card`, the same `mgRights` chips extracted in
SM678, the same principal picker. An operator who has learned one control has
learned both. The ACL is read when a row is opened rather than with the
listing, so a site with thirty tables does not pay thirty reads to draw a list -
the same argument SM679 made the other way for the row count.

# Related

[[SM678]] (the panel this repairs), [[SM682]] (writable_by, the other half of a
table's access), SM635 (three states: no rule, a rule naming nobody, a rule
naming somebody), [[SM611]] (a table belonging to a site, which would change
what this rule is keyed on).
