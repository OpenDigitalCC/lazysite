---
id: SM952
title: "SM952: A form's rate limit counts an address's posts to every form, including refused ones"
subtitle: "R8 of the 0.15.2 walk could not be settled: a new form refused its first post because the address had posted to another form."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the sites agent, 0.15.2 edge walk R8, 2026-10-07
area: forms
status-note: "RULED 2026-10-07 (release manager): the limit is PER FORM, and only ACCEPTED submissions count - a post refused by validation spends nothing. Key the stamps on form and address; record the stamp only when the submission is stored. WORK-PLAN-0153 R8."
---

# Measured

`plugins/form-handler.pl`, `check_rate_limit`: the stamps are stored in one
`$FORMS_DIR/.rate-limit.db`, keyed on the address alone (SM935). Each form's
`rate_limit:` is compared against that shared list. The check runs at line 246,
before field validation (`reject_invalid`, line ~1001), so a post refused for an
empty required field has already recorded a stamp.

The sites agent's walk (2026-10-07, one address): four accepted posts and one
refused-as-invalid to `contact` at 08:21-08:22 UTC - five stamps, the default
limit. Every later post inside the hour was refused, to `contact` and to a new
form `zz-r8`, including with its `rate_limit:` line removed (default 5). That
is the rolling hour working, applied across forms. The submitter saw only
"An error occurred - please try again."

SM401 introduced the setting as "the per-form `rate_limit` key".

# Where the reason is recorded

The refusal dies with "Rate limit exceeded"; the catch logs
`[ts] [ERROR] [form-handler] [<form>] processing failed error=Rate limit exceeded ip=...`
to the CGI's STDERR (the web server's error log) and, through `_forward_diag`,
to syslog (WARN and above by default, SM932). It is also counted as a `blocked`
form event with reason `rate`. The sites agent found neither line in the logs
the owner pulled; which sink receives it is SM932 (2), scheduled (R6).

# Question for a ruling

1. Should the count be per form and address, as the setting's name suggests, or
   per address across all forms, as built?
2. Should a post refused by validation spend the allowance?

# Ruling (2026-10-07)

1. Per form: the count is kept per form and address.
2. Only accepted submissions count: a post refused by validation spends no
   allowance.

# Done when

Ruled, built and documented; a test posts to two forms from one address and
asserts the ruled behaviour.
