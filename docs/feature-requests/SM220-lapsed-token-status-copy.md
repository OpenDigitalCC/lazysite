---
title: "SM220 - A lapsed renew-on-use token reported itself as 'in use'"
subtitle: "Sessions & keys showed 'in use' + 'token expired' + 'renews on use' on the same row - three true signals that together read as a contradiction; the status now leads with the lapse and says when the key was last used"
brand: plain
status: shipped
status-note: "FIXED on main (commit ee18e06), releasing in the 0.10.2 edge line. Field-reported 2026-07-27 ('in use token expired ... renews on use - this is confusing'). Root-caused as a COPY/semantics defect, not a broken token: the underlying behaviour is correct and deliberate. Fix built on branch claude/fix-sessions-token-status-copy (frontend only, starter/manager/sessions.md), smoke-green, AWAITING vcs-review; channel/release to be decided with the batch it lands in."
---

# SM220 - lapsed token reported as "in use"

## What was seen

A key row on **Sessions & keys** read:

```
claude-code   api webdav   25/07/2026, 14:21:20   in use  token expired
                                                  renews on use
```

"in use" beside "token expired", with "renews on use" underneath - which reads
as either a bug or a lie, since a token that renews on use should not be able to
expire while it is in use.

## Why it happened (the behaviour is correct)

Three independent, individually-true signals rendered side by side:

`in use`
: The key has been used **at least once since it was issued**
  (`cred_used_at >= cred_issued_at`, `cmd_keys_list`). It is a HISTORICAL fact,
  not a claim about right now.

`token expired`
: `token_expires_at` is in the past. Current, and true.

`renews on use`
: The account carries an operator-set `token_ttl`, so SM212's sliding renewal
  applies.

The apparent contradiction is the gap between "has ever been used" and "is
currently live". SM212's renewal deliberately **never resurrects an expired
token** - `touch_credential` slides the expiry only while
`token_expires_at > now`, and never shortens it. So a renew-on-use key that goes
unused for a full `token_ttl` **lapses by design**: only genuine inactivity can
end it, which is exactly the intended property. The engine was right; the page
did not say so.

## The fix

Frontend copy + rendering only (`starter/manager/sessions.md`); no backend
change - `used_at` was already in the `keys-list` payload.

When the token has expired, the row now:

- leads with **`token expired`** and shows **`last used <date>`** instead of the
  green `in use` tag - stating the historical use as history; and
- shows **`lapsed after inactivity`** in the Lifetime column, tooltipped "renews
  its lifetime on each use, but went unused for longer than that lifetime, so it
  has lapsed. Rotate the key to issue a fresh token." - instead of the
  now-misleading `renews on use`.

A live token is unchanged: `in use` + `expires <date>` + `renews on use`.

The reported row therefore reads: *token expired · last used 25/07/2026 ·
lapsed after inactivity* - coherent, and it names the remedy (rotate the key
from the account's card on the Users page).

## Tests

Covered by the starter-page smoke test (`t/smoke/01-all-starter-pages.t`), as
with the other manager-page rendering.

## Lesson

A status line is a sentence, not a set of flags. Each tag here was true in
isolation; the defect was emergent - only visible when a particular combination
rendered together. Where one tag is historical (`in use`) and another is current
(`token expired`), the historical one has to be re-worded once the current one
fires, or the row contradicts itself. Worth checking wherever "ever" and "now"
facts share a cell.
