---
id: SM1178
title: "SM1178: a pack operation name may carry a hyphen (crm-page.leads)"
subtitle: "A binding accepts the operation names OOM's packs give, a hyphen inside a part; a leading, trailing or doubled hyphen is still refused."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent (inbox 2026-10-18-a-binding-refuses-oom-pack-operation-names.md)
area: odoo
status-note: "SHIPPED on n665 (base 4c4798a6c): Lazysite::Odoo::Binding's operation pattern admits a hyphen between characters; test t/unit/odoo/71."
---

# What happened

The lazysite-sites agent, 18 October 2026: "OOM 0.32 ships packs from
`/usr/share/odoo-oom/packs/` (package `odoo-oom-packs`), and its first,
`crm-page`, names its operations `crm-page.leads`, `crm-page.lead`, ... The
extension already LISTS them (`odoo-status` shows all seven, from OOM's default
pack directory), but `handler-save` refuses every binding to one: `operation
'crm-page.leads' is not an operation name (dotted, lower case)`.
`Lazysite::Odoo::Binding`, line 35: `qr/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/`
- no hyphen. So a pack can be installed and listed but never bound."

# OOM's rule

Read from the vendored OOM (t/vendor/oom): `Odoo::Ops::Pack` requires a pack
name of lower-case letters, digits and hyphens, starting with a letter
(`/\A[a-z][a-z0-9-]*\z/`, also `Config` and `Registry`); `Registry` requires
every operation of a pack to be named `<pack>.<op>`. OOM puts no pattern on the
rest of an operation name, and core already has a hyphen in its second part
(`stock.link-stranded`). OOM's pack-name pattern would let a hyphen trail or
double; lazysite takes the narrower reading (a hyphen only between characters)
because no shipped name needs more, and widening later is a one-line change.

# What shipped

- `$OP` in `lib/Lazysite/Odoo/Binding.pm` is built from one part pattern,
  `[a-z][a-z0-9_]*(?:-[a-z0-9_]+)*`, joined by dots (two parts or more). The
  refusal message says a hyphen is allowed only inside a part.
- `starter/docs/odoo.md` states the rule under `operation`.
- Test t/unit/odoo/71: a site pack named `shop-page` (under `odoo_pack_dirs`, as
  t/unit/odoo/55 builds one) is bound as `shop-page.names`, saves, and runs on
  OOM's fake Odoo; `-crm.x`, `crm-.x`, `crm.x-`, `crm.-x`, `crm--page.x`,
  `CRM-page.x`, `crm page.x` and a name with no dot are refused.

# Where else the name is used

The operation name is never turned into a file name, URL, query key or regex:
the binding stores it as a value; `Lazysite::Odoo` passes it to OOM's registry
and runner and writes it to audit and log fields as text; plans and the store
are keyed by the binding id (its own pattern, unchanged); the manager's binding
form is a free text field with no client-side pattern. SM1170's `with_site_ops`
sets `ODOO_OPS_NAMESPACES` (Perl namespaces, `Odoo::Pack::CrmPage`) and the pack
directories, neither of which carries the operation name. MCP tool names and the
oomd call carry the name as a string argument. Nothing found that a hyphen
changes.

# Left open

The inbox also asks that `pack_dirs` / `pack` be passable from the site's config;
`odoo_pack_dirs` already is (SM1164), and a `pack` filter is not part of this item.
