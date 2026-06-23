---
title: "SM072: Self-service credentials and MFA-ready auth"
subtitle: "A single claim-token primitive for setup links, email reset, partner exchange - and a TOTP slot designed in from the start"
brand: plain
standard-margins: true
---

Status
: Draft specification (2026-06-23). Design only, no implementation in the tree. Extends SM070/SM071.

Author
: Claude (specification), with Stuart Mackintosh (design direction).

Target
: lazysite ≥ current main (post-SM071), branch `claude/hestia-install-fixes`.

Constraints
: Greenfield only - no migration of existing credentials. Self-contained scripts, no CPAN. `[DEFER]` marks work deliberately left for a later batch. Auth-security code: every batch lands with the suite green.

## 1. Summary

The operator should create an account and set its parameters, then the **user
provisions their own secret** - the operator never sets or handles a password.
SM072 introduces one primitive that satisfies this across every delivery
channel: a **claim token** - a single-use, short-lived, redeemable secret that
its holder exchanges to set up an account's credential.

Three flows are the same primitive wearing different clothes:

- a copy-paste **setup link** the operator hands over by any channel;
- an **emailed** version of that link (set-password on create, and forgot
  password), available only where the SMTP plugin is configured;
- the existing partner **pairing key**, finished with an HTTP exchange so an
  agent redeems its own access token.

The auth model is also laid out to accept **TOTP MFA** without rework: the
claim flow is the natural enrolment point, and login gains a second-factor
slot. MFA itself is built last (batch 4) but designed for now.

::: widebox
One primitive - a single-use, expiring, hashed **claim token** - underlies
setup links, email reset, and partner exchange. The operator sets params; the
holder of the claim sets the secret. MFA plugs into the same enrolment and
login points without changing it.
:::

## 2. Principles

Operator never holds the secret
: Account creation sets identity and capabilities only. The credential is set by the user redeeming a claim. The operator can generate and hand over a claim, but cannot read the resulting password or token.

Email is a transport, not a requirement
: The claim works as a copy-paste link with zero infrastructure. SMTP only adds automated delivery; nothing core depends on it.

Interactive vs machine, one model
: A claim yields a **password** for an interactive account (`ui` on) or a **token** for a machine account (`ui` off). WebDAV/API auth is unaffected by MFA - a `lzs_` token is already a separate strong secret.

Fail closed, leak nothing
: Single-use, short TTL, rate-limited, HTTPS-only, and generic responses (no account-existence disclosure). Disabled and token-only accounts cannot obtain an interactive password.

One live credential per account
: Minting a token, rotating it, or redeeming a claim replaces the previous secret - there is never more than one active credential. A fresh agent session that mints a new token thereby invalidates the old one: one agent, one live key. Token renewal on expiry (Flow C) is this same replace-in-place.

## 3. The claim-token primitive

A claim is minted against an account, shown once as a high-entropy string, and
stored only as a hash. It is redeemed once, within its TTL, to set that
account's credential, then cleared.

```datatable
columns: Property | Value
widths: 5cm | X
bold: 1
tone: medium
---
Entropy | 256-bit random, base32/hex; prefix marks purpose (lzc_ claim).
At rest | sha256 hash only (`claim_hash`); the raw value is never stored.
TTL | setup link 24 h (configurable); forgot-password 1 h. `claim_expires_at`.
Uses | exactly one; redeeming clears the claim. A second attempt fails generically.
Purpose | `set-password` (interactive) or `mint-token` (machine), from the account's `ui` flag at mint time.
Rate limit | per source IP and per account; reuses the SM070/71 token-bucket store.
Transport | HTTPS only; refused over plaintext.
```

This generalises the SM071 pairing key (`lzp_` → token exchange): the pairing
key is the `mint-token` purpose of the same primitive. SM072 unifies them so
there is one mint/verify/clear path.

## 4. Flow A - one-time setup link (no dependencies)

1. Operator creates the account, sets capabilities (the existing card).
2. Operator clicks **Generate setup link** on the card (next to *Generate
   credential*) - the API mints a claim and returns `…/claim?c=<raw>` once.
3. Operator hands the link to the user by any channel.
4. User opens it: the `/claim` page verifies the claim and presents either a
   **set-a-password** form (interactive account) or a **mint-and-reveal-token**
   action (machine account). The claim is consumed on success.

