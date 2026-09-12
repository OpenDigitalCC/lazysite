---
id: SM856
title: "SM856: a native form field cannot carry a value, so a code the URL already holds has to be retyped"
subtitle: "`query_params:` puts a URL value on the page, escaped, and a page can print it, branch on it, head a section with it. The form renderer emits no `value` attribute and has no rule that would set one - so the single place the value is needed is the one place it cannot go. One field rule, gated by the allowlist that already exists."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-11
raised-by: site agent
area: forms
---

# What was measured

Read from `lazysite-processor.pl` on the 0.13 line and re-checked here.
`_render_form` parses `name | label | rules` and emits, for a text input,
`type`, `name`/`id`, `maxlength` or `min`/`max`, `pattern`, `placeholder` and
`required`. There is no `value`, and no rule that would produce one.
`placeholder` is the near miss and is not a substitute: a placeholder is never
submitted.

The page path travels with a submission (`<input type="hidden" name="_page">`),
but `_page` is a protocol key the handler reads to validate a same-site redirect
and then strips. It never reaches the store. So no route exists, direct or
indirect, from a URL value to a stored submission field.

# The use case

Ten registration codes handed out at an expo, each a QR to its own unguessable
page. The applicant scans, fills in the form, and the code must arrive on the
row so the application can be matched to the card. The page knows the code; the
visitor is holding the card; the form cannot be told - so the applicant types
eight characters the URL already carried.

Small at ten. Not small at a thousand, and the shape generalises: a conference
badge link, a per-customer support form, a renewal that should not make somebody
find their account number.

# What is asked for

One field rule, in either or both spellings:

```
code | Your registration code | required max:12 value:"ODX-0000"
code | Your registration code | required max:12 prefill:c
```

- `value:"..."` - a literal default. The smaller half, useful alone.
- `prefill:<param>` - the value of a query parameter, **refused unless that
  parameter is declared in the page's `query_params:`**, with an undeclared
  parameter logged as the author error it is rather than silently rendering
  empty.

# Why the shape is safe, verified rather than assumed

Every control it needs exists and is applied elsewhere:

- **The allowlist is the gate.** `prefill:` can reach nothing `query_params:`
  has not admitted.
- **The escaping exists twice.** `query.*` is escaped at parse time, and into an
  attribute it wants `_esc_attr` - the two-entity escape `placeholder`,
  `pattern` and `accept` already use.
- **The cache question is already answered.** Checked in the processor: a
  request carrying a declared parameter skips the cache (the `$has_query_request`
  branch), so one visitor's value cannot be baked into a shared response. The
  SM389 class of problem does not arise.
- **It is not a trust elevation.** A prefilled value is visitor-controllable
  exactly as it was when they typed it. Nothing downstream may treat it as
  verified, and the documentation must say so in those words.

# The version to refuse, and why it is in this filing

The natural design for the use case is a code box that LOOKS THE CODE UP:

```yaml
tt_page_var:
  voucher: db:codes(code=[% query.c %])
```

This does not work today - binding values pass through `strip_tt_directives()`
and `db:` is never passed through `interpolate_env` - and **it should stay
refused**. That is a visitor steering a query against the site's tables. The
site agent named it unprompted as the thing NOT to build, which is why the
request is shaped as "move an allowlisted value into an attribute" and nothing
more.

# Impact, if it is built

Small and contained. One rule in the field parser, one attribute emitted through
the existing attribute escape, one refusal for an undeclared parameter, a line in
the forms documentation saying a prefilled value proves nothing. Tests: the
attribute renders, a hostile value (`"`, `&`, `<`) is escaped, an undeclared
parameter is refused and logged, and the value arrives in the store when
submitted.

It adds no new input surface: the value is one `query_params:` already admits,
into an attribute the renderer already escapes for three other rules.

# Related

[[SM673]] (the same expo, its other half: the applicant holding their record),
SM389 (per-visitor content and the cache), SM501 / SM401 (the form defences this
does not disturb).
