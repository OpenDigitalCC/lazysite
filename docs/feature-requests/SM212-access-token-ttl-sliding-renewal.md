---
title: "SM212 - operator-set, ceiling-capped access-token TTL with sliding renewal"
subtitle: "The lzs_ machine token (pairing exchange, used for WebDAV + control-API Basic auth) expires at a hardcoded 24h and has no refresh concept, so an automation account must re-rotate daily - a field agent proposed a daily cron. Make the TTL an operator-set per-account setting capped at 30 days, and renew it on use, so an active token never lapses and only genuine inactivity expires it. No cron, better security posture than one."
brand: plain
status: shipped
status-note: "SHIPPED 2026-07-26 (targeted at 0.9.16). Origin: the lazysite-sites agent's lzs_ token expired every 24h and it proposed a daily cron. Implemented as designed: a per-account token_ttl (Lazysite::Auth::Settings, floor 1h / hard ceiling 30d, resolve_token_ttl clamps even a hand-edited record), applied at exchange/rotate; sliding renewal folded into the already-throttled SM163 touch_credential (an account WITH a token_ttl renews on use so an in-use token never lapses; a default-TTL token is unchanged - hard 24h from issue); cmd_set token_ttl branch + parse_duration + effective_settings/keys-list surfacing; a Lifetime control (24h/7d/30d) on the manager Sessions & keys page. Tests in t/unit/users/10-token-lifecycle.t (ceiling/floor, 30d issue, resolver clamp, sliding-extends, default-no-slide)."
---

# SM212 - access-token TTL: operator-set, ceiling-capped, sliding

## Why

An automation account (the lazysite-sites agent) authenticates over **WebDAV**
and the control-API using the `lzs_` machine token it got by exchanging a pairing
key. That token expires at a **hardcoded 24 hours**. A site that is not edited
every day therefore loses access, so the agent proposed a **daily cron** that
calls `token-rotate` to keep the credential alive.

The cron works but is the wrong shape:

- It is operational debt - a scheduled job whose only purpose is to defeat an
  expiry the operator did not choose and cannot change.
- It is *worse* on security than doing nothing: the token (or a rotation
  credential) lives in cron env/logs, it rotates on a clock whether or not the
  account is active, and it fails **silently** if cron breaks - the access
  lapses exactly when nobody is watching.
- It papers over a missing capability rather than fixing it.

The elegant answer is to let the operator set a longer lifetime **and** renew it
on activity, so an in-use token never expires and only true inactivity lapses it.

## Current behaviour (located)

lazysite has two credential families, and they are asymmetric on renewal:

OAuth (`lzo_` connect code to Bearer access token) - MCP + control-API
: `lib/Lazysite/Auth/OAuth.pm`: `$ACCESS_TTL = 3600` (1h) with
  `$REFRESH_TTL = 30 * 86400` (30d) and a working `refresh_access` (RFC 6749
  `refresh_token` grant, rotating refresh). An OAuth-compliant client silently
  refreshes; continuous use rolls the 30-day window forward. This path already
  needs no cron. It does **not** cover WebDAV (Bearer is not accepted by
  `lazysite-dav.pl`), which is why the sites agent is on the path below.

Pairing (`lzp_` to `lzs_` token, HTTP Basic) - WebDAV + control-API
: `tools/lazysite-users.pl`: `$ACCESS_TOKEN_TTL = 86_400` (line 125, "24 hours"),
  hardcoded. Set on the credential record as `token_expires_at` at pairing
  exchange (~line 1598) and at `cmd_token_rotate` (~line 1618). A claim-set
  (password) credential deletes `token_expires_at` and is therefore **permanent**
  (~line 1772). Enforcement is SM071 Phase 2: `lazysite-dav.pl` `token_expired`
  (~line 1369) compares `time()` against `token_expires_at` and 401s; the
  control-API Basic path (`lazysite-manager-api.pl` ~line 173) and MCP verify
  (`lazysite-mcp.pl` ~line 222) read the same field. There is **no refresh
  concept and no renew-on-use** - the token is a fixed 24h window from issuance.

So the only levers today are "re-exchange the pairing key" or "rotate" - both of
which the operator can only automate with a cron.

## Proposal

Three parts, in priority order. Parts 1 and 2 are the change; part 3 is guidance.

### 1. Configurable, ceiling-capped TTL per account (`token_ttl`)

Replace the hardcoded `$ACCESS_TOKEN_TTL` at issuance/rotate with a per-account
`token_ttl` setting (seconds, or a friendly `24h` / `30d` form):

- Validated against a hard ceiling constant `TOKEN_TTL_MAX = 30 * 86400` (30
  days) and a floor (e.g. `1h`). A value over the ceiling is rejected, not
  clamped, so a misconfiguration cannot mint a year-long secret.
- **Default unchanged at 24h** when unset - the secure default is preserved; a
  long life is an explicit, deliberate opt-in for a specific automation account.
- Used in place of the constant wherever `token_expires_at = time() + TTL` is
  written today (exchange, rotate).

The sites agent then gets `token_ttl 30d` and its daily cron becomes, at worst, a
monthly re-exchange - 30x less churn, and aligned with the OAuth 30-day horizon
so the two families are finally consistent.

### 2. Sliding expiry (renew-on-use) - the important half

On each authenticated request, push `token_expires_at` forward by the account's
TTL, so a token that is used at all within its window never expires; only genuine
inactivity past the **full** window lapses it.

