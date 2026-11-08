---
id: SM1402
title: "SM1402: a notify setting for a form that does not exist is refused"
subtitle: "Triage T-92: set_form_notify and form-notify-save asked only whether the caller reaches the form, and the save wrote lazysite/forms/<name>.conf for any name. A name neither registered nor bound on a page is now refused, naming create_form."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "0.16.7 edge triage, T-92"
area: forms
status-note: "SHIPPED (0.16.8) on n771: Handlers::action_form_notify_save refuses (kind not-found, field form) a name whose conf does not exist and that no page binds (Manager::Common::form_pages), naming create_form; a registered form, and a page-bound form with no conf yet, save as before. t/unit/forms/76; /docs/forms."
---

# What happened

`set_form_notify` (MCP) and `form-notify-save` (control API) gate on
`manage_forms` and on whether the caller reaches the form (its domain), and
`Lazysite::Handlers::action_form_notify_save` then read the form's conf the
SM766 way - absent is empty - and wrote it back with one `notify:` line. So a
call for a name nobody had made wrote `lazysite/forms/<name>.conf` holding
`notify: off` and answered `ok`, with an `announces` report for a form that did
not exist.

# What was built

- `action_form_notify_save`: when `lazysite/forms/<name>.conf` does not exist
  and no page binds the name (`Manager::Common::form_pages`, the walk the
  manager already makes for a form's pages: `form: NAME` in a page's front
  matter, in the docroot or the private store), the call is refused with
  `kind: not-found`, `field: form`, naming the form and `create_form`. Nothing
  is written.
- A registered form (its conf exists) saves as before. A form a page binds
  whose conf is not there yet is a form - the processor renders it from the
  page - and its conf is made as before.
- `/docs/forms` says the form must exist and names the refusal.

The same reach check the two doors already make is untouched; this is the
existence check they did not make. `form-targets-save` and `form-uploads-save`
are not in the triage row and are unchanged.

Test: `t/unit/forms/76` - the ghost is refused naming `create_form` and no file
is written; the registered form saves; the page-bound form saves and its conf
is made. Fails with the check reverted.
