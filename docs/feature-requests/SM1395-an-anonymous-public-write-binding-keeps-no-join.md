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
status-note: "SHIPPED (PENDING) on n771: anonymous on public bindings; no ip or visitor on the call line or audit row; a spent plan loses its values and (ruling 160) the visitor hash; ruling 168, a repeated confirm or withdraw with the same Idempotency-Key gets the first outcome, matched by the plan's scoped key (_spent_repeat). t/unit/odoo/139-138; SECURITY.md entry drafted."
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
- Ruling 160 (second pass): the visitor's hash leaves a spent plan's records
  too. `_redact_spent_plan` also turns every `visitor:<hash>` label to
  `visitor` (`_unhash_visitor`) in `meta.json`'s owner and in OOM's own
  records - `plan.json`'s `actor`, `run.json`'s `planned`, `approval` and
  `applied` `by`, the journal's and `audit.jsonl`'s `actor` - in the plan
  folder and the daemon's run folder. A plan waiting for its confirm keeps
  the hash in its owner, so it is still confirmed by its maker and nobody
  else: the ownership check runs before the apply that spends it. A spent
  plan is nobody's; a later confirm or withdraw is refused as not found, and
  that refusal's line, built once the plan's binding is known, carries no
  hash (`_anon_rec`).
- Ruling 168 (third pass): a spent plan answers its own key. Ruling 160 left a
  spent plan nobody's, so a queue that flushed again - the offline kit's resend
  on an anonymous binding - was told "not found" for a confirm or withdraw that
  had worked. `_spent_repeat`, asked where a confirm or a withdraw would answer
  not found: a request carrying an `Idempotency-Key` on a spent plan of an
  anonymous binding (owner `visitor`) has its key derived as SM1223 derives any
  (`idem_derive`: binding, sender, key) and compared with the plan's own
  idempotency record, `meta.json`'s `idem`. A match gets the first stored outcome
  as SM1223 gives every caller: a confirm, `ok`, `applied`, `repeat` and the
  result from `result.json` (the plan folder's in-process, the daemon's run
  folder's through oomd), already stripped of its values, after the gate and
  within the plan's hour as any confirm; a withdraw, `ok`, `withdrawn`, `repeat`.
  Nothing is sent to Odoo; the line is the binding's (no ip, no visitor) with
  `idem` and `repeat`; no rate count is taken (the counter is by the hash, and
  the not-found it replaces took none). No key, another key, or the key from
  another visitor: not found, as before. The withdraw now takes the endpoint's
  `Idempotency-Key` (`lazysite-odoo.pl`), checked as a confirm's (malformed or
  other than the plan's, refused), and the key a plan's first confirm or withdraw
  carried is kept on a plan made without one (`_keep_idem`), so its repeat is
  matched too.
- `/docs/odoo`: the setting under *Bindings*, a line under *The anonymous
  write path* and one under *The call record*. SECURITY.md: an entry drafted
  for the release manager's confirmation (less processing of personal data; no
  ADR 0007 trigger).

Out of scope: the extension hooks (n768-n770); this touches Odoo.pm's record
writers and the binding parser only.

Test: `t/unit/odoo/139` - after an anonymous immediate apply the call line and
the audit row carry no address and no hash; the plan, run and journal records
hold no parameter value and keep their names, fingerprint and outcomes; the
setting is refused on a non-public binding and for an unreadable value; the
per-visitor cap still trips and is counted by the hash; a confirmed plan keeps
its parameters until the confirm and loses them after; a binding without the
setting records as before. Fails with the setting reverted (the binding cannot
be saved) and with the record writers reverted (the lines carry both and the
records keep their values).

Ruling 160: `t/unit/odoo/139` also checks that the owner keeps the hash until
the confirm, that the maker's confirm still works, that afterwards (and after
an immediate apply) the owner is `visitor` and no file in the plan folder names
the hash, and that a second confirm is not found with no hash on its line.
`t/unit/odoo/137` does the same through the real oomd, for a confirmed plan and
an immediate apply, in the plan folder and in the daemon's run folder (which
names the hash before the confirm). Both fail with the second pass reverted.

Ruling 168: `t/unit/odoo/138` (in-process) - a repeated confirm with the plan's
key gets the first outcome (`repeat`, the same counts, nothing sent to Odoo, no
value in the answer, a bare line carrying the scoped key, no rate count), and no
file in the plan folder, call line or audit row names the hash; without the key,
with another, or from another visitor with the key, not found; a confirm's or a
withdraw's own key on a plan made without one is kept and matched; a withdraw
refuses a malformed key and one other than the plan's, and its repeat with the
key answers `withdrawn`, without it not found. `t/unit/odoo/137` adds the
confirm's repeat through the real oomd, answered from the daemon's run folder.
Both fail with the third pass reverted (every repeat is not found).
