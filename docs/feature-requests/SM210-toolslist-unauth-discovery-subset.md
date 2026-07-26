---
title: "SM210 - tools/list over-shares to an unrecognised token (SM196 discovery follow-up)"
subtitle: "SM196 filters tools/list to a session's capabilities, but only when the token RESOLVES to an identity. An unrecognised / revoked / wrong-secret token passes undef caps and gets the FULL tool list instead of the public subset. Enforcement is intact (every tools/call gates on caps); this is discovery hygiene."
brand: plain
status: shipped
status-note: "LOGGED 2026-07-25 - observed live on edge.explore.lazysite.io while smoke-testing 0.9.14: a bogus/unrecognised Bearer token still gets all 44 tools from tools/list, though whoami and every real tools/call correctly reject it (SM200 'token not recognised'). Discovery-only; NOT a security hole. Small."
---

# SM210 - tools/list over-shares to an unrecognised token

## Why

SM196 made `tools/list` capability-aware: an authenticated session sees only the
tools it can invoke. But the filtering keys on a RESOLVED identity. When the
Bearer token is unrecognised - revoked, expired past re-check, or minted under a
since-rotated auth secret - the request has no resolved user, and `tools/list`
returns the FULL advertised set rather than the small public/introspection subset.

Observed live (edge.explore, 0.9.14): a deliberately-bogus token returns all 44
tools from `tools/list`, while `whoami` and every real `tools/call` correctly
reject it with the SM200 "token not recognised" reason. So enforcement is sound -
a bad token can DISCOVER the full surface but INVOKE nothing. This is an
information-disclosure nicety, not a hole: it advertises the site's full tool
vocabulary (including write tools like `create_theme`) to an unauthenticated
caller.

## Root cause (located)

`lazysite-mcp.pl`:

- `rpc_result($id, { tools => tool_list( defined $lu ? $lcaps : undef ) } )`
  (~line 1773): when the logged-in user `$lu` is undef (unrecognised token / no
  token), `tool_list` is called with `undef` caps.
- `tool_list($caps)` (~1640) treats `undef` as "no filter" and returns everything,
  rather than as "no identity - public subset only".
- `%INTROSPECTION_TOOLS` (whoami, describe_capabilities) is the natural
  pre-auth-visible set.

The gap is the semantic overload of `undef`: SM196 uses "resolved user with these
caps" vs the unhandled "no resolved user at all".

## What

Distinguish three discovery states in `tool_list`:

1. Recognised token, full caps -> all tools the caps unlock (SM196, unchanged).
2. Recognised token, limited caps -> the cap-filtered subset (SM196, unchanged).
3. Unrecognised / no token -> the PUBLIC subset only: `%INTROSPECTION_TOOLS`
   (whoami, describe_capabilities) plus whatever is deliberately meant to be
   visible pre-connection (the connect/onboarding affordance, if any). NOT the
   full list.

Pass an explicit signal for "no identity" (e.g. a distinct sentinel, or have the
caller pass `{}` for "recognised-but-no-caps" and reserve `undef` for
"unrecognised") so `tool_list` can return the public subset in case 3.

## Not in scope

- Any change to enforcement. `tools/call` capability gating is correct and stays.
- Hiding the server's existence or the OAuth discovery (that is public by design).

## Verification

- `tools/list` with a bogus / revoked token returns only the public subset
  (introspection + onboarding), not the full tool list.
- `tools/list` with a valid limited token still returns the SM196 cap-filtered set.
- `tools/list` with a valid full-cap token still returns everything.
- Every `tools/call` with a bad token is still refused with the SM200 reason.
