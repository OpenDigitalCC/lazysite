---
id: SM1166
title: "SM1166: a binding takes a declared list of rows (a quotation's lines)"
subtitle: "A request may fill a parameter the operation declares as a list of small rows of plain values, with a cap; each value is checked as a plain value is today. Never a domain."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: lazysite-sites agent, OOM Lab quotation app (inbox, L-11)
area: odoo
status-note: "CANDIDATE, ruled 2026-10-18 (R1 yes as proposed, R2 refuse a binding with no cap). Waits for OOM to declare a rows type (asked in odoo/oom/inbox); built when OOM ships it."
---

# The finding

OOM Lab, quotation app, L-11 (lazysite-sites agent, 2026-10-17): "A request
value is a plain value, so a list (a quotation's lines) travels as text the
operation parses ("7:3;11:2:10"). It works, and the operation validates every
part; a declared list-of-records parameter (each item a small object of plain
values, with a cap) would make it ordinary and checkable by the binding
itself."

# The line this crosses

A binding lets a request feed only a parameter the operation declares as a
plain value (str, int, bool) (`Lazysite/Odoo/Binding.pm`). A `json` or
`list` parameter can be fixed by the operator and never fed by a visitor,
because a `json` value can be a domain. That is the parameter-injection line,
and SM1166 must not move it for `json`.

# The proposal

- **OOM declares the shape.** A new parameter type, for example
  `rows`, with the fields of one row (each str, int or bool) and a maximum
  count. Nothing but this declared shape can be fed. Asked of OOM:
  `odoo/oom/inbox/2026-10-18-lazysite-a-declared-rows-parameter.md`.
- **The binding checks it.** A request's JSON body may carry an array for a
  `rows` parameter. Each row is an object holding only the declared fields;
  each value passes the plain-value rule and length limit used today; the
  count is at most the declared cap (and the binding's own, if lower). Any
  other key, any nested value, or one row too many refuses the whole call,
  naming the row and field.
- **`json` and `list` stay operator-only.** A `rows` parameter cannot hold a
  domain because no row value is anything but a plain value.

# Rulings

| Ref | Question | Ruling (release manager, 2026-10-18) |
|---|---|---|
| R1 | Widen what a request may feed to a declared `rows` type | Yes, as proposed: any binding whose operation declares rows, public visitor or signed-in |
| R2 | The default cap when the operation declares none | Refuse the binding: a `rows` parameter must state its cap, caught when the config loads |
