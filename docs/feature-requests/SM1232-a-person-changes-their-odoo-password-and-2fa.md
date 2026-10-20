---
id: SM1232
title: "SM1232: a person changes their Odoo password and turns two-factor on or off, in the page"
subtitle: "The next slice of L4's sign-in dialog, through OOM's core.credential: change-password, totp-enable and totp-disable as the signed-in person, at once, with nothing stored and nothing echoed. Planned and asked for rulings before any code."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-20
raised-by: "the OOM Lab (OOM-side O-6, lab FINDINGS.md) and SM1164's 'Not in this'; inbox triage 2026-10-20 item Ad-7; release manager, 2026-10-20: 'file it'"
area: odoo
status-note: "CANDIDATE, filed 2026-10-20 on the release manager's 'file it' (options were: file now, wait for a page that needs it, leave it to Odoo's UI). Nothing is built. Six questions for a ruling (re-authentication, limit, audit, who, sessions after a change, a site that requires two-factor); sized M."
---

# What was asked

The OOM Lab's finding O-6 (lazysite-oom-dev, notes/FINDINGS.md):

> A password change cannot go through the plan model: the plan and its journal are
> written to disk, so the old and new passwords would be kept at rest, and
> `res.users.change_password` is a model method the `call` change cannot express.
> Changing a password or turning two-factor on from an app needs a non-journalled
> credential operation (nothing stored, nothing echoed).

OOM built it as `core.credential` (vendored in `t/vendor/oom`, OOM 0.38). SM1164
left it out of its slice:

> `core.credential` (change a password, turn two-factor on or off, as the person)
> is a feature of its own on L4's sign-in dialog; it is noted here and filed when
> L4's next slice is planned.

The inbox triage of 2026-10-20 (Ad-7) listed it as open and waiting on a ruling.
The release manager's ruling, 2026-10-20, on "file it now as L4's next slice,
leave it until a page needs it, or never (the Odoo UI does it)":

> **"file it".**

This is that filing. It writes down what the slice would do and the questions the
engine should not answer for itself, and builds nothing.

# What OOM offers

`Odoo::Ops::Core::Credential` (`core.credential`, vendored at
`t/vendor/oom/lib/Odoo/Ops/Core/Credential.pm`) is an operation of a kind of its
own, `immediate`: it is never planned, and has no plan, run folder, journal or
approval, so no password is kept at rest. It runs as the person whose credential
the context holds, so a person changes their own password and never someone
else's. It has three actions and takes the secrets in memory, as `perform`
arguments, never as parameters:

```datatable
columns: Action | Secrets | What it does | Answers
widths: 3cm | 3.2cm | X | 4cm
---
change-password | old, new | Odoo's `res.users` `change_password(old, new)`, called as the person | `{action, answer}`; the password is not read back
totp-enable, step one | password | Opens Odoo's enable wizard (Odoo's identity check, with the password) | the wizard's number, the secret and the provisioning URI, once, to the caller
totp-enable, step two | password, code | Finishes the wizard with the authenticator's code; reads `totp_enabled` back | `two_factor: on` and `verified`; a wrong code is Odoo's refusal and the wizard stays
totp-disable | password | Odoo's identity check, then off; reads `totp_enabled` back | `two_factor: off` and `verified`
```

- Two-factor needs a web session (a `password` or `session` credential). A key-only
  connection is `refused/needs-session`; an Odoo without `auth_totp` is
  `refused/not-applicable`. The connection user, which is a key, can never do it.
- The guard's write scope names exactly `res.users` (`change_password`,
  `action_totp_enable_wizard`, `action_totp_disable`), `res.users.identitycheck` and
  `auth_totp.wizard`.
- OOM's audit records `event: credential`, the action, the login and the outcome (and a
  fault's category), never a value or a length. Odoo's refusals pass through in Odoo's
  words: a wrong old password, a password its policy refuses, a wrong code.
- OOM's vendored test lib carries `Odoo::Test::CredFake`, so the slice can be tested
  without a network.

# What lazysite has to build on

- The page endpoint `lazysite-odoo.pl` already takes `signin`, `signin_code` and
  `signout` POSTs, each behind the visitor token, the signed-in person's CSRF token, the
  address rule for sign-in (SM1159) and the site's login limiter
  (`Auth::LoginRate`, keys `odoo-ip=` and `odoo-login=`, five in five minutes).
- `Lazysite::Odoo::Session` holds the person's Odoo session as a signed cookie, so a
  context with the session credential exists for session bindings; the browser module
  `starter/assets/lazysite-odoo.js` already has a dialog whose password box is cleared
  before the answer arrives and which holds no storage.
