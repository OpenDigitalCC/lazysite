---
id: SM1405
title: "SM1405: the owner-contact notice mail has its own shape"
subtitle: "The owner mail arrived with the subject '[SITE] A form was submitted - ' and a body laid out as a form submission - a heading, the notice under a message: label, Submitted and IP lines. It now carries its own subject and the rendered notice as its body, through the same send."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager, 0.16.8 wave 1 (n771)"
area: forms
status-note: "SHIPPED (PENDING) on n771: Notify::_mail_send hands the notice to the Form SMTP extension as a composed message (send_message: subject, text) instead of a form submission with a subject_prefix; no handler layout, no IP line; SM485's send, transport and hourly bound unchanged. t/unit/forms/77; /docs/forms."
---

# What happened

`Lazysite::Notify::_mail_owner` renders the submission notice and hands it to
`send_mail` (SM485), whose transport `_mail_send` called the Form SMTP
extension's `--pipe` with `config => { to, subject_prefix => "$subject - " }`
and `form => { message => $text }`. That is the shape of a FORM submission, so
the extension built the mail as `send_email` builds one: the subject was the
prefix followed by nothing (`[Bakery] A form was submitted - `), and the body
was a "Form submission" heading, the notice under a `message:` label, then
`Submitted:` and `IP:` lines - the IP of the visitor whose submission raised
the notice, which the notice itself never carries.

# What was built

`_mail_send` now sends `message => { subject, text }` (with an empty `form`,
which the pipe's shape asks for), the path SM1020 made for a notification
rule's composed mail: the extension's `send_message` puts the subject on the
wire folded and encoded, the rendered notice as a plain-text UTF-8 body, and
nothing of its own. The transport, its refusals by name and the hourly bound
(`mail.per_hour`) are `send_mail`'s as before. Every mail `send_mail` makes
takes this shape - the owner contact's, SM485's account notices, an import's
claim links - since they are all composed notices and none was a submission.

`/docs/forms` says what the owner mail looks like.

Test: `t/unit/forms/77` - through the real form handler with a mock sendmail
(as `t/unit/forms/68`): the owner's mail has the subject `[Bakery] A form was
submitted` with nothing dangling, carries the notice, has no "Form submission"
heading, no `message:` field, no `IP:` or `Submitted:` line and the visitor's
address nowhere; on `notify: full` the fields are in it in the same layout.
Fails with `_mail_send` reverted.
