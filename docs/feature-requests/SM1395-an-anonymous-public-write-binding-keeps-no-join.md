---
id: SM1395
title: "SM1395: an anonymous public write binding keeps no join"
subtitle: "Ruling 154: a public, immediate write binding kept the parameters and the owner hash in the plan store and the IP and the same hash on every call line - the hash was the join. The binding setting anonymous: 1 leaves the parameters out of the records once applied and the address and the hash off the call line."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager (ruling 154), 0.16.8 wave 1"
area: odoo
status-note: "SHIPPED (PENDING) on n771: Odoo::Binding::parse takes anonymous (public bindings only); Odoo.pm writes the call line and its audit row without ip and visitor (_rec_base, _anon_rec) and nulls the values of a spent plan's records (_redact_spent_plan: plan, run, result, journal, the daemon's run folder too); the rate cap counts by the hash as before. t/unit/odoo/136; SECURITY.md entry drafted."
---

# What happened

A binding with `modes: public`, `apply: immediate` and a write operation kept
two records that together tied what a visitor sent to where it came from. The
plan store (`lazysite/odoo/plans/<id>/plan.json`, `run.json`, `meta.json`, the
journal) held the parameters and the owner `visitor:<hash>` until the plan was
spent and its retention ended; the call record (`lazysite/odoo/calls.jsonl`,
90 days) held the IP address and the same hash on every line, and the shared
audit row the address again. The hash was the join. Ruling 154 asked for a
binding that keeps none of it.

# What was built

- `Lazysite::Odoo::Binding::parse`: `anonymous` (`1`/`0`, the usual spellings),
  stored on the binding; refused unless `public` is in `modes`, naming why; a
  value that is neither is refused. A field on the Handlers page's binding
  form (`Lazysite::Handlers` schema), so the manager offers it.
- `Lazysite::Odoo::_rec_base`: an anonymous binding's record carries no
  `visitor` and no `ip`; the audit row (`_audit_line`) reads the same record,
  so it carries no address. `_anon_rec` applies the same to a record built
  before its binding is known - a confirm's expired refusal, a withdraw's, a
  resume's early refusals - by looking the binding up from the plan's meta.
- `_redact_spent_plan`: once the plan is spent, every value under `params`,
  `vals`, `before`, `after` and `values` in `plan.json`, `run.json`,
  `result.json` and the journal - in the plan folder and, for a plan the daemon
  made, its run folder - is set to null; the keys (the field names), the
  fingerprint, the counts, the ids made and the journal's outcomes stay.
  Called where the plan is spent: an immediate apply in `call` as it answers; a
  confirm when `_plan_spent` says so (beside `purge_plan_blobs`); a resume's
  settled run and its spent resumed plan; a withdraw; a dismissal. A plan
  waiting for its confirm keeps its parameters, which the confirm applies.
- The per-visitor rate cap is untouched: `_take_cap` counts by the hash in
  `recent.jsonl`, a rolling hour's counter that no call line now joins to. An
  `Idempotency-Key` still works: it is hashed with its scope (SM1223) and the
  key OOM holds stays on the line.
- `meta.json` keeps the owner `visitor:<hash>`, so a plan is still confirmed
  by its maker and nobody else; with the parameters gone and no address
  anywhere, it is joined to nothing a person sent.
- `/docs/odoo`: the setting under *Bindings*, a line under *The anonymous
  write path* and one under *The call record*. SECURITY.md: an entry drafted
  for the release manager's confirmation (less processing of personal data; no
  ADR 0007 trigger).

Out of scope: the extension hooks (n768-n770); this touches Odoo.pm's record
writers and the binding parser only.

Test: `t/unit/odoo/136` - after an anonymous immediate apply the call line and
the audit row carry no address and no hash; the plan, run and journal records
hold no parameter value and keep their names, fingerprint and outcomes; the
setting is refused on a non-public binding and for an unreadable value; the
per-visitor cap still trips and is counted by the hash; a confirmed plan keeps
its parameters until the confirm and loses them after; a binding without the
setting records as before. Fails with the setting reverted (the binding cannot
be saved) and with the record writers reverted (the lines carry both and the
records keep their values).