- A local account already has the equivalent (`/account`, SM1042, SM1043): the current
  password for every sensitive change, counted against the sign-in limiter ("share the
  sign-in limit", ruled 2026-10-12), an audit row for each change and for each wrong
  password, and a changed credential ending the account's other sessions (SM1040).
- Sign-in, sign-out and the two-factor step stay in-process: oomd has no verb for them
  (SM1164, "What did not go through the daemon").

# What it would do

One engine function and one request shape for each action, on the page endpoint, from
a signed-in person only:

- `POST {credential: 'change-password', old, new, visitor_token}`;
- `POST {credential: 'totp-enable', password, visitor_token}` answering the secret and
  the provisioning URI once, then `POST {credential: 'totp-enable', wizard, password,
  code, visitor_token}`;
- `POST {credential: 'totp-disable', password, visitor_token}`.

`Lazysite::Odoo::credential` builds OOM's context from the person's session (the
session-binding context), calls `perform` with the secrets as arguments and returns what
is now true. The secrets are in memory for the call and in no URL, header, cookie, log,
record, plan or file, the way the sign-in password is (SM747 slice B). The answer is
`Cache-Control: no-store`. The browser module gains the calls and a small panel, in the
dialog's pattern: boxes of `type=password` with the right `autocomplete`, cleared before
the answer arrives, the secret drawn as text and the URI as a code the way
`::: account-2fa` draws it (SM1042), no storage, no `innerHTML`.

The slice is the person's own account page for a site whose people are Odoo users. It is
not an operator tool, and no binding names `core.credential`: it is not planned, so
the slice makes sure a binding that names it is refused at save, and checks that against
the binding validator before building.

# Questions for a ruling

1. **Re-authentication before a change.** OOM's actions already take the current
   password (the old one, or Odoo's identity check), so each request re-authenticates
   against Odoo. Proposed: that is the re-authentication, as on `/account` (SM1043 Q3),
   with no extra "recent sign-in" age check. The alternative is also asking for a fresh
   sign-in if the session is older than a bound, which an Odoo identity check may already
   enforce.
2. **Rate limits.** Proposed: every credential request counts before Odoo is asked
   against the sign-in limiter's two keys (`odoo-ip=`, `odoo-login=`), the same five in
   five minutes, so a stolen session cannot be used to guess the old password at a rate the
   sign-in refuses (the SM1043 ruling, "share the sign-in limit"). The alternative is a
   bucket of their own.
3. **Audit.** Proposed: the call record gains `phase: credential` with the action and the
   outcome and nothing typed, one `odoo-call` row in the shared audit trail with the actor
   `odoo:<login>` (or the session label on a site that has not opted in to the Odoo
   sign-in), wrong passwords included; OOM's `credential` event is its own record and keeps
   no value.
4. **Who may.** Proposed: the signed-in person on their own account only, in authenticated
   mode, over the page endpoint; no MCP tool, no control-API action, no scheduled or
   public mode, and a connection-user or visitor context is refused. The decision here is
   whether an operator needs a way to reset someone's password from lazysite (proposed: no,
   Odoo's own administrator screens do that).
5. **Sessions after a change.** A local account's changed credential ends its other
   sessions (SM1040). For an Odoo person lazysite holds the Odoo session cookie, and on an
   opted-in site (SM1160) a site session record per sign-in. Proposed: after a successful
   password change or a two-factor change, lazysite revokes the person's other site sids
   (not the current one), and on turning two-factor off clears the trusted-device cookie
   SM1157 keeps; what Odoo does to its own other sessions is Odoo's and is to be measured
   on 16 and 18 before the slice is built, not assumed.
6. **A site that requires two-factor.** Proposed: no setting at first, so a person who
   turns two-factor off is allowed to. The alternative is a key in the extension's config
   (for example `odoo_require_2fa: on`) that refuses `totp-disable` on that site, which would
   put policy in lazysite that Odoo can also hold.

# Security notes for the review

- The secret and URI of `totp-enable` step one are the only secrets in an answer. They go
  to the caller who proved the password, once, over the same TLS the sign-in uses, with
  `no-store`. The TOTP secret is OOM's and Odoo's; lazysite keeps none of it.
- A forged request needs the visitor token (bound to the `SameSite=Strict` visitor cookie)
  and the person's session cookie; the CSRF rule is the sign-out's.
- A stolen site or Odoo session cookie alone changes nothing: each action needs the current
  password.
- Odoo's policy messages ("a password its policy refuses") are passed on in Odoo's words,
  as OOM does; the engine adds no text of its own from a fault.
- The slice adds an authentication-changing interface, so it fires ADR 0007's
  new-authentication-method trigger when built and gets a register entry in
  `docs/SECURITY.md` with the release that carries it.

# Size

M. The engine function and the request shapes on the endpoint, with the limiter, audit and
session rules above (S to M); the browser module's calls and panel and the docs (S to M);
tests through the endpoint with OOM's `CredFake` and the sabotage runs, a test that no
secret reaches any file or log, and one that the answer is `no-store` (M). Nothing in OOM
or the extension's declarations changes.

# Not in this

- A person's own Odoo API key, the deferred L5 (ruled "keep deferred until an app needs
  it", 2026-10-20).
- Passkeys (later, as SM1160 ruled).
- Sign-in, sign-out and the two-factor step through oomd, which needs an OOM sign-in verb
  first.
