---
title: "SM099 - sign in/out button must be client-side (not baked into the cache)"
subtitle: "The shared page cache bakes one visitor's auth state into the button"
brand: plain
---

::: widebox
The layout's **Sign in / Sign out** control reflects the auth state of whoever
triggered the cache-miss render, then that HTML is served to everyone. So a visitor
can see "Sign out" while signed out (or "Sign in" while signed in). The auth-varying
parts of a cached page must be resolved **client-side**, not baked in.
:::

## Why it happens

A rendered page is cached as a shared `.html` and served to all visitors. The
processor already bypasses the cache for *managers* (so the admin bar is never
baked), but a normal authenticated visitor (e.g. a `members` account) is not a
manager - their render can write a cache carrying "Sign out", which anonymous
visitors then receive. The reverse also happens (an anonymous render bakes "Sign
in").

## The fix

Make the auth-dependent header control **client-side**:

- The layout renders a neutral placeholder (e.g. `<span class="ls-auth"
  data-auth></span>`); a tiny bundled script fills it in on load from the actual
  client state.
- Determine signed-in-ness client-side without trusting the cached HTML. Cheapest:
  a **non-HttpOnly marker cookie** (e.g. `lzs_session=1`) set alongside the signed
  `HttpOnly` auth cookie at login and cleared at logout - the script reads it and
  shows Sign out + the account, else Sign in. (The marker carries no authority - the
  signed HttpOnly cookie remains the gate; this is display only.)
- Alternatively a small `/whoami`-style endpoint the script calls, but a marker
  cookie avoids a request per page.

## Notes

- Same class as the admin bar (already handled by NOCACHE for managers) and the
  preview marker cookie (`lzs_preview_active`) - this extends the pattern to the
  ordinary sign-in/out control for all authenticated non-managers.
- Keep a `<noscript>` fallback (e.g. always show a "Sign in" link, which is harmless
  for a signed-in user).

## Status

Queued. Bounded: a placeholder in the layout(s) + a small script + a marker cookie
set/cleared in `lazysite-auth.pl` at login/logout.
