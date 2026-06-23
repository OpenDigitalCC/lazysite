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

Starter pages: `claim.md`, `forgot.md`. Manager card gains an **email** field
and a **Generate setup link** action (and **Send set-password email** when SMTP
is configured).

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

## 13. Out of scope / deferred

- SSO / external IdP (OIDC, SAML) - the existing external-auth-proxy trust
  model already covers that case; SM072 is built-in auth only.
- WebAuthn / passkeys - `[DEFER]`; the login second-factor slot from batch 4 is
  the future extension point.
- Session invalidation on credential change - `[DEFER]` (§10).
- Admin-set passwords - explicitly removed as the default path; an operator may
  still set one via the CLI for break-glass, but the UI leads with claims.
