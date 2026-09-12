---
id: SM854
title: "SM854: the two refusals an agent meets most often answered 400, because neither carried a kind"
subtitle: "SM670 derives a refusal's HTTP status from its `kind`, and a refusal with no kind answers 400 by rule. The dispatch gates set none: an action the account may not call and an action name the server does not recognise both answered 400 - a permission problem and a spelling problem, reported identically."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-12
raised-by: site agent (1313E-04)
area: control-api
---

# What was found

The 1313E pass checked SM670's statuses and found the mapping working where a
kind was set - `exists` 409, `invalid` 400 with its field - and absent where it
matters most:

| Provoked | Answered | Should be |
| --- | --- | --- |
| an action the token lacks the capability for | 400, no kind | 403 |
| `nosuchthing` | 400, no kind | 404 |

Both messages are well written - the first names the capability that would work,
the second says to check the spelling and the query string - and both arrive with
the status of a malformed request. A client that reads the status to decide
whether to stop, ask for a grant, or fix its request cannot tell the two apart.

SM237 exists because these two were once confused in their WORDING. The wording
was fixed; the status was not.

# What it was

The refusals are raised on the API channel in `lazysite-manager-api.pl`. The UI
channel's capability refusal already carried `kind => 'forbidden'`; the API
channel's carried nothing, and so did the cookie-only and unrecognised-action
refusals beside it. A sweep of the file found 78 refusals with no kind - most
correctly, because a validation refusal IS a 400.

# The fix

Nine refusals on the access path now carry a kind that already exists in
`Lazysite::Manager::Common::%REFUSAL_STATUS` - no new mapping, no new vocabulary:

| Refusal | kind | status |
| --- | --- | --- |
| insufficient capability (api channel) | `permission` | 403 |
| the `api` capability is required | `permission` | 403 |
| an interactive manager account on the api channel | `forbidden` | 403 |
| an action served only to the manager UI | `forbidden` | 403 |
| an unrecognised action name | `not-found` | 404 |
| the control API is not enabled | `disabled` | 403 |
| upload exceeds the limit | `too-large` | 413 |
| upload rate exceeded | `rate` | 429 |
| invalid or missing CSRF token | `forbidden` | 403 |

Wordings are untouched. Validation refusals keep their 400.

# Held by

`t/integration/97-a-refusal-carries-its-status.t` drives the real CGI over token
auth and asserts the status LINE for each - the unknown action, the capability
refusal, the channel gate and a cookie-only action - with two controls that must
not move: a successful call still answers 200, and a malformed request still
answers 400. It fails against the shipped control API on every refusal.

# Still a decision, not fixed here

**`Invalid credentials` answers 400.** 401 is the honest status and there is no
401 in `%REFUSAL_STATUS`; adding one is a contract decision for the release
manager rather than a fix, so this refusal is left as it was. The same question
covers `This action must be sent as POST.` (405) and the bootstrap refusal on a
site with no manager account (409 or 403). Each is a deliberate omission here.

# Related

[[SM670]] (the statuses), [[SM237]] (the same two refusals, confused in wording),
[[SM821]] (the other API-contract change in 0.13.13).