::: recommendation
Build Flow A first. It meets the objective - operator sets params, user sets
the secret - with no SMTP, no email address, and no new cryptography beyond the
claim primitive.
:::

**Operator-triggered reset.** The operator can issue a claim to an existing
account at any time - this is the admin's password-replacement mechanism, with
the admin never choosing the value. A plain claim is additive: the current
credential keeps working until the user redeems. A **Reset credential** variant
additionally **revokes** the current credential (clears its hash) so the account
cannot authenticate until the new claim is redeemed - the forced reset for a
lost, rotated, or compromised secret.

## 5. Flow B - email delivery (gated on SMTP)

Where the SMTP plugin (`plugins/form-smtp.pl` + `lazysite/forms/smtp.conf`) is
configured and the account has an `email`, the same link is delivered by mail:

set-password on create
: Creating a user with an email and no password offers **Send set-password email** - the claim link is mailed instead of copy-pasted.

forgot password
: `/login` shows a **Forgot password?** link (only when SMTP is present) → `/forgot` takes a username or email → if an account with that email exists, a `set-password` claim is mailed. The response is identical whether or not it matched.

Auth shells out to the existing SMTP plugin rather than introducing a second
SMTP stack; if SMTP is absent, the email affordances simply do not render.

## 6. Flow C - partner pairing-key HTTP exchange

The SM071 onboarding brief already carries a pairing key, but the exchange is
operator-only (CLI). SM072 adds the HTTP endpoint so an agent self-redeems:

```datatable
columns: Step | Actor | Action
widths: 3cm | 3cm | X
bold: 1
tone: light
---
mint | operator | partner-create issues a pairing key (the claim, mint-token purpose) in the brief.
exchange | agent | POST the pairing key to the exchange endpoint over HTTPS; receive a rotating lzs_ access token.
rotate | agent | re-exchange/rotate before expiry; an expired token returns 401.
```

This is Flow A's `mint-token` purpose exposed to the credential holder over
HTTP - no new primitive.

## 7. Flow D - TOTP MFA (designed now, built last)

MFA is an **additional check at interactive login**, orthogonal to
provisioning. It is specified here so the model accommodates it; implementation
is batch 4.

Enrolment
: At claim redemption (set-password), the page offers an optional **enable two-factor** step - show a TOTP secret + otpauth URI (QR), confirm one code, and issue hashed **recovery codes**. Also available as a card action later.

Verification
: `lazysite-auth.pl` login: after password verification, if `totp_secret` is enrolled, require a valid 6-digit TOTP (or a recovery code) before issuing the cookie. `mfa_required` may force enrolment.

Scope
: Interactive (password → cookie) login only. Token / WebDAV / manager-API auth is untouched - the token is the strong factor there.

Self-contained
: TOTP (RFC 6238) is HMAC-SHA1 over a time counter - Perl core (`Digest::SHA`) plus a base32 codec, no CPAN. The shared `totp_secret` is stored in `user-settings.json` under the same `0640`/`2770` protection as other credentials (noted tradeoff: no at-rest encryption; the auth dir is off the web and group-restricted).

## 8. Data model

New per-user keys in `user-settings.json` (settings-set / effective_settings),
alongside the SM070/71 set:

```datatable
columns: Key | Type | Purpose
widths: 4.5cm | 2.5cm | X
bold: 1
tone: medium
---
email | string | Delivery address for emailed claims (Flow B). Operator-set.
claim_hash | string | sha256 of the outstanding claim. Transient; cleared on redeem.
claim_expires_at | epoch | Claim TTL.
claim_purpose | enum | set-password \| mint-token.
mfa_required | bool | Force TOTP enrolment at next login (Flow D).
totp_secret | string | Base32 shared secret once enrolled (Flow D).
recovery_hashes | array | sha256 of one-time recovery codes (Flow D).
expires_at | epoch | Account-level expiry; after it ALL authentication fails (time-boxed access). Distinct from token_expires_at. Operator-set.
```

## 9. Endpoints and pages

```datatable
columns: Surface | Method | Role
widths: 5.5cm | 2.2cm | X
bold: 1
tone: light
---
/claim | GET | Claim page: set-password form or mint-token action (Flow A).
?action=claim | POST | Redeem a claim, set the credential, clear the claim.
/forgot | GET | Request-a-reset page (rendered only when SMTP present).
?action=forgot | POST | Mint a set-password claim and email it; generic response (Flow B).
?action=token-exchange | POST | Partner self-exchange of a pairing key (Flow C).
login flow | POST | Add the TOTP second-factor step after password verify (Flow D).
```

