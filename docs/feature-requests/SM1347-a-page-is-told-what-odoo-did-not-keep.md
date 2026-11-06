---
id: SM1347
title: "SM1347: a page is told what Odoo did not keep, and why a record was refused"
subtitle: "A change Odoo did not keep as asked names its fields on the page, never the values; a record the account may not read, and one that is gone, each have their own sentence."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "rulings 103 and 104 (Q35, Q36), on SM1346's two findings"
area: odoo
status-note: "SHIPPED (0.16.5) on n751: _applied_changes passes each change's not_kept fields and a note, _result_summary passes not_verified, %REFUSED_KIND says access and missing; the browser helper draws the notes into [data-ls-odoo-not-kept]. Wording is through one `said` in Lazysite::Odoo, plain \"Odoo\" until SM1328 is stacked."
---

# What happened

Vendoring OOM 0.44 ([[SM1346]]) found two things a page could not tell:

- **A write Odoo did not keep reads `done`.** From 0.44 OOM compares each field a
  write asked for with Odoo's record afterwards. A value Odoo dropped or reset in
  the same write leaves the change `done`, counts it in `not_verified`, and names it
  in the journal's `not_held` with the value asked and the value found. lazysite
  passed none of this.
- **`refused/access` and `refused/missing` said "the call was refused before Odoo
  answered".** OOM 0.43 tells a record the account may not read from one that does
  not exist. lazysite answered both with the generic sentence, which is wrong for
  both: Odoo did answer.

The release manager ruled on 2026-11-05:

- **103:** a page is told a change was not kept (`not_verified`) and which fields
  Odoo did not keep. It is never told the asked or found values; the rule that a
  change's values are never passed stands.
- **104:** `refused/access` and `refused/missing` each get their own sentence,
  named with the site's name for Odoo.

# What shipped

- **Each change Odoo did not keep says so.** `_applied_changes` reads the journal
  entry's `not_held` and gives the change's entry `not_kept`, the field names, and
  `note`, "Odoo did not keep this change as asked: name". Only names that are Odoo
  field names are passed; the values are never read out of `not_held`. One reader,
  so an immediate apply, a confirm, a resume's carried changes and the oomd path
  all answer the same.
- **`result.not_verified` is passed** by `_result_summary`, and is 0 on the empty
  results. It is OOM's count: the done changes no read-back confirmed. That is these
  changes, and those OOM does not read back (a call, a delete). So a page asks
  `not_kept`, not the count, whether Odoo dropped a value.
- **`access` and `missing` have their own lines in `%REFUSED_KIND`**: "Odoo refused:
  this account may not do that" and "that record no longer exists in Odoo". The kind
  stays `refused`, so a page that handles it is unchanged. OOM's text stays in the
  log.
- **The browser helper draws it.** `lazysite-odoo.js` draws each change's `note`, as
  text, into a `<div data-ls-odoo-not-kept>`, if the page has one, after `write()`,
  `confirm()` and a resume settled from the unknown slot. The slot's
  `data-ls-odoo-state` is `not-kept` or `kept`. A resume settled from the unknown
  slot also adds the notes under "Done.". `notKept(data)` and
  `showNotKept(node, data)` let a page draw them itself.
- **One wording call.** Both texts go through `said( $named, $plain )` in
  `Lazysite::Odoo`, read by `_kind_said` for the kind tables. Here `said` puts
  "Odoo" for `{name}`. SM1328 (n744) has the same `said` and `_kind_said`, with
  `said` reading `odoo_display_name` through `Lazysite::Odoo::Name`. Stacked, keep
  n744's two subs and drop these. The new texts then follow the site's name
  unchanged: each is written with `{name}` and without it.
- **The Odoo doc** (`starter/lazysite/templates/docs/odoo.md`) describes
  `not_kept`, `note`, `not_verified` and the slot, and the `refused` row names the
  two codes.

# Tests

- `t/unit/odoo/122-a-write-odoo-did-not-keep-says-which-fields.t`: on OOM's fake
  Odoo told to drop `x.product.name` (`drop_writes`), an immediate apply, a confirm
  and a resumed unknown run each answer the change `done` with `not_kept ['name']`,
  the note and `not_verified` >= 1. The asked and found values never appear in the
  answer. A change Odoo kept carries none of it, and `not_verified` is 0.
- `t/unit/odoo/123-a-record-not-readable-and-a-record-gone-are-each-said.t`: each
  code answers kind `refused` and its own sentence, with OOM's text only in the log.
  Another code keeps the generic sentence. A read binding refused `access` answers
  its sentence end to end.
- `t/unit/odoo/124-the-browser-helper-shows-a-write-odoo-did-not-keep.t`, with
  `t/lib/odoo-not-kept-harness.js`, under node: write, confirm and a settled resume
  draw the note; a kept write draws `kept`; a note that is markup is text; a page
  with no slot is answered as before.

Sabotage, each fix reverted alone:

- Without the `_add_not_kept` call, 122 fails.
- Without `not_verified` in the summary, 122 fails.
- Without the two `%REFUSED_KIND` lines, 123 fails.
- Without the helper's drawing, 124 fails.

# Not done

- **The oomd path has no test of its own.** It reads the daemon run's journal
  through the same `_applied_changes`. The daemon test runs its own fake Odoo, in
  another process, which this test cannot tell to drop a field.
