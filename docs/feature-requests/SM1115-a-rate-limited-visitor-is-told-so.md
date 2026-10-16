---
id: SM1115
title: "SM1115: a rate-limited visitor is told so, and the operator can see it"
subtitle: "A form submission refused by the per-form, per-address limit says why and when to try again, and the first refusal in an hour is audited."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: edge-testing agent (0.15.8 walk), fix approved by the release manager 2026-10-16
area: forms
status-note: "SHIPPED on n618: plugins/form-handler.pl; t/unit/forms/66, t/unit/forms/30."
---

# What happened

The 0.15.8 test walk on edge:

> A rate-limited form submission says only "An error occurred - please try
> again." and is not audited. Past the per-form, per-address anonymous limit
> (check_rate_limit in plugins/form-handler.pl), the 303 carries that generic
> outcome. Nothing reaches the audit trail: no `submit` row, ok or fail. A
> visitor cannot tell "slow down" from "broken", and the operator cannot see
> the refusals. This is what made the 0.15.6 R3 walk store 5 of 8 events.

`check_rate_limit` refused with `reject`, whose message is never shown to the
submitter, and no refused submission was audited. The refusal was counted in
the form's blocked statistics under `rate`, and that was all.

# What shipped

- The refusal is a `reject_user` message, as a timing refusal is (SM888 A7):
  "Too many submissions of this form from your address in the last hour.
  Please try again in about N minutes." N is when the oldest counted
  submission leaves the rolling hour. It happens to real people, and the limit
  is in the shipped source, so the reason gives nothing away.
- Its reason code is still `rate`, so the blocked count is unchanged.
- The first refusal for a form and address in a clock hour writes one audit
  row: `submit <form> fail`, origin `form`, detail "rate limit: N an hour from
  this address; next in about Nm". Further refusals in that hour write none,
  so a flood past the limit cannot fill the trail. The marker lives in the
  rate-limit database and goes with its hourly purge.
- A signed-in session is still waived, as designed (SM425).

t/unit/forms/66 lifts the limiter with the real audit trail: the message, the
reason code, one audit row for two refusals, and another address unaffected.
It fails against the plugin before this change.
