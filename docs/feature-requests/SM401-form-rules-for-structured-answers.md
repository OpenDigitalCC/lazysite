---
title: "SM401: form rules for structured answers, and two silent losses"
subtitle: "A field vocabulary that could not express 'which ones, and how many' - so the answer went in a free-text box. Building it found two defects that lost data without saying so: an option containing a comma split in two, and a field submitted twice kept only the last value."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19 from an inbox filing by the jpm-stock-data-corrections workstream: an office team answering ~300 structured questions, one form page per product. NEW RULES: radio:, checklist:, checklist-qty:. FIXED WHILE BUILDING: a comma inside a quoted option split it into two options, silently - the form worked and offered the wrong answers; and parse_post OVERWROTE a repeated field name, so any multi-select would have kept only the last tick. ALREADY WORKED, checked before building and reported back rather than rebuilt: quoted labels containing spaces and brackets, and `number` with min:/max:. BUILT DIFFERENTLY FROM THE ASK: the request was a rate-limit exemption for logged-in users; this handler is not behind the auth wrapper, so the header it would have trusted is client-supplied and exempting on it would leave the limit one header away from useless. A per-form `rate_limit:` ships instead - same outcome for the gated form that prompted the request, and no trust decision about an unverified header. See SM402 for the finding that the same header is already trusted for attribution here."
---

# What was asked for

A gated data-entry interface: an office team answering roughly 300 structured
questions - which production batch was on each delivery - one form page per
product, options carrying per-batch quantities.

The vocabulary was `text`, `email`, `textarea`, `select:`. None of it can say
"which of these, and how many of each", so that answer goes in a free-text box
and someone retypes it later.

# What already worked

Checked first, because rebuilding something that works is worse than not
building it - it looks like a fix and changes nothing:

- **quoted option labels containing spaces and brackets.** `select:"CC1099
  (recorded)","CC1007"` already rendered correctly
- **`number` with `min:` / `max:`.** Already rendered numeric bounds rather
  than a maxlength

Both were reasonably assumed missing. Neither was.

# Two silent losses, found while building

::: widebox
Both defects produced a form that **worked**. It accepted the submission, it
looked well-formed, and it quietly held different data from what the person
entered. Nothing anywhere reported a problem.
:::

An option containing a comma split in two
: The list was `split /,/` with quotes stripped afterwards, so
  `select:"Smith, John","Jones"` offered three choices, two of them wrong. The
  parser now respects quotes. Spaces and brackets never needed them; the comma
  is the case that was broken.

A repeated field name overwrote
: `$form{$k} = $v` in `parse_post`. One name submitted several times is how HTML
  has always expressed a multi-select, and every value but the last was
  discarded. Nothing shipped depended on it - a field submitted once is
  unaffected, and a field submitted twice was losing data.

# The new rules

`radio:A,B,C`
: The same choice as a select, every option visible. On a page of short
  questions answered in sequence a hidden list makes a mis-pick easy and
  silent.

`checklist:A,B`
: Checkboxes; the submission carries every ticked value. **`required` is
  deliberately not applied** - on checkboxes the browser reads it as *this box*,
  so marking them all required would demand every option, the opposite of a
  multi-select. On radio inputs it correctly means one-of, and is applied.

`checklist-qty:A,B`
: Checkboxes with a quantity beside each; the submission reads `A=60; B=40`.

# The quantity travels in the name

`checklist-qty` asks something the flat name/value shape cannot carry. The
alternative to encoding it in the field NAME was to teach the handler the form's
field types - which it does not have and should not: the page defines the form,
the handler receives it. A rule (`field~qty~OPTION`) keeps the handler generic
where a schema would couple it to the page.

A quantity is kept only when its option was actually ticked, so unticking a box
and leaving a number behind - which is what a person does when they change their
mind - does not submit a quantity for something they deselected.

# The rate limit: not built as asked

The filing asked that submissions from a logged-in user bypass the 5-per-hour
IP limit. **That would have been a bypass, not an exemption.**

`form-handler.pl` is not behind the auth wrapper: the shipped templates front
only `lazysite-processor.pl` and `lazysite-manager-api.pl` with it, and
`/cgi-bin/` is otherwise a plain `ScriptAlias`. So `HTTP_X_REMOTE_USER` arrives
at this handler exactly as the client sent it. Exempting on it would leave the
limit one header away from useless.

Instead the ceiling is per form: `rate_limit: 200` raises it, `rate_limit: off`
removes it. An operator setting that on the one gated form they built is
explicit, auditable, and needs no trust decision about a header nobody verified.
It solves the reported problem - an authenticated team on one office address
working through twenty-five pages - without weakening the control on every other
form.

# Verification

`t/unit/processor/48` (22 assertions, the render side) and `t/unit/forms/06`
(19, the handler side), against six sabotages each confirmed to apply and still
compile: making the option split comma-blind; removing the quantity input;
applying `required` to a checkbox group; restoring the overwriting assignment;
accepting any quantity value; and emitting a quantity for an unticked option.

`t/unit/processor/48` also pins one behaviour rather than changing it: an
**unrecognised rule renders a plain text box with no complaint**. That is the
current behaviour, recorded so that changing it is a decision rather than a
surprise.
