---
id: SM1179
title: "SM1179: the Odoo registry is built once per process and site configuration"
subtitle: "A request that names an operation twice no longer loads every operation module twice."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent (inbox 2026-10-18-odoo-endpoint-builds-the-oom-registry-twice-per-request.md)
area: odoo
status-note: "SHIPPED on n666 (base 4c4798a6c); t/unit/odoo/66-the-operation-registry-is-built-once.t."
---

# What happened

The lab's profile of one scan request (inbox, 18 October 2026):

> `Lazysite::Odoo::operation_class` is called twice, and each call goes
> through `Lazysite::Odoo::registry`, which builds a new `Odoo::Ops::Registry`
> - loading every operation module of every namespace - each time. Measured
> without the profiler, one build is 210-240 ms (`bin/timing.pl`), so about
> 450 ms of every request.

# What shipped

- `Lazysite::Odoo::registry($conn)` keeps the registry it built in `%REGISTRY`,
  keyed on everything that changes what the registry holds: the docroot, the
  namespaces (`odoo_packs`), the pack directories (`odoo_pack_dirs`), the cache
  directory and OOM's version. A config save changes the key; a second site in
  the same process (the pool, the dev server, lazysited) has its own. Every
  caller (`operation_class`, the status report, the binding checks in
  Handlers.pm) goes through `registry()`, so all of them share it.
- The build is the same code as before, inside `with_site_ops` (SM1170): the
  environment is set with `local` only while building. OOM's
  `Runner->apply` still builds its own registry from the environment; that is
  OOM's and is left (the apply path is unchanged).
- The memo holds OOM's operation classes and nothing about a person. t/lint/269
  (the pooled worker's resident set) classifies `%REGISTRY` as exempt, keyed.
- A pack changed on disk under an unchanged configuration is read by a new
  process, not by a running one, as for the other config-keyed caches.
