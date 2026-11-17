---
id: SM1469
title: "SM1469: a form field can be hidden or read-only"
subtitle: "The form grammar has no hidden and no read-only field type, so a form cannot carry a value the page sets - a campaign, a product, a reference - except as a field the visitor can see and change."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the release manager"
area: forms
status-note: "CANDIDATE, filed 2026-11-17. Nothing built. Target 0.17.x edge. Questions for a ruling below; SM923 (sections, n856) is in the same grammar."
---

# What the grammar has

A field's rules are `required optional email textarea select: radio: checklist: checklist-qty:
max: min: value: prefill: pattern: type: file accept: multiple capture placeholder`
(lazysite-processor/forms.pm, the rule loop near line 336). `type:` accepts `tel date time number
url password` and nothing else. `value:` sets a literal default and `prefill:` takes a value from
an allowlisted query parameter (`query_params:`), but both render as an ordinary visible,
editable input.

The only hidden inputs a form carries are the engine's own: the form token and `_page`.

# What it costs

A page that must send a fixed or page-set value with a submission - which campaign or product
the form is about, a reference from the link the visitor followed - has two choices today: show
it as a field the visitor can edit, or add it by a script over the rendered form. The first
clutters the form and invites edits; the second is the per-site script this grammar exists to
avoid.

# The requests

R1
: `type:hidden` - rendered as `<input type="hidden">` with its `value:` or `prefill:` value; it
  reaches the handler as any field does, and appears in the submission like any other.

R2
: `readonly` - a visible field the visitor cannot change in the browser (`readonly` attribute),
  for a value the visitor should see but not edit.

# What a build must keep true

- A hidden or read-only value is still what the visitor's browser sends: either can be altered
  by anyone who edits the request. Neither is a trust elevation, as the prefill comment in
  forms.pm already says of prefill. The docs must say so, and a handler must never treat such a
  field as proof of anything.
- validate_page and its marked copies (Lazysite::Validate::form_rule_tokens and
  form_value_rule_known, held by t/lint/276) know the new rule, or a valid page is warned about.

# Questions for a ruling

1. For a value that must not be altered (a price, a product the handler acts on), should the
   engine also offer a server-side form: a value the handler sets from the page's declaration,
   never sent through the browser, or a hidden field signed with the form secret and refused when
   changed? Either is a larger change than R1 and R2.
2. Should a `readonly` value the server can check (it came from `value:`) be refused when it
   arrives changed, or only rendered read-only?
