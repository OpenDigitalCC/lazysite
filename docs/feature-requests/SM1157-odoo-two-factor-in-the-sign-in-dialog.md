---
id: SM1157
title: "SM1157: Odoo's two-factor code in the Odoo sign-in dialog"
subtitle: "A person whose Odoo account has two-factor authentication is asked for the code after the password, instead of being refused; remembering the device is the site's choice and the value is kept in one cookie."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: OOM agent (L4), at the owner's request; accepted by the release manager 2026-10-17
area: odoo
status-note: "SHIPPED on n644: lazysite-odoo.pl (signin_code), lib/Lazysite/Odoo.pm (sign_in_code, odoo_remember_device), lib/Lazysite/Odoo/Session.pm (pending and device cookies, complete_totp), starter/assets/lazysite-odoo.js; t/unit/odoo/48, 49."
---

# What happened

The L4 filing, 2026-10-17:

> The owner chose Odoo's own TOTP as the second factor: Odoo-centric, with Odoo
> as the one authority (option M1 of the pocket-portal plan). Today the
> extension refuses an account with Odoo's two-factor on (`two-factor`, 403).

and its addendum, "what OOM 0.27's two-factor step does, as built":
`authenticate` answers `{ second_factor => 'totp', pending => 1 }`;
`complete_totp($code, remember => 0|1, user_agent => UA)` finishes the sign-in
and, with `remember`, returns `trusted_device => { name => 'td_id', value }`
which OOM never stores; a wrong code is fault category `second-factor`;
`resume_pending(session => SID)` rebuilds the pending transport between the
two requests; Odoo fails (HTTP 500, read on 16) on a `remember` post whose
User-Agent it cannot place, so the visitor's own is passed; the audit never
logs the code, the password or the device value, "the extension's call record
must not either".

Whether to offer "remember this device", and where to keep that cookie, is the
site's decision (L3: on a shared tablet the person signed in is responsible).

# What shipped

- **The password step.** `signin` on the page endpoint answers
  `{ ok, signed_in: false, second_factor: 'totp', remember_offered }` for such
  an account. The half-open session id travels in its own cookie,
  `lzs_odoo_pending`: signed with its own domain separation (so it is never a
  session cookie, and a session cookie is never a pending sign-in), HttpOnly,
  SameSite=Strict, Secure over HTTPS, scoped to the endpoint, good for five
  minutes. No session cookie is set.
- **The code step.** `signin_code` (`code`, `remember`, `visitor_token`) rebuilds
  the pending transport with `resume_pending` and calls `complete_totp` with the
  visitor's User-Agent. A right code sets the session cookie and clears the
  pending one. A **wrong code** answers `second-factor` (401) and changes
  nothing, so the person tries again; Odoo counts the tries and says when it
  has had enough, and lazysite adds no count of its own to the code step (the
  password step is already limited per address and login, and is what mints a
  pending sign-in). Odoo's own words are not returned. A pending sign-in that
  has expired, was forged, or that Odoo has forgotten is `signin-required`
  (401) and clears the cookie; Odoo is not asked for the first two.
- **Remember this device** is a new extension setting, `odoo_remember_device`,
  **off unless said**. It is offered only when on **and** the request is over
  HTTPS (the value lets a browser past Odoo's second factor for up to ninety
  days, so it never travels in the clear), and honoured only then. The value
  Odoo returns is kept in one cookie, `lzs_odoo_device` (HttpOnly, Secure,
  SameSite=Strict, the endpoint's path, 90 days), never in a body or a store,
  and sent back to OOM as `trusted_device` on the next password, when Odoo opens
  the session with no code. A value Odoo no longer trusts, or one the site has
  stopped honouring, is not sent and is cleared.
- **Sign-out** also ends a half-open sign-in the person gave up on.
- **The call record** gains the phase `signin-code`, names the session by a
  hash and the outcome by its kind; the code, the password and the device value
  are in no record, audit line, log line or response body (t/unit/odoo/48
  searches every file the engine wrote, the log and every body for all of them).
- **The browser helper and its dialog** (`lazysite-odoo.js`) take the second
  step: the dialog turns into a one-time-code box, with the "don't ask again on
  this device" box only when offered; a wrong code is said and asked again; a
  lapsed sign-in returns to the password; Cancel ends the half-open sign-in.
  The code box is cleared before the answer arrives and the code is in the body
  of its own POST only (t/unit/odoo/49).
- **The dependency floor stays at OOM 0.03.** The two-factor step needs 0.27, but
  an older OOM never answers a pending sign-in: such an account is refused by
  name (`two-factor`, 403) as before, which t/unit/odoo/48 holds by removing
  `complete_totp`. The setting's note and `starter/docs/odoo.md` say it needs
  0.27.
- `second-factor` joins the 401 refusals (`Lazysite::Manager::Common`).

# Not done

- A trusted device is Odoo's list and is revoked in Odoo (the account's
  security settings); lazysite has no screen for it.
- No lazysite-side count on wrong codes (Odoo's limit is the limit); a site
  that wants a tighter one raises it with Odoo.
