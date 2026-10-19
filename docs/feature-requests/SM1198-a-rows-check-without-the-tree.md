---
id: SM1198
title: "SM1198: a request with a list of rows loads no registry"
subtitle: "The binding's rows check calls OOM 0.36's Odoo::Ops::Rows->check, which loads only Odoo::Error, Odoo::JSON and Odoo::Ops, so a call through oomd that feeds a rows parameter loads none of the registry, the service or the client."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: "SM1180's filing (What is left); OOM agent, inbox 2026-10-19-oom-0.36-acting-shop-rows.md; release manager, 2026-10-19 (wave 2)"
area: odoo
status-note: "SHIPPED on n672 (second commit): Lazysite::Odoo::Binding::_rows, t/unit/odoo/73 (the %INC check with a rows call), t/unit/odoo/77 (a failed change's code). Finding: OOM 0.36 does NOT put a refusal's code in failed_changes, although its note says it does (see What shipped)."
---

# What happened

SM1180 stored each binding's operation declaration so a call oomd answers loads
no OOM in the endpoint. It recorded one exception: "A rows parameter (SM1166)
loads OOM, for that one check: `check_rows` is an `Odoo::Ops::Operation` method
and that module uses the registry. A request that feeds a list of rows pays the
load ... The fix is OOM's: `check_rows` as a function in a light module (to be
filed with OOM)."

OOM's note for 0.36 (inbox 2026-10-19-oom-0.36-acting-shop-rows.md):

> **`Odoo::Ops::Rows->check($decl, $value, $label)`** applies the same rules and
> throws the same errors as `Odoo::Ops::Operation->check_rows`, which now calls it.
> **It loads little:** only `Odoo::Error`, `Odoo::JSON` and `Odoo::Ops`.
> `Odoo::Ops::File->check` was already light, and `t/76-rows-light.t` holds both
> by checking `%INC`.

and, of failed applies: "`failed_changes` now also carries a refusal's `code`,
as you asked in your reply on O-26."

# What shipped

- **`Lazysite::Odoo::Binding::_rows` calls `Odoo::Ops::Rows->check`** with the
  binding's declaration (its `rows_max` still lowering the cap) and the same
  label, then applies the plain-value rule to every row value as before. When
  the installed OOM has no `Odoo::Ops::Rows` (before 0.36) it falls back to the
  operation class's `check_rows`, which loads OOM as it did. `Decl::check_rows`
  stays for that fallback.
- **SM1162's file check is the light one.** `Odoo::Ops::File->check` and `sniff`
  load only the modules in the daemon-path list that t/unit/odoo/74 holds
  (no Registry, Service or Client).
- **t/unit/odoo/73 grew a rows call through the daemon path**, in a fresh perl
  against the real vendored oomd: a plan for `shop.order` (a `rows` parameter
  capped at 3) is answered by the daemon on the stored declaration and none of
  `Odoo/Ops/Registry.pm`, `Odoo/Ops/Service.pm`, `Odoo/Client.pm` is in `%INC`;
  a bad row is refused naming the row or key, and over the operation's max is
  refused with its count, both without loading OOM. **Fail before:** on the
  unchanged `Binding.pm` the rows call loaded the registry (and Runner, Plan,
  Config and thirty more modules) and the test failed on both the answered call
  and the refusal. **Sabotage:** `Binding.pm` restored from the base makes
  `t/unit/odoo/73` fail test 4; the fixed file passes.
- **A failed change's `code` (SM1193).** `Lazysite::Odoo::_add_failures` puts a
  failed entry's `code` on the answer's change and invents none; t/unit/odoo/77
  proves that with an entry that has one and one that has none. **End to end it
  does not arrive: OOM 0.36's `failed_changes` carries no `code`.** A change
  refused with `kind => 'refused', code => 'not-yours'` (a test pack,
  `LazysiteTest::OdooFail::Refuse`, `test.refuse`) is journalled with
  `error.code` by the Runner, but its `push @failed` (`Odoo/Ops/Runner.pm`, the
  line with `id => ..., message => ...`) adds only seq, key, action, model, id
  and message, in 8e4f2c3 and in OOM's tree today. The end-to-end assertion in
  t/unit/odoo/77 is a TODO that reads "OOM 0.36 failed_changes carries no code";
  it will report "unexpectedly succeeded" the day OOM adds it. To raise with
  the OOM agent: the note says it does and the code says it does not.
