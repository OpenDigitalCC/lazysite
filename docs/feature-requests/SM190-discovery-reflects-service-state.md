---
title: "SM190 - Discovery documents must reflect the live service state"
subtitle: "The .well-known/ discovery docs advertise endpoints regardless of whether the service is enabled - so they name endpoints that 404, and get render-cached. Gate them on their service flag and serve them live."
brand: plain
status: candidate
status-note: "PARTIAL - core IMPLEMENTED on claude/sm188-190-field-fixes (2026-07-21, commit 0a300ff): the processor 404s .well-known/oauth-* when oauth_enabled is off (not advertised, not cached). DEFERRED: making ai-partner code-served from live config, and a lazysite-check probe of advertised endpoints. Awaiting gate + vcs-review + release."
---

# SM190 - Discovery documents must reflect the live service state

## Why

lazysite publishes several `.well-known/` discovery documents that a client (or
an agent) reads to learn the site's endpoints. Two of them advertise endpoints
WITHOUT regard to whether the corresponding service is actually enabled, so they
name endpoints that 404 - and, being ordinary pages, they get render-cached:

- `.well-known/oauth-authorization-server` + `.well-known/oauth-protected-resource`
  ship as `api: true` content pages (`starter/.well-known/oauth-*.md`). They are
  processor-rendered and cached (stored as `.html`, the cache's naming for any
  render), and the processor does NOT gate them on `oauth_enabled`. But
  `lazysite-oauth.pl` 404s the real authorize/token/register endpoints when
  `oauth_enabled` is off (the default). So on a typical site the discovery
  metadata advertises an OAuth AS that is switched off.
- `.well-known/ai-partner` is a STATIC operator-published document (not
  code-served) that the partner brief points clients at. On a field site
  (marriage-morris) it advertised the pairing-key `exchange` endpoint while
  `token_exchange_enabled` was off - so a connecting agent was told to POST to an
  endpoint that returned the disabled-service response, and the mismatch cost a
  misdiagnosis (read as "not deployed"). A hand-published doc also drifts from the
  real grant over time.

General class: a discovery document should advertise ONLY what actually answers.

## The good pattern already exists

`/.well-known/lazysite-instance.json` (SM156, `lazysite-processor.pl`) is served
DIRECTLY by the processor - dynamic, `Cache-Control: no-store`, computed per
request, before auth. It reflects reality and never caches. That is the model.

## Design

1. Gate the service-specific well-known docs on their service flag. In the
   processor, `/.well-known/oauth-*` return 404 when `oauth_enabled` is off (and
   answer only when on), matching `lazysite-oauth.pl`'s own killswitch. A 404 is
   not cached, so the stale-cache-advertising-a-disabled-service problem
   disappears with the same change. Keep the `api:` source pages for the ON case;
   just add the gate.
2. Make `ai-partner` code-served, not a static file. Generate it from the live
   config (like `lazysite-instance.json`): advertise the pairing / exchange /
   rotate / control / WebDAV endpoints only for the services that are enabled, and
   the current capability / scope shape. It then cannot drift and cannot advertise
   a disabled endpoint - omit the token-exchange entry unless
   `token_exchange_enabled`, WebDAV unless `webdav_enabled`, and so on.
3. Deploy-check: verify advertised endpoints answer. Extend `lazysite-check`
   (which already HTTP-probes `/dav/` via `--check-dav`) to fetch each
   `.well-known` discovery doc and probe the endpoints it advertises, warning when
   a doc names an endpoint that 404s. This catches both the "service off but
   advertised" case and a genuine deploy gap - the original marriage-morris ask:
   "the well-known generator should only advertise endpoints that actually
   answer."

## Not a security hole

Discovery metadata is public by design (no secrets). The issue is
correctness / consistency: advertising endpoints that don't answer sends clients
and agents down wrong paths (a real support cost, as the marriage-morris incident
showed), and caching a disabled service's advertisement compounds it.

## Tests

- `.well-known/oauth-authorization-server` returns 200 when `oauth_enabled` is on
  and 404 when off; a 404 leaves no render-cache entry.
- A code-served `ai-partner` omits the token-exchange endpoint when
  `token_exchange_enabled` is off and lists it when on.
- `lazysite-check` warns when a discovery doc advertises an endpoint that 404s.

Related: SM156 (`lazysite-instance.json` - the live-served model), the 0.9.0
service killswitches (`oauth_enabled` / `token_exchange_enabled` /
`webdav_enabled`), `lazysite-oauth.pl`, the partner brief in
`tools/lazysite-users.pl`, ADR 0006 (`api:` pages), and the 0.9.9 disabled-service
messaging fix (200 `{ok:0, code:service_disabled}`).
