---
title: "SM219 - Login loop for an account without the manager (ui) capability"
subtitle: "An API/MCP-only account authenticated successfully, then bounced between /manager and /login forever; the manager boundary now serves a terminal 403 that names the cause and the remedy, and the UI warns before a change strips manager access"
brand: plain
status: shipped
status-note: "Field-reported 2026-07-23, root-caused the same day, FIXED and shipped in 0.9.14 (also in 0.10.0 stable / 0.10.1). Numbered retrospectively 2026-07-27 - the fix predates its SM number, so this doc is the record, not an open item. Distinct from SM188 (the stale lzs_session marker), which was the OTHER login-loop cause."
---

# SM219 - manager login loop for a non-`ui` account

## The bug

An account placed in an `mcp`-only group could sign in - the credential was
valid and a real session was minted - but every attempt to reach the manager
bounced: `/manager/` redirected to `/login`, `/login` saw a valid session and
sent the user back to `/manager/`, forever.

Distinct from [[SM188]], which was a stale `lzs_session` marker cookie
outliving a dead session. Here the session was genuinely valid; the account
simply had no manager access.

## Root cause

Two correct gates that disagreed about what to do with the same account:

- `handle_login` authenticated the account and minted a session - correct, an
  account may legitimately need an interactive login for auth-gated *public*
  pages.
- The manager render gated on the **`ui`** capability and, on failure,
  **redirected to `/login`** - which is the right refusal but the wrong
  response: it sent an already-authenticated user back to a page that would
  immediately return them.

SM127 (MCP-only accounts cannot drive the manager UI) was working exactly as
designed. The defect was purely the *shape of the refusal*.

## The fix

**Refuse at the manager boundary, not at login.** Blocking login outright was
considered and rejected: an API/MCP account may still need an interactive login
for auth-gated public content, so the refusal belongs where the manager access
is actually attempted.

1. **Terminal 403** (`_serve_manager_forbidden`, `lazysite-processor.pl`): an
   AUTHENTICATED account without `ui` hitting `/manager/` gets a served 403 that
   names the cause (this is an API/MCP account), the remedy (use the connector,
   or have an operator grant `ui` to one of its groups) and a sign-out link.
   No redirect, so no loop. An UNAUTHENTICATED request still 302s to `/login`
   and clears the `lzs_session` marker (SM188 behaviour, unchanged).

2. **Proactive warning** (`starter/manager/users.md`): the reactive 403 catches
   the problem only *after* an account is locked out, so the group editor now
   confirms before removing an account's **last `ui`-granting group** - "this
   will remove <account>'s access to the manager interface; they'll only be able
   to connect via the API/MCP connector". Computed the same way the gate
   resolves it (`groups.<g>.caps.ui`, already in the users-page payload), so no
   server change. Pairs with SM198's inert-group warning: same surface, same
   "make capability reality visible" theme.

## Tests

- `t/integration/31-manager-login-loop.t`: an authenticated non-`ui` account
  gets a terminal 403 at `/manager/`, not a redirect; an unauthenticated one
  still redirects.
- `t/unit/.../02-api-mode.t`: locks the `caps.ui` contract the UI warning reads.

## Lesson

A capability refusal has two parts: the *decision* (which was right) and the
*response* (which looped). Any gate that refuses by redirecting must ask whether
the destination can send the request straight back - a redirect is only a valid
refusal for an anonymous caller.
