---
id: SM1406
title: "SM1406: the route report names the owner mail"
subtitle: "Notify::route_report - set_form_notify's announces block, the API's and the Handlers page's - answered bell, xmpp and the opt-in email route only, so a site with owner_contact set saw no sign of it. It now reaches owner-mail, or withholds it with the first reason."
brand: plain
standard-margins: true
status: withdrawn
raised: 2026-11-07
raised-by: "release manager, 0.16.8 wave 1 (n771)"
area: forms
status-note: "WITHDRAWN before landing (ruling 159): the owner mail it reported is retired by SM1412, so the route report has no owner-mail endpoint. Built on n771 (commit 799041eaa) and dropped from the branch with its _mail_transport refactor, which SM1405 does not need; nothing of it ships."
---

> Withdrawn before landing by ruling 159. The text below records what was built on
> the branch and then dropped; none of it ships.

# What happened

SM938 D2 made `route_report` say where a form's submission notice goes and
what stops it, from the same checks delivery uses. SM1362 added a fourth
destination, the owner contact's mail, and the report was not taught it: an
operator who set `owner_contact` and opened the Handlers page, or an agent
reading `set_form_notify`'s `announces`, saw bell and xmpp and no sign of the
owner mail, sent or withheld.

# What was built

- `route_report`, for a submission notice: `owner-mail` in `reaches` when
  `owner_contact` is set in `lazysite/notify.conf`, is exactly one address and
  the mail transport allows a send; otherwise in `withheld` with the first
  reason, in the order `_mail_owner` and `send_mail` meet them: `notify.conf`
  names no `owner_contact`; `owner_contact in notify.conf is refused - ...`
  (the send's own sentence); the Form SMTP extension not installed, switched
  off, or without settings. The hourly bound is a count at the moment of a
  send, not a state, and is not reported.
- `_mail_transport`: the three transport checks factored out of `send_mail`
  and asked by both, so the report cannot say "reaches" of a mail the send
  would refuse (the SM938 D2 rule: the report calls the checks, never
  describes them).
- A form's own `notify: off` and `emit.submission: off` still withhold
  everything first, as before; another notice type reports no owner mail.
- The Handlers page draws it as it draws every endpoint; `/docs/forms` names
  it.

Test: `t/unit/lib/212` - reaches with the address set and the extension on
with settings; withheld naming "no owner_contact", the refused two-address
value, the extension off, and no settings; `notify: off` withholds all;
another type reports none. Fails with the report reverted.
