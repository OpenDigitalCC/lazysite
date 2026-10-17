---
id: SM1148
title: "SM1148: a form whose Odoo change applied with a warning is delivered"
subtitle: "An apply that OOM reports as apply-incomplete after the record was made no longer sends the visitor to outcome=undelivered; the warning goes to the call record and the audit."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (OOM Lab L-3), accepted by the release manager 2026-10-17 ("all rulings accepted")
area: odoo
status-note: "SHIPPED on n641: lib/Lazysite/Handlers.pm _to_odoo; t/unit/odoo/45 (t/lib/OdooIncompleteApply.pm)."
---

# What happened

From the lazysite-sites agent, OOM Lab findings for the Odoo extension, 2026-10-17 (inbox/2026-10-17-oom-lab-findings-for-the-odoo-extension.md), finding L-3:

> A form whose Odoo binding applied but reported `apply-incomplete` (an OOM
> invariant, O-4) sends the visitor to `outcome=undelivered`. The record WAS made,
> so the visitor is told it failed and may send it again, making a duplicate.
> Applied-with-a-warning should not read as not delivered.

`Lazysite::Odoo` marks an apply that OOM does not call `ok` as kind
`apply-incomplete`, and `Handlers::_to_odoo` read any non-ok answer as a failed
delivery, so the form handler refused with `undelivered` (SM1124 made that a code,
and its sentence says the form is not accepting submissions).

# What shipped

`_to_odoo` returns a delivery, `ok` with a `note`, when the answer is
`apply-incomplete`, was applied, and the result shows at least one change done and
none failed and none not attempted: that is the invariant case, where the change
was made and OOM's checks afterwards did not hold. The note is carried by
`Handlers::deliver` to the delivery's audit line (its detail) and to the event log
as a WARN, the engine's call record keeps `kind: apply-incomplete`, and the form
handler answers as for any delivery: `ok`, so the visitor sees the ordinary
acknowledgement and `outcome=ok` in the no-JavaScript redirect. The same holds for
a scheduled run of the binding.

A result in which a change failed or was not attempted is not a delivery and keeps
the refusal; the visitor is told as before. This follows SM1124's scheme: no new
outcome code is added, since the visitor sees success.

t/unit/odoo/45 posts a real form to the real form handler in a child process with
OOM's fake Odoo and an apply whose verdict is set (t/lib/OdooIncompleteApply.pm,
which runs the real apply and changes only the verdict): an invariant failure is
delivered (JSON ok, `outcome=ok`, a call-record line, the audit detail), and a
failed change is still `undelivered`.
