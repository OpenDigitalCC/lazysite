---
id: SM1017
title: "SM1017: a quarantined submission was acknowledged, and an acknowledged address could name two recipients"
subtitle: "SM1010 phase 0, ruled \"Fix now\" 2026-10-12. F1 reproduced through the real delivery path; F2 is a header-injection shape. Both fixed, with the one definition of a mail address in Lazysite::Mail."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1010 F1 and F2, ruled "Fix now" by the release manager 2026-10-12
area: forms
status-note: "SHIPPED (PENDING): the SM877 acknowledgement reads quarantine from the delivery context (F1, reproduced through form-handler.pl); an address put in a mail header is exactly one address, refused otherwise, by the handler, the header writer and the account store (F2). t/unit/forms/60, 61."
---

# The ruling

The release manager, 2026-10-12, SM1010 phase 0, "Fix now":

> F2 (SECURITY): a submitter address (and every place the mail handler puts a
> caller-influenced address into a header) must be exactly one address - no
> , ; < > or CR/LF - refused otherwise; F1: reproduce through the real delivery
> path (form-handler -> deliver) first; if confirmed, a quarantined submission
> sends no acknowledgement.

# F1: reproduced, then fixed

`t/unit/forms/60` posts through `plugins/form-handler.pl`, the CGI a visitor
reaches, to an smtp handler with `mail_the_submitter_field: email` and a mock
sendmail. Before the fix, a submission the spam assessment quarantined (three
links) was stored, and the mock was handed TWO messages: the operator's, and
one to `victim@example.net`, the address the suspect submission chose. The
control case (a clean submission) gets both, so the quarantine case is not
passing vacuously.

The cause is as SM1010 read it: the form handler strips every `_` key before
delivery (`_visible_fields`) and carries the flag as `quarantined` in the
delivery context, and `_acknowledge_submitter` asked `$fields->{_quarantined}`.
It now asks `$ctx->{quarantined}` (and still the fields, so a caller that puts
the key there is not trusted less). The audit row of the delivery carries the
reason ("held in quarantine, so no acknowledgement was sent").

# F2: what was admitted, and the rule now

`_submitter_address` accepted `/\A[^\s@]+@[^\s@]+\z/`. A value with two `@` was
already refused, so the shapes that got through were those with ONE: measured
through the CGI, `root,b@example.org` and `root;b@example.org` reached the mock
in the `To:` header as written - a local mailbox and a stranger, once
`sendmail -t` parses it - and `x<b@example.org>` arrived as `xb@example.org`,
because the writer stripped `<` and `>` and sent the rest.

`Lazysite::Mail::one_address` is the one definition: a bare `local@domain` with
no `, ; < >`, no quote, parenthesis or backslash, and no whitespace or control
character; refused, never repaired. It is applied in four places:

- the acknowledgement's address (`Handlers::_submitter_address`);
- the header writer, `plugins/form-smtp.pl` `sanitise_email`, for `To` and
  `From` on every message it sends (a form's copy, an acknowledgement, a setup
  link, a notice) - it used to strip CR, LF, `<` and `>`; it now refuses, and
  the pipe answers the refusal;
- a handler's own `email`-typed settings (`to`, `from`) at save;
- an account's `email` (`lazysite-users.pl set`, and the account-request
  approval, which reads the address from a form field).

The handler check and the writer check are two layers: with the handler's
check removed the writer still refuses (sabotage S2 below), and the delivery
record names which layer refused.

# Tests and sabotage

- `t/unit/forms/60-a-quarantined-submission-is-not-acknowledged.t` - through
  the CGI: control; quarantined -> operator only, with the reason audited; five
  multi-recipient shapes -> operator only, refused by the handler.
- `t/unit/forms/61-a-mail-header-names-exactly-one-address.t` - the definition;
  the writer refuses and sends nothing; a handler `to` naming two is refused at
  save; an account address naming two is refused.

Sabotage (backups under tmp/sab-bak/, restored with cp and checked with cmp):

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S1 | the acknowledgement asks the fields only | 60, the quarantine subtest |
| S2 | the submitter address is not checked | 60, the record assertions (delivery still refused by the writer) |
| S3 | the writer strips instead of refusing | 61, the writer subtest |
| S4 | the account address check is off | 61, the account subtest |

# Not changed

`notify_email` and Notify's own recipient check (`_mail_recipient`) already
refused `, ; < >`; it is left as it is. A hand-written `handlers.conf` whose
`to:` names two addresses now fails at send with the reason, where it used to
send; the save path already refused two `@`, so no supported configuration
did this.
