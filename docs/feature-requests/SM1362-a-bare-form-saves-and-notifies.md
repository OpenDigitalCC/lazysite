---
id: SM1362
title: "SM1362: a form tells the site's owner by email, and can answer the submitter"
subtitle: "Re-scoped by ruling 123. A bare form already saves: every contact, enquiry and sign-up form on the live sites runs on the shipped local-storage handler with the default notice. What was missing is that the notice never reached an owner who is not the operator, and that an acknowledgement to the person who submitted was written by hand."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion: 'the default save to file storage is a sensible form default')"
area: forms
status-note: "SHIPPED (0.16.6) on n759, ruling 123: notify.conf owner_contact mails each submission notice through SM485's send_mail (Form SMTP, mail.per_hour); a form's acknowledge_field and acknowledge_message answer the submitter in the form's own words under SM877's caps. t/unit/forms/68."
---

# What was filed

A form with no handler named would keep its submissions in the site's file storage
and tell the site's owner, with spam protection and a send-rate limit on notices,
and ready-made contact, enquiry and sign-up forms. It waited on the sites agent's
evidence of what forms had really needed.

# What the evidence said (sites inbox, 2026-11-06)

- **The bare default exists already.** Every contact, enquiry, interest and sign-up
  form runs on the shipped `local-storage` handler with the default notice.
- **No form notice reaches an owner who is not the operator** (T-50). Notices go to
  the bell and XMPP; an email route exists (SM485, through the Form SMTP extension,
  bounded per hour), but no site has it set up, and its recipient is an account
  that opted in, which on every live site is the operator.
- **Acknowledgements are written by hand** (T-51), as `.eml` scripts, on three
  sites.

# The re-scope (ruling 123)

From "a bare form saves" (already true) to "the owner is told by email, and the
submitter can be acknowledged":

- **The owner, by email.** A site names its owner contact, and the default notice
  reaches them by email when the site has SMTP set up. Through the existing route
  (SM485) and its rate limit: no second mail configuration and no new hook.
- **The submitter, opt-in.** An acknowledgement email to the person who submitted,
  with the form's own wording.

Not in it: default storage (already true), the ready-made forms and a separate
notice rate limit (SM485's bound is reused).

# What shipped

**The owner contact.** `lazysite/notify.conf` takes `owner_contact:`, one email
address. Each `submission` notice (the one a form already raises) is also mailed
there through `Lazysite::Notify::send_mail`, SM485's send: the Form SMTP extension
as the only transport, refused by name when it is not installed, switched off or
has no settings; and the per-site hourly bound `mail.per_hour` (60 unless set),
counted from the same `logs/notice-mail.jsonl`. It follows the notice: nothing on
`notify: off`, nothing for a quarantined submission, the fields only on
`notify: full`; built-in `submission.email` templates carry the link to the
stored submission. The bell notice stays a broadcast. The address is the site's
own configuration, never anything a request carries, so a visitor cannot point
this mail anywhere; a value that is not exactly one address mails nobody and is
logged.

**The acknowledgement.** A form's conf opts in:

    acknowledge_field: email
    acknowledge_subject: Thank you for your message
    acknowledge_message: We have your message and will reply within two days.

`Lazysite::Handlers::acknowledge_form` sends `acknowledge_message` (`\n` is a line
break) to the one address in the named field, after the submission is stored,
whatever handlers the form delivers to. It is SM877's acknowledgement in its
controls: one address (SM1017), none for a quarantined submission (SM913), the
per-recipient (3) and per-site (60) hourly caps, counted in the same
`submitter-mail.jsonl` as an smtp handler's acknowledgements, and changed by the
form's own `submitter_per_destination_hour` / `submitter_per_site_hour`. Unlike
SM877's, it carries the form's wording and NOTHING OF THE SUBMISSION, so a form
cannot be used to send a chosen stranger a chosen text. A failure is logged and
never changes what the visitor is told.

# Tests

t/unit/forms/68, through the real form handler CGI and the Form SMTP extension
with a mock sendmail: the owner and the submitter each get one message, the
acknowledgement in the form's words and without the visitor's text; `notify:
full` gives the owner the fields; nothing without the opt-ins; the owner mail
needs the extension, follows `notify: off` and refuses two addresses; a
quarantined submission tells nobody; `mail.per_hour`, the per-address cap, the
form's per-site cap, and the bucket shared with the smtp handler each hold.

# ADR 0007

Ruling 140 (release manager, 2026-11-06): an owner notice under `notify: full`
carries a submission's contents by email, so the new-processing-of-restricted-data
trigger fires. It is assessed contained: off by default, sent only to the
operator's named `owner_contact` address, and rate-limited by `mail.per_hour`.
The register entry in `docs/SECURITY.md` (2026-11-06, SM1362) records it.
