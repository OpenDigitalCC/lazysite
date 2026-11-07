---
id: SM1379
title: "SM1379: an email field neither hides spam from the quarantine nor carries a probe past it"
subtitle: "SM913's 'every field the same' rule counted the email field, so a random address defeated it. An email field holding quotes or SQL went unremarked. Ruling 133: email fields are left out of the rule, and a probe in one is quarantined."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (ruling 133, triage T-34)"
area: forms
status-note: "SHIPPED (0.16.6) on n760, ruling 133: _one_value_everywhere leaves email fields out; _email_field_injection quarantines quotes or SQL in an email field, naming the field only; ruling 138: one apostrophe in the local part passes. Register entry confirmed (ruling 140). t/unit/forms/75."
---

# What happened

[[SM913]] S3 quarantines a submission whose fields are one value said three
times: every field the same text, or one run of five or more digits in every
field. The email field was one of the fields, so a bot that repeated its number
in name, subject and message and put a random address in the email field broke
both shapes.

A scanner puts its payload in the email field. A form with no rules sidecar has
no `type: email` check (SM934) to refuse it, and the quarantine had no signal for
it.

# What shipped

Ruling 133:

- **Email fields are left out of the repetition rule.** An email field is one
  whose name says so (`email`, `e-mail`, `your_email`, `email-address`) or whose
  value is one address and nothing else. A field declared `type: email` in the
  rules sidecar is covered by the second: validate_fields has already refused any
  value of it that is not an address. The three-field minimum now counts the
  other fields.
- **An email field holding quotes or SQL is quarantined**: a double quote or
  backtick, an apostrophe other than one in an address's local part, `/*` or
  `-- `, or SQL-shaped text (`UNION SELECT`, `DROP TABLE`, `OR 1=1`, `SLEEP(`).
  Stored and flagged, never refused, as SM913 ruled. The reason names the field
  and does not repeat the value.

# One apostrophe passes (ruling 138)

Ruling 138 (release manager, 2026-11-06): a single apostrophe in an email's local
part passes, so `o'brien@example.org` is not quarantined. As first built, any
apostrophe quarantined, which held back real addresses. Two apostrophes, one in
the domain, or one in a value that is not an address still quarantine, and so do
double quotes, backticks, SQL comments and SQL-shaped text, apostrophe or not.
t/unit/forms/75 tests both sides.
