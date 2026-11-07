---
id: SM1405
title: "SM1405: a notice mail has its own shape"
subtitle: "A notice mailed through the site's one send arrived with the subject '[SITE] A form was submitted - ' and a body laid out as a form submission - a heading, the notice under a message: label, Submitted and IP lines. Every such mail now carries its own subject and the rendered notice as its body (ruling 157)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager, 0.16.8 wave 1 (n771)"
area: forms
status-note: "SHIPPED (PENDING) on n771: Notify::_mail_send hands a notice to the Form SMTP extension as a composed message (send_message: subject, text), not a form submission; no handler layout, no IP line; transport and hourly bound unchanged. Ruling 157: every notice mail. Test re-aimed at SM485's account notice and a claim link (the owner mail is retired, SM1412). t/unit/forms/77."
---

# What happened

`Lazysite::Notify::send_mail` (SM485) is the site's one mail to an account: a
notice for an opted-in account, an import's claim link, and (until SM1412) the
owner contact's copy of a form notice. Its transport `_mail_send` called the
Form SMTP extension's `--pipe` with `config => { to, subject_prefix =>
"$subject - " }` and `form => { message => $text }`. That is the shape of a
FORM submission, so the extension built the mail as `send_email` builds one: the
subject was the prefix followed by nothing (`[Bakery] A form was submitted - `),
and the body was a "Form submission" heading, the notice under a `message:`
label, then `Submitted:` and `IP:` lines - the IP of the request that raised the
notice, which the notice itself never carries.

# What was built

`_mail_send` now sends `message => { subject, text }` (with an empty `form`,
which the pipe's shape asks for), the path SM1020 made for a notification
rule's composed mail: the extension's `send_message` puts the subject on the
wire folded and encoded, the rendered notice as a plain-text UTF-8 body, and
nothing of its own. The transport, its refusals by name and the hourly bound
(`mail.per_hour`) are `send_mail`'s as before. Ruling 157: every notice mail
through the one send takes this shape - SM485's account notices and an
import's claim links alike - since they are all composed notices and none was a
submission.

The owner-contact mail this was first found on is retired (SM1412, ruling 159);
the fix stands for the sends that remain.

Test: `t/unit/forms/77` - the real extension script behind a mock sendmail:
SM485's notice to an opted-in account and a claim link sent as
`Manager::AccountImport` sends it each have their own subject with nothing
dangling, carry their text, and have no "Form submission" heading, no
`message:` field and no `IP:` or `Submitted:` line; the request address is
nowhere in the notice. Fails with `_mail_send` reverted.
