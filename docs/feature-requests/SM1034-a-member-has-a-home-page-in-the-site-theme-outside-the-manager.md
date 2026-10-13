---
id: SM1034
title: "SM1034: A member has a home page, in the site's theme, outside the manager"
subtitle: "WORK-PLAN-0154 P26. A brief for one page where a signed-in member manages their own account - password, two-factor, their bell, the messages they receive, their sessions - without manager access. Answers SM1010 R2 and folds in R1 and R4. Grounded in the engine at n444 (c9fcc20b)."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-12
raised-by: release manager, on SM1010's open items, 2026-10-12
area: accounts
status-note: "Ruled 2026-10-12: build phase 1. Built: SM1040 (other sessions end on a password change or 2FA disable), SM1041 (password_min_length, default 12), 1a /account and me-* (SM1043), 1b own notices (SM1044), 1c self-enrolled 2FA with manager enrolment removed (SM1042), SM1010 R5. Phase 2: R4's store and one-click link built (SM1073). Remains: the rest of phases 2-3."
---

# Ruled

The release manager, 2026-10-12. Recorded in the words given; where a ruling
settles a question below, the ruling stands.

- **"Accept, build phase 1"**, with the brief's recommended answers:
  - Q1: `me-*` actions on the control API; the session-less unsubscribe goes
    on the auth CGI, later.
  - Q2: on by default, with an `account_page` switch to turn it off.
  - Q3: re-authenticate per sensitive request - the current password; plus a
    current 2FA code to disable 2FA or regenerate recovery codes.
  - Q4: members may set a display name that cannot copy another account's
    login or display name (phase 2).
  - Q5, Q6, Q8, Q9 as the brief recommends: land at `/` with a link to
    `/account`; `manage_notifications` reaches the notify handler page (the
    per-type rule limits it to notify handlers).
