---
title: "Sessions and keys"
brand: plain
---

# Sessions and keys

Governing capability: `manage_users`.

## Review and revoke a session

Where
: Access -> Sessions & keys

Do
: Sign in as another user in a second browser, find that session here, revoke it,
  then use the second browser.

Expect
: Sessions list the account, when it started and where from. A revoked session
  stops working on the next request rather than at its natural expiry, and the
  revocation is audited.

Negative
: Revoking your own current session should sign you out - and say so - rather
  than silently leaving you on a dead cookie.

## Review and revoke a key

Where
: Access -> Sessions & keys -> keys

Do
: Issue a token to an agent account, exercise it against the control API, revoke
  it, and try again.

Expect
: The key list shows the account, issue time and last use. After revocation the
  API refuses with a reason that distinguishes "revoked" from "never valid" -
  an agent needs to know which.

Negative
: A key belonging to an account outside a delegate's sub-tree is not listed and
  not revocable by them.

## Rotate the auth secret

Where
: Access -> Sessions & keys -> rotate

Do
: Rotate, then check every signed-in browser and every issued token.

Expect
: Every session is invalidated at once. This is the emergency control and should
  read like one - a confirmation that says what it costs, not a bare button.

Negative
: `manage_users` alone is not enough; this is `manage_config`. Confirm the
  refusal names the capability.