Starter pages: `claim.md`, `forgot.md`. Manager card gains an **email** field, a
**Generate setup link** action, and a **Reset credential** action (revoke +
fresh claim) - plus **Send set-password email** when SMTP is configured.

## 10. Security model

- Claims and recovery codes: 256-bit random, **hashed at rest**, **single-use**,
  short TTL, rate-limited per IP and per account.
- **Generic responses** everywhere - `/forgot`, `/claim`, and exchange never
  reveal whether an account or email exists, nor whether a claim was valid
  beyond success/failure.
- **HTTPS-only**; plaintext refused (matches `/dav`).
- A claim respects account state: **disabled** accounts and **token-only**
  (`ui` off) accounts cannot redeem a `set-password` claim.
- Redeeming a claim **invalidates outstanding sessions** for that account is
  `[DEFER]` - considered, not required for v1.
- TOTP secret at rest is group-restricted, not encrypted (no key management);
  documented, accepted for greenfield self-hosting.

## 11. Build sequence

Each row is one green-suite batch; later batches do not churn earlier ones.

```datatable
columns: Batch | Scope | Depends on
widths: 1.6cm | X | 3.5cm
bold: 1
tone: medium
---
1 | Claim primitive + /claim page + setup-link card action (MFA-ready stub). | -
2 | Email delivery: /forgot + Send-set-password-email, gated on SMTP. | Batch 1, form-smtp.
3 | Partner pairing-key HTTP exchange endpoint. | Batch 1.
4 | TOTP MFA: enrolment in claim, login second factor, recovery codes. | Batches 1-3.
```

## 12. Non-functional close-out

Per the project's five-dimension close-out, each batch carries:

```datatable
columns: Dimension | Bar for this work
widths: 3.2cm | X
bold: 1
tone: light
---
Coverage | Unit tests for mint/verify/expire/single-use/rate-limit of the claim; redeem→password and redeem→token; forgot generic-response; TOTP vector tests against RFC 6238 sample values; recovery-code single-use.
Quality | Self-contained, no CPAN; generic error surface; constant-time comparisons for hashes/codes.
Performance | Claims are O(1) file ops; rate-limit reuses the existing bucket store; no per-login cost unless MFA enrolled.
Security | The §10 model is the acceptance gate: enumeration, replay, brute-force, plaintext, and privilege (disabled/token-only) all covered by tests.
Docs | Update auth.md + the AI briefings; CHANGELOG entries per batch; this spec is the design of record.
```

## 13. Adjacent decisions (publishing-model review, 2026-06-23)

A review of the partner onboarding against the live briefings raised the
following. They are recorded here as the design of record; most extend
SM071's control API or sit beside SM072 rather than inside its four batches.

Config and themes - control API, not raw WebDAV [DECISION]
: Config-key changes and theme/layout *activation* (with HTML-cache invalidation) go through the token control API with a **key allowlist**, never a raw PUT of `lazysite.conf` - that file carries privilege-escalation keys (`plugins`, `auth_default`, `manager_groups`). WebDAV stays for content, assets, and layout/theme *files* under the `lazysite/layouts/` scope. The dav **deny-list enforces this server-side** regardless of any bootstrap prose (verified by test: `lazysite/auth`, `lazysite/forms/.smtp-password`, `lazysite.conf`, `lazysite/manager` are write-denied). Consequence for the plan: an agent's "manage config / activate theme" capability is **gated on the control-API release**; until then the operator performs those through the manager UI.

Account expiry [SM072 addition, near-term]
: A per-account `expires_at` (date, optional time) after which the account fails authentication outright - the operator grants time-boxed access ("one day, then auto-expire"). Independent of `token_expires_at` (which expires a single access token); `expires_at` expires the whole account whatever its credential. Enforced in login and verify-credential; surfaced as a date field on the card.

Machine-readable bootstrap + well-known path [roadmap]
: The onboarding brief gains a compact parseable block (partner, site, endpoints, auth, capabilities, scope, docs) alongside the prose, fetchable from a well-known path (e.g. `/.well-known/ai-partner`) and referenced from `llms.txt` - so a cold agent can start from a URL alone. The brief documents the grant; the token enforces it. The bootstrap is the write/discovery counterpart to `llms.txt`'s read/discovery index, and does exactly four jobs: identify, authorise, locate, point-to-docs.