- **A separate security item, "Fix now"**: any password change (own, an
  operator's `passwd`, a redeemed reset or claim link) and any 2FA disable
  revokes that account's OTHER sessions; the current session stays. Its own
  SM (SM1040), its own branch first, test and sabotage.
- **"Min 12, configurable"**: `password_min_length` in lazysite.conf, default
  12, applied to every way a password is set (users tool add and passwd,
  claim and reset redemption, setup-sysop, me-password); existing passwords
  keep working until changed. SM1041, its own branch.
- **2FA, "Self-enrol only"**: members enrol their own 2FA (phase 1c); managers
  can only reset or disable someone's 2FA and never see a secret or recovery
  codes; until 1c lands manager enrolment stays so nobody is locked out - so
  manager enrolment is removed in the same branch as 1c, not before. SM1042.

Build order, each its own stacked branch: SM1040 (n446), SM1041 (n500), phase
1a (SM1043), phase 1b, phase 1c with the removal (SM1042), then SM1010 R5.

# The ask

The release manager, 2026-10-12, asked about notification phase 1's open items
(SM1010 R2: members have no surface to read the per-member bell; R5: a
`manage_notifications`-only group cannot reach the handler page; R1: over-cap
messages are refused rather than digested; R4: no one-click unsubscribe
endpoint):

> "maybe we need a user home page, that uses the site theme and sits outside
> manager, offering basic functions, password, 2fa, bell etc."

Grades: **(A)** read in the code at n444 (c9fcc20b), cited file:line; **(B)**
inferred from code read, or a proposal. Nothing here was run.

# What the engine has today

## Two surfaces, and a member has neither

- **The manager** is `/manager/*`, rendered with its own layout
  (`lazysite/manager/layout.tt`) and served only to an account whose groups
  grant the `ui` capability (`handle_manager_path`, lazysite-processor.pl:595,
  the check at :615; `_is_manager`, lazysite-processor/auth.pm:285-300). A
  signed-in account without `ui` gets a terminal "forbidden" page, not the
  manager. (A)
- **Content pages** render with the site's layout and theme. An `auth:
  required` page receives `auth_user`, `auth_name` (the display name, SM743),
  `auth_email` and `auth_groups` (`%AUTH_CONTEXT`, lazysite-processor.pl:1178-
  1185). It cannot call anything server-side; its only route to an action is
  its own JavaScript. (A for the variables; B that nothing else exists, from
  reading the render path.)
- **The admin bar** on content pages is for managers only: Manage, Edit, the
  no-password warning and Sign out are all inside `if ($is_manager)`
  (lazysite-processor/layout.pm:942-976). A member has no account control on
  the site at all; the starter's `members.md` hand-writes a sign-out link. (A)
- **A member's sign-in lands on `/`**: only a manager is sent to a start page
  or the manager's account sheet (`_login_is_manager`, lazysite-auth.pl:344).
  (A)

## The system pages and their fallback chain (SM201)

- `%SYSTEM_PAGES` is the fixed set `login claim 402 403 404`
  (lazysite-processor.pl:160). Each resolves the per-domain content root, then
  the primary docroot, then the protected engine default under
  `lazysite/templates/system/` (`_system_page_md`, :162-171), so a deleted copy
  self-heals and an agent cannot delete the default. (A)
- `/forgot` and `/logout` are ordinary starter content pages
  (`starter_role: infrastructure`), not in that set, so a site that deletes
  them loses them (starter/forgot.md, starter/logout.md). (A)
- The system pages post to the auth CGI with hand-written forms, the stated
  exception to the native-forms rule (SM361, starter/forgot.md:35-50). (A)
- The login page already asks for a two-factor code (system/login.md:124) and
  already has a "you are already signed in" panel shown by the `lzs_session`
  marker (:113). (A)

## The starter's account pages

None. A search of `starter/` for account, me, profile, settings and password
finds only the login, claim and forgot pages, and the manager's own pages. (A,
searched)

## Changing one's password today

- **Self-service by mail only.** `/forgot` mints a single-use claim and mails
  it to the account's address, only when SMTP is configured and the account is
  interactive (`handle_forgot`, lazysite-auth.pl:850; `_forgot_dispatch`, the
  SMTP check :874, `ui_enabled` :894). Without SMTP, operators are told on the
  bell to issue a setup link by hand (:874-890). (A)
- **Through the manager's Users page**, the `users` action's `passwd` verb. The
  users tool already lets an actor change their own password
  (`$actor eq $user`, tools/lazysite-users.pl:963) - but the `users` action is
  gated on `manage_users|create_sub_users|delegate_sub_user_creation` on the
  cookie channel (ControlApi/Actions.pm:782), so a member never reaches it. (A)
- **No current password is asked for** by `passwd`; it is an administrative
  set (`cmd_passwd`, tools/lazysite-users.pl:945-971). (A)
- **Changing a password signs nothing out.** `not_before` - the "signed out
  everywhere" marker - appears nowhere in tools/lazysite-users.pl; neither
  `passwd` nor `claim-redeem` writes it. A stolen session survives the
  password change it prompted. (A, searched)
- **No password policy** beyond non-empty (`claim-redeem`,
  tools/lazysite-users.pl:2668). (A)

## Two-factor authentication

- **It exists.** TOTP (RFC 6238) with eight single-use recovery codes, stored
  hashed; enrolment is pending until a code confirms it, so an unconfirmed
  set-up cannot lock anyone out (`cmd_mfa_enroll` :2760, `cmd_mfa_confirm`
  :2818, `cmd_mfa_verify` :2839 with replay refusal by `totp_last_step`;
  enforced at sign-in, lazysite-auth.pl:508-519). (A)
- **Only a user manager can enrol it**, for someone else, on the Users page
  (starter/manager/users.md:1483), and in doing so sees that person's TOTP
  secret and recovery codes. A delegate cannot (`mfa-*` are not in
  `%DELEGABLE`, Manager/Users.pm:317-322), and a member cannot reach the
  action at all. There is no verb to regenerate recovery codes short of
  disable-and-enrol. (A)
- `mfa_required` is read and cleared but nothing sets it: there is no "this
  group must use 2FA" policy (Auth/Verify.pm:178; users tool :2805). (A,
  searched)

## The bell and the per-member notice (n444)

- A rule's bell notice is written with `to` = the account
  (`Lazysite::Notify::bell_for`, Notify.pm:842), and the one reader shows an
  addressed notice only to its addressee (`_for_principal`,
  Manager/Notices.pm:87-92). (A)
- **The reader's door is `notifications`** on both channels
  (`_notices_gate`, Manager/Notices.pm:277-287; Actions.pm:175) - an operator
  capability. A member holding it would also see every broadcast (operator)
  notice, because `_for_principal` passes any notice without a `to`. (A)
- **The window is site-wide.** The reader keeps the last 100 lines of one
  shared store (`_read_notices`, :54-60). On a site of 700 members, one
  member's addressed notices compete for those 100 lines with everyone
  else's and with the operators'. (A for the bound; B for the effect.)
- Read state is per principal already (`notices-seen.json`, `action_notices_seen`,
  :211), so a member surface needs no new store for it. (A)

## Unsubscribe (SM1010 R4) and what a member may refuse

- Every rule's email carries an unsubscribe link and `List-Unsubscribe` unless
  the rule turns it off; the link is the operator's own page,
  `unsubscribe_path` (Outbox.pm:446-451, :500; Handlers.pm:262-268,
  :911-920). (A)
- **Nothing in the engine records a refusal.** The outbox job sends to every
  resolved recipient, subject only to the per-recipient cap; there is no
  suppression list, and by ruling rules do not consult the account's
  `notify_email` opt-in (Outbox.pm:18-23, :530-640). (A)
- **The cap refuses, it does not fold** (SM1010 R1): an over-cap recipient is
  audited and marked refused (Outbox.pm:581-585). (A)

## Follows and subscriptions

- A member's follow row is theirs (`row_policy: personal`, `created_by` from
  the actor) and they may delete it through the data endpoint, which verifies
  its own session cookie and requires a CSRF token it mints itself
  (lazysite-data.pl:187-212, delete at :309-312). Deleting the row is the
  unfollow. (A)
- A page can list the viewer's own rows with `db:<table>(mine)`, rendered per
  viewer and never cached (lazysite-processor/sources.pm:470-487). P17's
  ruling ("Allow own rows" past the table's read rule) is recorded in
  WORK-PLAN-0154 and is not marked built there. (A for (mine); B for P17's
  state, from the plan.)
- Nothing knows which tables are "follow" tables: they are a site's own
  design. (B)

## Display name and other account settings

- `display_name` is stored and shown (SM642, SM743, SM778) but **is not
  self-service**: the users tool's self-service list is `start_page
  notify_email` (tools/lazysite-users.pl:419), although the comment beside it
  calls `display_name` a preference. (A)
- `notify_email` is self-service in the tool but no screen offers it to a
  member. (A)
- `email` is set by the operator or the approve flow; there is no verified
  flag (SM1010 Q6) and no self-service change. (A)

## Sessions and keys

- `sessions-list`, `session-revoke`, `user-revoke` (sign out everywhere),
  `keys-list` and `key-revoke` all require `manage_users` on the cookie
  channel and list **every** account's sessions (Manager/Sessions.pm:122-130,
  :153-182). A member cannot see or end their own sessions, except the current
  one by signing out (which revokes its sid, lazysite-auth.pl:577). (A)
- Access keys (tokens) are minted only by user managers (`token` is in
  `%ACTOR_FORBIDDEN`, tools/lazysite-users.pl:399), and an account that can use
  the manager may not drive the API with one (SM127). A member home has no key
  to manage. (A for the gate; B for the conclusion.)

## What a signed-in non-manager can call today

The control API takes any verified session cookie (lazysite-manager-api.pl:333
onwards) and then gates each action by capability (:695-735). Run against the
declarations (tmp/sm1034-open-actions.pl, read-only), the actions with no
capability of their own on the cookie channel are: the introspection set
(`whoami`, `describe-capabilities`, `actions-list`, `csrf-token`, `version`,
`display-names`, `nav-read`), the content-file family that self-authorises
per file through ACLs (`save`, `read`, `list`, `move`, ...), and the actions
with a bespoke gate - of which only **`start-page` / `start-page-set`** are
self-service for any account (`_start_page_subject`, Manager/StartPage.pm:322-
336), while sessions, keys and notices refuse a member. (A)

So the precedent exists: an action whose subject defaults to the caller and
which refuses anyone else's account without `manage_users`. The CSRF token is
per account and hourly (`generate_csrf_token`, Auth/Session.pm:141-157), minted
by `csrf-token` for any signed-in caller (lazysite-manager-api.pl:575), and the
gate covers every POST (:572). The site CSP allows `connect-src 'self'` and
scripts from `'self'` (SecurityHeaders.pm:152-162). A page in the site theme
can therefore call the control API from an engine-shipped script with no CSP or
CORS change. (A)

## Layout components

A `::: <name>` fence renders `components/<name>.tt` from the active layout, else
a built-in under `lazysite/templates/components/`; a layout's component of the
same name wins (lazysite-processor/components.pm:30-38). The built-in `::: qr`
already renders a QR code from a bundled script (templates/components/qr.tt).
(A)

## Multi-domain

The session cookie carries no `Domain=` attribute (lazysite-auth.pl:360), so a
sign-in belongs to one host, and the SM201 chain already finds a system page
per domain content root. (A)

# The design

## Shape

1. **A system page, `/account`**, added to `%SYSTEM_PAGES` with an engine
   default `lazysite/templates/system/account.md` (`auth: required`), so it
   renders in each domain's own layout and theme, self-heals if deleted, and a
   domain may override it in its content root. (B)
2. **Built from built-in components**: `::: account-password`,
   `::: account-2fa`, `::: account-sessions`, `::: account-bell`,
   `::: account-messages` (phase 2), each a template plus one engine-shipped
   script under `/lazysite-assets/`. The default page is a Markdown page of
   those fences; a site that wants another arrangement writes its own
   `/account` with the same fences, and a layout may restyle any of them by
   shipping a component of the same name. No hand-written form HTML reaches
   content (the SM361 rule kept). (B)
3. **A closed family of `me-*` control-API actions** whose subject is always
   the caller - never a parameter. Cookie-only (a token client is refused, as
   `notices-seen` is today), POST for every write, CSRF-gated by the existing
   gate, audited by the existing block, declared in Actions.pm so the parity
   lints (22, 58, 23, 218) hold them. A new declaration field, `self => 1`,
   says the action needs no capability and acts only on `$auth_user`;
   t/lint asserts that no `self` action reads a username, login or account
   parameter. (B)
4. **No new capability.** Every signed-in, interactive (`ui` flag) account
   gets the page; nothing in it grants anything. An operator switch turns it
   off (below). (B)

Why the control API and not the auth CGI or a third endpoint: the manager API
already owns the CSRF gate, the audit block, the action reference and the
start-page precedent; the auth CGI owns unauthenticated flows (sign-in, claim,
forgot) and stays that way; a third endpoint is a third copy of the session
check, which is the SM402 lesson (lazysite-data.pl's header says why it had to
be one). One exception: the one-click unsubscribe (phase 2) must work without
a session and goes to the auth CGI. (B)

## What the page offers

```datatable
columns: Function | Exists today | Must be built | Phase
widths: 3cm | 6cm | 6cm | X
bold: 1
tone: light
---
Who am I | `whoami`; `auth_name`, `auth_email` in the page | `me`: login, display name, address (shown, not editable), 2FA state, groups by name | 1
Change password | `cmd_passwd` allows `actor eq user` (users tool :963); members cannot reach it | `me-password`: current password + new, verified in process; on success sign out every other session (`not_before`) and re-mint this one; a minimum length the operator sets | 1
Own sessions | registry + revocation, `manage_users` only, all accounts (Sessions.pm) | `me-sessions` (own rows only, current marked), `me-session-revoke` (own sid only), `me-signout-everywhere` | 1
Own bell | addressed notices, per-principal read state (Notices.pm) | `me-notices`, `me-notices-seen`: addressed notices only (`to` = me, never broadcasts), no capability | 1
2FA enrol / confirm / disable | `mfa-enroll`, `mfa-confirm`, `mfa-disable` (users tool); manager-only | `me-mfa-enroll` (password first), `me-mfa-confirm`, `me-mfa-disable` (password + a current code), `me-recovery-codes` (regenerate; password + code); QR by the built-in component | 1
Messages I receive (R4) | the link and header point at the operator's page; no suppression | a suppression store consulted by the outbox job; a signed one-click endpoint (RFC 8058); `me-messages` lists rules that have written to me, `me-message-stop` / `-resume` | 2
Mail me my notices | `notify_email`, self-service in the tool, no screen | a toggle through `me-settings` | 2
Display name | stored, shown; not self-service (users tool :419) | `display_name` in the self-service list, through `me-settings` (Q4) | 2
Follows / subscriptions | own rows + delete via the data endpoint; `(mine)` | none in the engine: the site lists its follow table with `db:<table>(mine)` on its own `/account`, and a documented example ships | 2 (docs)
Address change | operator-only; no verified flag | a confirmed change (mail to the new address, then the old one told) | 3
Digest preference (R1) | cap refuses | fold over-cap events into the next message (R1, engine); later a member's per-rule "immediately / daily" | 3
Own form submissions | the stored submission carries no name (SM1018) | nothing to list; a site lists its own table rows with `(mine)`. Not proposed | -
Access keys | minted by user managers; SM127 keeps manager accounts off tokens | nothing: shown as "none" if absent, else read-only | -
```

(B throughout, on the (A) facts above.)

## Security model

- **A member acts only on their own account, by construction.** No `me-*`
  action takes an account name; the subject is `$auth_user` from the wrapper's
  verified cookie. A session id or notice id given to `me-session-revoke` /
  `me-notices-seen` is checked to belong to the caller before it is acted on
  (an id of someone else's session answers "not found", never "forbidden",
  so ids cannot be probed). (B)
- **CSRF**: the existing method-keyed gate (Manager/Csrf.pm) covers every POST;
  the page's script fetches `csrf-token` and sends `X-CSRF-Token`. The cookie
  is `SameSite=Lax` (lazysite-auth.pl:360). (A for the gate; B for its use.)
- **Re-authentication for sensitive changes**: the current password with the
  request, verified in process, for a password change, 2FA enrol, 2FA disable,
  recovery-code regeneration and (phase 3) an address change; a current TOTP
  or recovery code as well to disable 2FA or regenerate codes. Per request, not
  a "recently signed in" window: no session state to add, and nothing to steal
  from a session that has not got the password. (B)
- **After a password change or a 2FA disable, every other session ends**
  (`not_before` = now, then a fresh cookie for this one) - closing the gap that
  today leaves a stolen session alive (A for the gap). (B)
- **Rate limits**: password and code checks count against the same per-IP
  limiter as sign-in (`check_login_rate`, lazysite-auth.pl:1312, a switchable
  extension) and a per-account bucket, so a stolen session cannot brute-force
  the password behind it; TOTP replay is already refused (`totp_last_step`).
  (B)
- **Audit**: every `me-*` write is a row in the audit trail as the account
  (`user-passwd`, `user-mfa-*` already exist as audit actions,
  tools/lazysite-users.pl:276, :297-299); a failed re-authentication is a
  `denied` row. Secrets never: not the password, the TOTP secret, or a
  recovery code. (B)
- **Secrets shown once**: the TOTP secret and recovery codes are returned only
  to the account they belong to, once, as enrolment does today - and the Users
  page stops showing another person's secret (Q6). (B)
- **Not offered to an agent account**: an account with `ui: false` cannot sign
  in interactively (lazysite-auth.pl:498), so never reaches the page; `me-*`
  refuse a token. (A for the gate; B for the design.)
- **What the operator configures** (lazysite.conf, per domain where a domain
  sets it): `account_page: enabled|disabled`; `account_2fa: enabled|disabled`
  (enrolment offered); `password_min_length` (default 12, applied to
  `me-password`, `claim-redeem` and `passwd`); later `account_address_change`.
  Disabled means the page answers 404 and the `me-*` actions refuse with the
  setting's name. A `manage_users` operator keeps every power they have today
  (reset 2FA, sign a user out). (B)
- **Multi-domain**: one account store for the instance, so the page on any
  domain acts on the same account; the session is per host (A, the cookie has
  no `Domain=`), so a member signs in on each domain they use, as today. A
  domain's `allowed_groups` already decides whether the account may reach that
  domain at all. (B)

## How it renders

A system page with the site theme, as `/login` is: the page is Markdown plus
TT, the components are server templates with an engine script that calls the
`me-*` actions. The page is `auth: required`, so it is never cached (the
processor already marks every non-public page protected,
lazysite-processor.pl:1187-1201). A member who is not signed in is sent to
`/login?next=/account`; one with the account page disabled gets 404. (A for
the cache rule; B for the rest.)

Where people find it: the login page's "already signed in" panel links to it;
a member's sign-in with no destination may land there (Q8); a layout may link
to `/account` from its own header (a `[% IF authenticated %]` block, as layouts
already do for sign-in). The manager's account sheet keeps the start page and
gains a link to `/account` rather than a second copy of these controls. (B)

## MCP and API parity

None for the `me-*` family, deliberately: they are a person's own credentials
and read state, and SM918 already ruled per-principal read state out of the
token door (t/lint/23's reason for `notices-seen`). An agent's own notices stay
on `read_notices` with `notifications`. The actions are listed in
`actions-list` as cookie-only, with the reason. (A for SM918's rule as recorded
in Manager/Notices.pm:188-206; B for the rest.)

## SM1010's open items

- **R2 (a member surface for the bell)**: answered - `::: account-bell` on
  `/account`, over `me-notices`, which shows only notices addressed to the
  caller and needs no capability. The site-wide 100-line window (A) is the
  limit to fix first: an addressed notice should be read from a per-account
  slice (phase 1b keeps the shared store and widens the window for addressed
  reads to the account's own lines; a per-account store is phase 3 if it is
  still slow). (B)
- **R4 (one-click unsubscribe)**: folded in as phase 2. The link becomes
  `/cgi-bin/lazysite-auth.pl?action=unsubscribe&t=<token>`, the token an HMAC
  over (rule id, recipient key, issue time) under the auth secret, so it needs
  no session and names nothing in clear; GET shows a confirmation page in the
  site theme, POST (and RFC 8058 `List-Unsubscribe-Post: List-Unsubscribe=One-
  Click`) records a suppression. The outbox job skips a suppressed (rule,
  recipient) and audits the skip. For an account recipient, `/account` lists
  the rules that have written to them (from the ledger's hashed recipient
  keys) with stop and resume. `unsubscribe_path` stays as the rule's optional
  "manage your subscriptions" page. (B)
- **R1 (folding over the cap)**: an engine change in the outbox, not the home
  page's - but its natural home for the member's side is a per-rule
  "immediately / daily digest" preference on `/account` (phase 3). (B)
- **R5 (the handler door)**: not the home page's; a manager question. Our
  recommendation is in Q9. (B)
- **R3, R6, R7**: unchanged by this brief.

## Phases and sizes

```datatable
columns: Phase | What | Delivers | Size
widths: 1.5cm | 9cm | 4cm | X
bold: 1
tone: light
---
1a | `account` in `%SYSTEM_PAGES` and its engine default; the `self` declaration and its lint; `me`, `me-password` (current password, minimum length, sign out the others), `me-sessions`, `me-session-revoke`, `me-signout-everywhere`; `account_page` switch; docs | the minimal slice: a member can change their password and end their sessions | S
1b | `me-notices`, `me-notices-seen` (addressed only); `::: account-bell`; the addressed-read window | SM1010 R2 | S
1c | `me-mfa-enroll/-confirm/-disable`, `me-recovery-codes`; `::: account-2fa` with the QR; `account_2fa` switch | self-service 2FA | S
2 | R4: suppression store, the signed one-click endpoint, the outbox skip, `me-messages`; `me-settings` for `notify_email` and (Q4) `display_name`; a documented follow-list example with `(mine)` | SM1010 R4, preferences | M
3 | confirmed address change; digest preference with R1's folding; per-account bell store if needed; a "2FA required" group policy (`mfa_required`) | the rest | M
```

Phase 1 whole: M. All phases: L. (B)

# Open questions for the release manager

1. **Where the actions live.** Recommendation: a closed `me-*` family on the
   control API, declared `self`, cookie-only; the auth CGI only for the
   session-less one-click unsubscribe. Not a third endpoint.
2. **Default on or off?** Recommendation: on, on every site, with
   `account_page: disabled` to turn it off - it grants nothing, and the
   alternative leaves members with no way to change a password where SMTP is
   not configured.
3. **Re-authentication: per request or a "recently signed in" window?**
   Recommendation: per request - the current password with each sensitive
   change, plus a current code to disable 2FA or regenerate recovery codes.
4. **May a member set their own display name?** It is shown to others (SM778),
   so a member could call themselves "Site administrator". Recommendation:
   yes, through `me-settings`, refusing a name equal to another account's login
   or display name; the operator can turn it off.
5. **Sign out other sessions on a password change?** Recommendation: always,
   and on a 2FA disable; also for an operator's `passwd` and a claim redeemed
   (today none of the three does).
6. **The Users page's 2FA enrolment for another person.** Recommendation:
   remove enrolment for others once `/account` has it, keep "reset 2FA"
   (disable) for `manage_users`, so no operator ever sees a member's secret.
7. **Unsubscribe scope.** Recommendation: per (rule, recipient), for account
   and address recipients alike; an account may resume from `/account`, an
   address only by the operator (no session to prove it).
8. **Where a member lands after sign-in with no destination.** Recommendation:
   unchanged (`/`), with `/account` linked from the login page's signed-in
   panel; a site may set `auth_member_landing: /account` later if asked.
9. **SM1010 R5: widen the handler door to `manage_notifications`?**
   Recommendation: yes - add it to `handler-list`, `handler-save` and
   `handler-delete`'s gate; the per-type capability rule already confines a
   `manage_notifications`-only holder to notify handlers (Handlers.pm:29-37,
   :233-235), so the door admits them to nothing else.

# Done when

A signed-in member with no manager access opens `/account` in the site's own
theme on any domain and, acting only on their own account, changes their
password (and every other session ends), sees and ends their sessions, reads
and clears the notices addressed to them, and enrols, confirms and disables
two-factor with recovery codes; every change is audited, CSRF-gated and
re-authenticated where sensitive; an operator can turn the page off; and a
message's unsubscribe link stops that rule writing to that recipient, in one
click, without a sign-in.
