---
id: SM1413
title: "SM1413: a notify handler's recipients may name a group"
subtitle: "Ruling 158: no one is mailed by default, and people are mailed only through a notify handler the form names. Its recipients gain a groups source: each member account of each named group, nested membership included, at the address its account record holds."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager, rulings 157-158 (Q86, Q88, Q89)"
area: forms
status-note: "SHIPPED (PENDING) on n771: Outbox recipient grammar gains {\"groups\":[...]} (members by Auth::Settings::group_closure_in, once each; a member with no address skipped as a no-address ledger line and the rule's status no_address); an unknown group is refused at save naming it. t/unit/notify/10; /docs/forms."
---

# What was asked

Ruling 157 found that a single hard-coded `owner_contact` address was the wrong
way to tell people about a form: recipients should be accounts, their
addresses managed in the existing Users UI, chosen as a group or the operator
group. Ruling 158 settled the shape: no one is mailed by default - a form's
submissions go to file storage - and people are mailed only through a handler
the form names, a notify handler whose recipients gain a group source. The
handler decides who, as for its other sources.

# What was built

- `Lazysite::Outbox::parse_recipients` takes `{"groups":["name", ...]}` (1 to
  50 names, each a group name as `group-create` takes it, duplicates dropped).
- `resolve` reaches every member account of each named group at send time. An
  account is a member when the group is among its effective groups as the
  group store walks them (`Auth::Settings::group_closure_in` over the groups
  file and the group records), so a member of a group nested inside a named
  group is a member. Only real accounts are members. A group's address limits
  (SM1140) belong to a request and do not apply to the job. A group store that
  exists and will not open makes the entry retry, as an unreadable account
  store does; it is never read as "nobody".
- Each member is one recipient, keyed by its account, so an account in two
  named groups, or named by another source too, gets one message. The address
  is the one its account record holds, looked up per channel as for
  `{"accounts":...}`.
- A member with no address gets no email: it is skipped, written to the
  ledger as `no-address` (so the event's outbox record counts it) and to the
  rule's status as `no_address` (the Handlers page says "N skipped"), and is not
  audited as a refusal. The bell still reaches it.
- Everything else is the other sources' rules: one message per address, once
  across retries; `per_recipient_hour` with held events folded; one audit row
  per recipient; the unsubscribe link and headers; the actor left out unless
  `notify_actor`.
- At save (`Handlers::_destination_problem`), every named group must exist
  (`Auth::Settings::group_names`: the groups file or a group record), refused
  naming the missing ones and listing the groups there are. The operator group
  may be named.
- Docs: `/docs/forms` - how a form mails people (name a notify handler; by
  default nothing is mailed and the submission is stored under
  `lazysite/forms/submissions`), and the groups source in the notify handler's
  description; the handler schema note names it.

Test: `t/unit/notify/10` - a group of three direct members (one with no
address) and a nested group: the members with addresses get one message each,
the one in two groups once, the one without is counted in the status and the
event's outbox record and not audited; each carries the unsubscribe link; the
per-recipient cap holds the next event; the operator group can be named and
reaches the operator; an unknown group is refused at save naming it. Fails
with the groups source removed.
