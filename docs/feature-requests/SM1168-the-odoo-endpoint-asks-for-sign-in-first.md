---
id: SM1168
title: "SM1168: the Odoo endpoint asks for sign-in before it checks the token"
subtitle: "A session-mode binding called by someone with no Odoo session answers 401 signin-required, so the helper's sign-in prompt opens, and not 403 csrf."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: release manager, from the lazysite-Odoo rig / OOM Lab findings (inbox 2026-10-17-oom-lab-findings-for-the-odoo-extension.md)
area: odoo
status-note: "SHIPPED on n650: lazysite-odoo.pl _post_one; t/unit/odoo/51; t/unit/odoo/42 follows."
---

# What happened

From the OOM Lab findings, as handed over for wave 2: a POST to the Odoo
endpoint for a binding in session mode, from a visitor with no Odoo session,
answers 403 with kind `csrf`, not 401 `signin-required`. The session-token
check ran first and failed, because there is no session to hold a token. The
browser helper (`starter/assets/lazysite-odoo.js`) opens its sign-in prompt
only on `signin-required`, so the person was never asked to sign in.

The inbox file holds no separate csrf report: the finding came in the
release manager's item text, and the code shows it. `_csrf_ok` accepts the
visitor token for a session binding only when `odoo_session` is set; with
none it fell through to the account (`authenticated`) branch, which has no
actor to fit a token to.

# What shipped

`_post_one` now answers `signin-required` (401) for a `credential: session`
binding when the request carries no Odoo session, before the token check. The
refusal is the engine's own (`Lazysite::Odoo::gate`), so it is recorded in the
call record like any gate refusal.

- A batch needs nothing more: each call goes through `_post_one`, so a
  session call with no session answers 401 inside the batch while its public
  siblings run and are token-checked as before.
- The token check is not weakened. A request that HAS a session still needs
  the right visitor token (wrong or missing: 403 `csrf`), and a public
  binding's visitor token is checked as before.
- Nothing leaks. The 401 runs nothing and tells nothing of the binding (no
  rows, no operation, no proof it exists beyond what a 404 `not-found` for
  an unknown name already separates); it says "you are not signed in", which
  the caller already knows. Whether the binding is a session binding is not
  secret: the helper's own prompt discloses it.
- A confirm is unchanged. It names a plan, not a binding, and the plan's
  binding (so its mode) is known only from the plan's owner record; a confirm
  with no session is answered as before (403 `csrf` with no token, `not-found`
  for a plan that is not the caller's). The helper reaches a confirm only
  after a plan call of the same session, and that call asks for the sign-in.
- The helper needs no change: it already prompts on 401 `signin-required`
  (t/unit/odoo/31, 44). The new test shows the server's answer it reacts to.

Tests: t/unit/odoo/51 (fails on the base at the two no-session cases, passes
after; sabotage-checked by restoring the base endpoint). t/unit/odoo/42 had
pinned the old behaviour (a second session call after the session ended
answered 403); it now expects 401.
