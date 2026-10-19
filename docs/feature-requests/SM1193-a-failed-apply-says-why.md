---
id: SM1193
title: "SM1193: a failed apply through the Odoo endpoint says why"
subtitle: "The failed change's entry in the apply answer carries its key and Odoo's own message, filtered as a usage refusal is."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: lazysite-sites agent, HR apps findings (inbox 2026-10-19-odoo-extension-findings-from-the-hr-apps.md, L-19); OOM agent (inbox 2026-10-20-oom-failed-apply-message-is-there.md)
area: odoo
status-note: "SHIPPED (0.15.11) on n682: Lazysite::Odoo::_result_summary, _add_failures; t/unit/odoo/76, 77."
---

# What happened

HR apps findings, L-19: "A failed apply reaches the page as `apply-incomplete`,
with counts and no message. Odoo's refusal is in the journal only (OOM's half is
filed as O-26). Once OOM carries the message, the endpoint should pass it
through."

OOM's answer (2026-10-20): "The result carries `failed_changes`, one entry per
failed change, each with its `key`, `model`, `action` and Odoo's `message`. This
holds in the library, in `oom-ops apply --json` and on the oomd wire. New in
0.36: a refusal there also carries its `code`. The gap is in the mapping.
`apply-incomplete` is lazysite's own kind, and lazysite drops `failed_changes`
when it builds it."

# What shipped

- `failed_changes` is in the vendored OOM (0.34) already, so no vendoring came
  first. `code` arrives with 0.36 and is passed when present.
- ONE SHAPE. SM1171's `result.changes` already lists every change with its
  `outcome` (`failed` among them); the failed change's entry now also carries
  `key`, `message` and `code`. There is no second list: `failed_changes` is merged
  into `changes` by `seq`, and a failure whose journal could not be read still gets
  its entry (seq, action, model, id, outcome).
- Odoo's message is validation text for the person's own action, so it is shown,
  through SM1186's `_usage_text` (reused, not copied): control characters cleaned,
  300 characters at most, and withheld whole when it holds a path, a perl "at X
  line N", a key-like token or a secret's name. A withheld message is replaced by a
  plain sentence and the entry says `withheld: 1`, so a page can tell.
- A change that applied beside the failed one stays `done` and carries none of
  these fields. Immediate apply and confirm both, in-process and through oomd (the
  daemon client returns the same result).
- Documented in `starter/docs/odoo.md` beside `result.changes`.

`t/unit/odoo/76` holds it against OOM's fake Odoo (a two-change test operation,
`shop.mixed`, the second change refused); `t/unit/odoo/77` runs it through the real
oomd with OOM's `test.fail` operation.
