---
id: SM877
title: "SM877: an smtp handler that can answer the submitter"
subtitle: "The stock smtp handler takes a `to` fixed at configuration time, so a native form can notify the site owner and cannot acknowledge the person who filled it in - every receipt, booking confirmation and consent-record flow needs the other direction. The requested fix is one schema key, `to_field`, naming a form field rather than an address. The cap it needs is the actual work: form rate limiting is per source IP (default 5/hour), which is the wrong axis for an open relay."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-14 by the sites agent, for a model-release flow where a signer should get their own copy. NOT 0.14.1 - a new field on a delivery path is a feature, and the patch is low-risk fixes only. The requester proposed inheriting the existing form rate limiting; checked against plugins/form-handler.pl:682, that limiter is keyed per source IP and caps how often ONE SENDER submits, saying nothing about how many distinct destinations the site will mail - so it does not mitigate the relay risk the requester correctly named. Connectors already carry a real rate cap, modes, a credential and a call record (SM579 removed webhook/api handlers for lacking exactly those four), which is why the connector workaround is the path with the controls. Schedule with the per-destination cap attached; the field is one line, the cap is the feature."
---

# SM877 — an smtp handler that can answer the submitter

**Raised by:** the sites agent, 2026-09-14. Not urgent by their own account:
their immediate case is served by a connector, and wants a generated PDF anyway.

## The gap

`Lazysite::Handlers`, type `smtp`, takes a `to` fixed at configuration time.
A native form can therefore notify the site owner and cannot acknowledge the
person who filled it in. Every acknowledgement, receipt, booking confirmation
and consent-record flow needs the other direction.

The requester's shape: a `to_field` naming a **form field** rather than an
address, so the destination stays inside the submission.

```text
- id: release-copy
  type: smtp
  from: no-reply@example.org
  to: office@example.org        # unchanged: who always gets it
  to_field: email               # additionally, the address this field holds
```

A site that does not set `to_field` behaves exactly as today. The requester
raised the open-relay risk themselves, was not asking for it urgently, and
noted their own case is served by a connector.

## Why it is not a patch

0.14.1 is low-risk provable fixes only. This is a new field on a delivery path,
which is a feature by any reading. That alone settles the scheduling question.

## The part worth recording, because the stated mitigation does not hold

The request says the feature "wants to inherit" the existing form rate
limiting. I checked what that limiting actually is before accepting it, and it
does not cover this.

`check_rate_limit()` in `plugins/form-handler.pl:682` is keyed on
`"$ip:$hour"` — **per source IP, default 5 per hour**. It caps how often one
sender submits. It says nothing about how many distinct destinations the site
will mail.

For an open relay that is the wrong axis. The attacker is not trying to submit
often; they are trying to make the site send mail to someone else, and 5/hour
from each of many addresses is not a cap on anything that matters. Worse, the
victim is the recipient, so the limit protects the party who is not being
harmed.

The relevant axes are per-destination and per-site volume, and neither exists
today. Contrast `Lazysite::Manager::Connectors`, which has a real rate cap
(`rate_per_hour`), modes, a credential and a call record — SM579 removed
webhook/api handlers *precisely because* they lacked those four. Routing
attacker-chosen destinations through the one delivery type that has none of
them would walk that decision back.

This is why the connector workaround the requester already has is not merely
more scaffolding: it is the path that carries the controls.

## What a design has to settle

- **A cap on the axis that matters** — per destination and per site, not per
  submitter IP. Nothing in the handler path has this today.
- **Envelope sender is the site**, never anything supplied.
- **A separate delivery, not a second `To:`** — the requester is right, and for
  their reason: otherwise the operator's address reaches a stranger's inbox.
- **Refuse rather than guess** when the named field is absent or empty, per the
  standing rule about never validating the empty value. Validate with the
  existing `email` rule.
- **Whether the operator's copy still goes** when the submitter's fails, and
  what the submitter is told.
- **Whether this belongs on `smtp` at all**, or as a distinct type whose name
  says it mails a stranger — an operator reading `to_field:` on a familiar
  handler may not register what they have switched on.

## Recommendation

Keep it open, schedule it as a feature with the rate-cap work attached, and do
not let it in as "one field". The field is one line; the cap is the feature.
