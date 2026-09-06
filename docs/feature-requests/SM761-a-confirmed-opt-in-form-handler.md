---
id: SM761
title: "SM761: a confirmed opt-in form handler - the confirm link is the only path to the payload"
subtitle: "Filed from the sites agent's request of 2026-09-06, raised while designing an evaluation-download form on sites.lazysite.io; the operator asked for it to be put to dev. Verified against the engine: no site can mail a submitter today, so the primitive is absent, not merely unused."
brand: plain
standard-margins: true
status: candidate
status-note: "candidate 2026-09-06, awaiting the release manager's word. Not built. The request is archived at inbox/archive/2026-09-06-request-confirmed-opt-in-form-handler.md and is the specification of the need; this filing adds what the source says and the decisions the build would need."
---

# The need, in one sentence

A form that gives the visitor something back - a download, an evaluation, a
key, an account - must not give it to an address nobody has proved, because
otherwise the form is a way to make the site mail a stranger with a payload
on the sender's behalf.

# What the source says (2026-09-06, main at SM760)

- The `smtp` handler (`plugins/form-smtp.pl`) sends one message, to the fixed
  `to` in `handlers.conf`, with a generated field-dump body. **Nothing in the
  forms pipeline sends mail to the submitter.** The agent's reading of the
  docs is correct against the code.
- `form-submission-confirm` (SM216) is the **operator's** confirmation of a
  submission from the manager - not a visitor's proof of address. The name
  will collide; the build should pick another word (`verify`).
- The bot defences (honeypot, HMAC window, spam assessment and quarantine) are
  all about the submitter, none about the address. The agent's table is
  right.
- The pieces the build would use exist: `lazysite/forms/smtp.conf`, the JSONL
  store, the `table` handler's declared data table, the dispatch pipeline,
  notifications.

# The shape (from the request; agreed as the right shape)

1. On submission, record the row **unverified** and mint a single-use,
   expiring token.
2. Send a **minimal** message to the submitted address: what was asked for,
   the confirm link, nothing of value.
3. On the click, mark the row **verified**, and only then dispatch the
   handlers that deliver the payload.
4. Three visitor-facing states the site can render: check your mail;
   confirmed, here it is; that link has expired.

**The confirm link is the only path to the payload.** A design that sends
the payload first and confirms afterwards solves neither risk.

# Decisions the build needs (the release manager's)

| # | Question | The request's lean | Note from the source |
| --- | --- | --- | --- |
| 1 | Where the click lands | a form-handler endpoint | `form-handler.pl` is POST-only by design; a GET verb wants its own route and its own rate limit |
| 2 | Where the token and flag live | engine-owned store, not content | `lazysite/forms/` already holds `smtp.conf` and the JSONL store; a per-form `verify.jsonl` beside the submissions is the smallest honest home |
| 3 | What fires on verification | second dispatch of the remaining handlers | the simplest model; handlers would declare `after: verify` or the form would list `verify` first |
| 4 | Quarantine | a quarantined row sends no confirmation | must hold, or the quarantine is bypassed by the mail it suppresses |
| 5 | Resend | bounded, with a cooldown | one open token per (form, address); a resubmit resends the same link, no new token, cooldown ~10 min |
| 6 | Expiry | a working day | 24 h; an expired link says so and offers the form again |
| 7 | The consent record | keep the click deliberately | timestamp, the form's page path and its content version at the time (the content history has it), the address - this is the evidence eleven-year-old records lacked |

# Relationship

SM762 (markdown email templates) supplies the words this message needs; each
stands alone.