Token presentation and rotation [SM071 control API]
: Basic-auth username = the partner id, password = the `lzs_` token (per-partner attribution in the access log, per-partner revoke). The exchange/rotation response returns `{token, expires_at}` so rotation is deterministic, not 401-driven.

Account type at creation + rename [SM072 addition, near-term]
: Choosing **Human (interactive)** or **AI / backend (token)** when adding a user drives the lifecycle - human shows the password field; AI creates with `ui` off + `webdav` on, so the card leads with the setup-link / onboarding brief. The row summary shows the type. Plus a **rename** action (updates the credential store, settings, group membership, and provenance references).

Per-page ownership + per-file ACLs [roadmap]
: Each page shows its created date and created-by/group; the owner can set read/write on their own files (a per-file ACL), enforced at the WebDAV / manager layer. For multi-author sites where authors want to limit who can modify their pages. Likely a sidecar/metadata model since content files have no native ACL.

Files page: list by type [roadmap]
: The manager Files page groups/filters files by type (e.g. all generated `.html`), so an operator can quickly review and selectively delete them - useful after content moves or theme changes leave stale cached HTML.

Manager shows the running version [roadmap]
: The manager interface prints the currently running lazysite version (from the install state / manifest), so an operator can confirm what is deployed.

Audit log UI [roadmap]
: The manager interface surfaces the existing `lazysite/logs/` audit trail - who changed what, when, and from where (IP) - as a readable page, with a per-user view reachable from that account's card. The data already exists (every `log_event` records actor/action/ip); this is the UI over it.

Agent introspection API [roadmap]
: An authenticated agent can query, over the control API, what it is actually allowed to do: its groups/access, the plugins present with their capabilities and status, and the themes/layouts available with their active/inactive status. This is the runtime, token-scoped counterpart to the static bootstrap block - the agent discovers its real grant rather than reading prose. Depends on plugins publishing capabilities (the email-detection gap noted for batch 2).

Lock propagation: editor <-> WebDAV [roadmap]
: A unified lock model so the manager's online editor and WebDAV class-2 locks see each other - a page open in the editor reports `423 Locked` to a `LOCK`/`PUT` over `/dav`, and a WebDAV lock blocks the editor. One lock store, both surfaces honour it.

Agent-editable navigation [SM072 addition, near-term decision]
: `lazysite/nav.conf` is currently write-denied over WebDAV (only `lazysite/layouts/**` is carved out). Make the nav agent-editable - either a WebDAV carve-out for `lazysite/nav.conf` gated by a capability (nav is benign, file-shaped, and natural to a publishing agent) or a control-API action (consistent with config-via-control-API). Recommendation: WebDAV carve-out, since nav carries no privilege-escalation keys, provided nav rendering is injection-safe.

Offline publish bundle [new feature, separate]
: For no-egress agents: assemble the in-scope file set once, then either transport it live over WebDAV or serialise it to a **docroot-relative archive + audited manifest** (target paths, create/overwrite, post-extract actions such as "clear HTML cache") for the operator to apply by hand. One file-set builder, two transports - unit-testable with no network. The apply step stays operator-supervised (a manifest to audit, not a script that auto-runs).

## 14. Out of scope / deferred

- SSO / external IdP (OIDC, SAML) - the existing external-auth-proxy trust
  model already covers that case; SM072 is built-in auth only.
- WebAuthn / passkeys - `[DEFER]`; the login second-factor slot from batch 4 is
  the future extension point.
- Session invalidation on credential change - `[DEFER]` (§10).
- Admin-*chosen* passwords - removed. The operator cannot pick a credential's
  value, but **can trigger its replacement** by issuing a new claim (the
  **Reset credential** action of §4): the old secret is revoked and the user
  sets a fresh one. A CLI `passwd` remains for break-glass only.
- Agent-initiated access request with owner approval - `[DEFER]`, a future
  **Flow E**: the inverse direction of this spec. Instead of the operator
  pushing a claim down, an agent (or user) *requests* access and is handed a
  URL for its upstream owner, who authenticates as manager and approves -
  releasing the credential. It reuses the same single-use claim primitive (the
  approval mints/redeems the claim), so nothing here precludes it. Recorded for
  a later cycle; not in batches 1-4.