The insertion point already exists. `Lazysite::Auth::Settings::touch_credential`
(SM163, `Auth/Settings.pm:330`) is **already called from every credential path**
(control-API verify, WebDAV Basic, MCP verify), is **already throttled** to one
write per `$TOUCH_WINDOW` (300s) so a key hammering DAV does not rewrite
`user-settings.json` per request, and is already best-effort (a failure never
blocks the request). Sliding renewal is a few lines *inside the same throttled
write*: when it stamps `cred_used_at`, if the account has a live `token_expires_at`
and a `token_ttl`, also set `token_expires_at = now + token_ttl` (never *shorten*
it; never resurrect an already-expired token - only a currently-valid one slides).

Effect for the sites agent with `token_ttl 30d`: it has to be idle for a **full
30 days** to lose access. No cron, no rotation, no client change, works for a
plain WebDAV or `curl` client that cannot do OAuth refresh.

### 3. Where it fits, prefer OAuth

For anything the agent does over MCP or the control-API (i.e. not WebDAV), the
OAuth path already solves this with 1h access + 30-day rotating refresh and zero
new code. Worth pointing automation at OAuth for the non-DAV surface regardless
of this change; SM212 is specifically for the WebDAV/`lzs_` clients that OAuth
refresh cannot reach.

## Design detail

Storage and policy (`tools/lazysite-users.pl`, `lib/Lazysite/Auth/*`)
: A per-account `token_ttl` in the settings record (absent = default 24h).
  `TOKEN_TTL_MAX = 30 * 86400` and a floor enforced at the set and the
  issue/rotate sites. A single helper resolves "the TTL to apply for this
  account" so exchange, rotate and the slide all agree.

Sliding renewal (`lib/Lazysite/Auth/Settings.pm::touch_credential`)
: Extend the existing throttled stamp to also slide `token_expires_at` when a
  live TTL applies. Guard: slide only a token that is present and not yet expired
  (`token_expires_at > now`); never touch a permanent (claim-set) credential
  (no `token_expires_at`); never shorten. Stays best-effort and throttled - the
  300s window means the slide costs no extra writes.

CLI (`tools/lazysite-users.pl`)
: `token-ttl <user> <duration>` to set/clear (empty clears to default);
  surfaced in `effective-settings` / the Sessions & Keys view alongside the
  existing `token_expires_at` and `cred_used_at`. `token-exchange` / `token-rotate`
  report the resolved lifetime as they already do (they print "expires in Nh").

Manager UI (Users - Sessions & Keys)
: Where an account's key/expiry is shown, add the TTL control (a small select:
  24h / 7d / 30d, default 24h) for accounts that use a machine token, with a
  one-line note that a long-lived token renews on use and is revocable by
  rotating or clearing the credential. Advisory copy should make the tradeoff
  explicit (a longer window is a longer-lived standing secret).

Control-API / MCP surface
: The credential-status / whoami expiry fields already exist; they now reflect a
  sliding `token_expires_at`, so a client can still see its current lifetime. No
  new endpoint is required for the core feature.

Defaults and migration
: No migration. Existing `token_expires_at` records keep their meaning; absent
  `token_ttl` means 24h exactly as today. The feature is inert until an operator
  sets a longer TTL on a specific account.

## Security considerations

- **Short default preserved.** Nothing gets longer-lived by default; 24h remains
  the out-of-the-box window. Long life is a per-account, operator-set choice.
- **Hard ceiling.** `TOKEN_TTL_MAX = 30d` is enforced centrally, so no account -
  however configured - can hold a token beyond the OAuth refresh horizon.
- **Sliding + long TTL = a de-facto durable credential for an active client.**
  That is the intended outcome for a provisioned automation account, and it is
  strictly better than the daily-cron alternative it replaces: the secret is not
  copied into a scheduler, it is revocable at any time (rotate or clear the
  credential immediately invalidates it), and every use is audited via
  `cred_used_at`. The slide never resurrects an expired token, so revocation and
  natural inactivity-expiry both still bite.
- **Blast radius unchanged.** The token's *capabilities* are unchanged; only its
  lifetime policy moves from a hardcoded constant to a capped operator setting.

## Tests

- Unit (`Auth::Settings`): `touch_credential` slides a live token by the account
  TTL; does not slide when `now - last < TOUCH_WINDOW` (throttle holds); does not
  slide an already-expired token; does not touch a permanent credential; never
  shortens.
- Unit (`lazysite-users`): `token_ttl` set/clear/surface; ceiling rejects `> 30d`;
  floor rejects too-small; exchange and rotate apply the resolved TTL.
- Integration: a DAV request inside the window extends the deadline (a request
  after the original 24h but within a 30d sliding window still authorises);
  after a full idle window the token 401s on DAV, control-API and MCP alike.
- Guarantee/parity: the three verifiers stay in agreement on expiry semantics
  (extends the existing SM071 expiry coverage).

## Out of scope / follow-ups

- A grace/overlap window on `token-rotate` (old token valid briefly alongside the
  new one) is a separate, already-noted refinement and is not required here -
  sliding renewal removes most of the need to rotate at all.
- Bringing WebDAV onto the OAuth/Bearer path (so the `lzs_` family could be
  retired in favour of refresh tokens) is a larger, separate piece; SM212
  deliberately fixes the existing Basic path in place.
- Per-credential (rather than per-account) TTL, if an account ever holds more
  than one machine token, follows the same shape and can extend this later.
