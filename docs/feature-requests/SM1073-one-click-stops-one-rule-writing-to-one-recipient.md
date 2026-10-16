---
id: SM1073
title: "SM1073: one click stops one rule writing to one recipient"
subtitle: "SM1010 R4. Ruled \"Per rule, default on\": every rule's messages carry an unsubscribe link and List-Unsubscribe. Both pointed at a page the operator had to write, and the engine recorded no refusal. Now the engine's own signed link stops that rule writing to that recipient, in one click, without a sign-in (RFC 8058)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: SM1010 R4, ruled 2026-10-12 ("Per rule, default on"); SM1034 Q1 (the session-less unsubscribe on the auth CGI) and Q7 (per rule and recipient)
area: notifications
status-note: "SHIPPED (0.15.5): lazysite-auth.pl?action=unsubscribe&t=<token> - GET asks, POST (and RFC 8058 one-click) records a stop in notify/suppressed.jsonl, idempotent and audited; the token is an HMAC over rule and recipient hash under notify/.unsubscribe.key; the outbox skips a stopped pair on every channel, held messages too. t/unit/lib/94, t/integration/248."
---

# The rulings

The release manager, 2026-10-12 (SM1010 "Ruled"): **"Unsubscribe - 'Per rule,
default on'.** Each rule's messages carry an unsubscribe link and a
List-Unsubscribe header unless the rule turns it off." Q8 as recommended: "a
link ... and a `List-Unsubscribe` header ...; one-click POST unsubscribe
later."

SM1034 "Ruled" (2026-10-12), Q1: "`me-*` actions on the control API; the
session-less unsubscribe goes on the auth CGI, later." SM1034 Q7, as
recommended: "per (rule, recipient), for account and address recipients
alike".

The coordinating session, 2026-10-13: "an unsubscribe link acts without
sign-in, so it must be unguessable, act only on its own rule and recipient, be
idempotent, and be audited."

# What was wrong

SM1010 R4 and SM1034: the link and the header pointed at `unsubscribe_path`,
the operator's own page (Outbox.pm, `render`), which a rule could not save
without; "Nothing in the engine records a refusal. The outbox job sends to
every resolved recipient, subject only to the per-recipient cap; there is no
suppression list."

# What was built

- **The token** (`Lazysite::Unsubscribe`): `v1.<rule>.<recipient>.<mac>` - the
  rule id, the recipient as the 24-hex hash the ledger already keys it by
  (never an address or account name), and HMAC-SHA256 over both under
  `notify/.unsubscribe.key` (256 random bits, 0660, made once by the sending
  side, exclusively; the endpoint never makes one), cut to 128 bits and
  compared in constant time. Changing the rule, the recipient or the MAC gives
  a token that does not verify. The same pair always gives the same link; it
  does not expire (a recipient may act on an old message); deleting the key
  voids every link sent.
- **The endpoint**, `lazysite-auth.pl?action=unsubscribe&t=<token>`: GET
  shows a confirmation page and changes nothing (mail scanners fetch links);
  POST records the stop - the page's button, or a mail client's RFC 8058
  one-click POST (`List-Unsubscribe=One-Click`). Recording a pair already
  recorded changes nothing and says so. The page is the engine's own: no
  layout, script or outside resource, `Referrer-Policy: no-referrer` (the URL
  carries the token), `no-store`, `noindex`, a CSP of `default-src 'none'`.
- **Audit**: every POST - `unsubscribe | notify:<rule> | <ip> | ok | ui |
  recipient <hash>` (with " - already stopped" on a repeat), a token that does
  not verify as `denied`, a store that cannot be written as `failed`. Never an
  address.
- **The store**, `notify/suppressed.jsonl`: one line per stopped (rule,
  recipient hash), appended under an exclusive lock.
- **The outbox job** reads it once per run. A stopped recipient gets nothing
  more from that rule on any channel - the bell too - including a message the
  cap was holding (SM1071); each skip is a failed audit row saying
  "unsubscribed". A store that exists and will not open stops the run, as an
  unreadable ledger does: "could not tell who said stop" is not "nobody did".
- **The message**: `List-Unsubscribe: <one-click link>` and
  `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (the Form SMTP
  extension's closed header list gains the second, in its one fixed shape),
  and the body's "To stop these messages:" line is the same link. A rule's
  `unsubscribe_path` is now optional, offered beside it as "Manage your
  subscriptions"; templates get `unsubscribe_url` and `manage_url`. If no link
  can be made (the key cannot be written), the message is retried, not sent
  without one.
- The outbox view (SM1072) shows a stopped recipient's pending send as
  `unsubscribed`.

# Not built

- SM1034 phase 2's member side: `me-messages` (the rules that have written to
  me) and `me-message-stop` / `-resume`. There is no resume: a stop is undone
  by an operator removing its line from `notify/suppressed.jsonl`.
- The confirmation page in the site's theme (SM1034 suggested one). It is the
  engine's own plain page: a themed page would mean a system page reflecting
  the token into a form, for a page that has one button. For a ruling if
  wanted.

# Tests and sabotage

- `t/unit/lib/94` - no key, no verification; the token is stable, 0660, names
  no address; another rule, another recipient, every one-character MAC change,
  another site's key: refused; recording is idempotent; an unreadable store
  is "cannot tell".
- `t/integration/248` - through the outbox job and lazysite-auth.pl: the
  header pair and the body link; GET asks and records nothing; tokens changed
  to another recipient or rule refused and audited; POST stops it, a repeat
  and a one-click POST record nothing more and are audited; the next event
  reaches bob and not ann; ann still gets another rule; a held message is not
  sent after the stop; an unreadable store sends nothing.
- `t/unit/notify/01`, `03`, `04` and `t/unit/lib/93` follow the change: no
  page is required, the link is the engine's, the Post header's shape guard.

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S1 | any well-formed token verifies | 94, 248 |
| S2 | the MAC does not cover the rule | 94, 248 |
| S3 | a GET records the stop | 248 |
| S4 | the outbox writes to a stopped recipient | 248 |
| S5 | a held message goes to a recipient who stopped since | 248 |
| S6 | recording is not idempotent | 94, 248 |
| S7 | an unreadable store of stops reads as empty | 248 |
