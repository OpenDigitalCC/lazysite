---
id: SM1166
title: "SM1166: a binding takes a declared list of rows (a quotation's lines)"
subtitle: "A request may fill a parameter the operation declares as a list of small rows of plain values, with a cap; each value is checked as a plain value is today. Never a domain."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent, OOM Lab quotation app (inbox, L-11)
area: odoo
status-note: "SHIPPED on n658 (base n648, OOM 0.32): Lazysite::Odoo::Binding feeds a declared rows parameter, checked by OOM's check_rows and the plain-value rule; test t/unit/odoo/51. R1 and R2 as ruled 2026-10-18."
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

# What OOM shipped

OOM 0.32 (inbox 2026-10-18-oom-0.32-rows-inline-reports-repeat-safe.md, "Rows
parameters"):

> An operation may declare a parameter of type `rows`. `describe --json`
> prints it in the parameter's entry: `"lines": { "type": "rows", "max": 50,
> "required": 1, "row": { "product_id": "int", "qty": "int", "discount":
> "int?" } }`
>
> - **Row fields** are `str`, `int` or `bool`. A trailing `?` marks a field
>   optional. `max` is always present.
> - **The value** is a JSON array of flat objects. Through the daemon or the
>   library, it is an array of hashes.
> - **OOM's check, before anything else.** It refuses as `usage`, naming the
>   row number and the key: more than `max` rows; a key that is not declared;
>   a missing required key; a value of the wrong type; any nesting. A `str`
>   in a row is at most 4,096 characters, with no control characters.
> - **The same rule for you:**
>   `Odoo::Ops::Operation->check_rows($decl, $value, $label)`. Call it before
>   sending if you want the refusal on your side too.
> - **A declaration whose `row` is a string, not a hash, cannot be checked
>   statically.** `core.make`'s `lines.<field>` is the case. Treat such a
>   parameter as operator-only, or pass it and let OOM's plan refuse it.

# What shipped

- `Lazysite::Odoo::Binding::check_against` lets a request feed a parameter
  whose declared type is `rows` (R1: any binding, public visitor or signed-in).
  The `%FROM_INPUT` rule is unchanged for every other type: `json`, `list` and
  `path` stay the operator's alone.
- R2, caught when the binding is saved (and again at the call, which runs the
  same check): a `rows` parameter with no `max` is refused naming the
  parameter. A `rows` whose `row` is a string, not a hash (`core.make`'s
  `lines.<field>`), is operator-only: a binding mapping a request field into
  it is refused naming the parameter and why. The operator may still `fixed:`
  either.
- At the call, before anything reaches Odoo, `assemble` takes the request's
  value, which must be an array, through `Odoo::Ops::Operation->check_rows`
  (count, keys, types, nesting) and then the existing plain-value rule on each
  value (1,000 characters, no control character; the rule is now one function,
  `_plain_problem`, used for single values and row values alike). Any failure
  refuses the whole call as `invalid`, naming the row and the key. The rows
  reach the operation as an array of hashes.
- The binding syntax is flat keys, so the per-binding cap is one more key,
  `rows_max` (a whole number, offered in the Handlers form): it applies to
  every rows parameter the binding feeds and can only lower the operation's
  own `max`.
- The JSON body already carries `params` as an object: the 400 "params must be
  an object" path is unchanged, and a nested value is accepted only for a
  rows parameter (any other mapped field still says "must be a single value").
  A form posts text and a query string is text, so neither can carry a list:
  rows are for the JSON endpoint and the control API.
- `starter/docs/odoo.md` describes it beside `params`. A rows parameter is not
  drawn as a form field (`Lazysite::Odoo::Fields` skips types it has no
  portable type for).
- The plugin's dependency floor is unchanged: a rows parameter exists only
  where OOM 0.32 declares one, and only then does the check run.

# Evidence

`t/unit/odoo/51-a-binding-takes-a-declared-list-of-rows.t`, on OOM's fake
Odoo, with three new test operations (`t/lib/LazysiteTest/OdooOps/`: Order,
a capped write; Nomax; Dyn). Before the change the first binding is refused at
save ("a request may feed only a plain value"). Sabotage: the unchanged
Binding.pm fails the file; with only the plain-value loop removed the
over-1,000-character row value passes and the test fails; with only
`check_rows` removed the cap and key tests fail.
