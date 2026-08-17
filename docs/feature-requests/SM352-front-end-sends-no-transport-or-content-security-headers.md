---
title: "SM352 - The front end sends no transport or content security headers"
subtitle: "`x-content-type-options`, `x-frame-options` and `referrer-policy` are all set correctly. `strict-transport-security`, `content-security-policy`, `permissions-policy` and `cross-origin-opener-policy` are absent on every response measured."
brand: plain
status: filed
---

# SM352 - three of seven

## What was measured

edge 0.10.12, anonymous, homepage and several content paths.

```datatable
columns: Header | Value
widths: 7.0cm | X
bold: 1
tone: medium
---
`x-content-type-options` | `nosniff`
`x-frame-options` | `SAMEORIGIN`
`referrer-policy` | `strict-origin-when-cross-origin`
`strict-transport-security` | **ABSENT**
`content-security-policy` | **ABSENT**
`permissions-policy` | **ABSENT**
`cross-origin-opener-policy` | **ABSENT**
```

Correct behaviour observed alongside, worth recording so this filing is
not read as a general indictment: the login-gated redirect carries
`cache-control: no-store`, and form pages carry `cache-control: no-store,
private`. The per-response caching decisions are being made deliberately.

## Priority order

**HSTS is the one to fix first.** The site is TLS-only and redirects to
`/login` for gated content, so a first request over plain HTTP is
downgrade-attackable in the ordinary way. It costs one header and no
content changes. The only care needed is the usual: start with a short
`max-age`, confirm nothing on the instance needs plain HTTP, then raise
it, and treat `preload` as a separate decision because it is effectively
irreversible.

**Permissions-Policy is nearly free.** lazysite installs no trackers and
the shipped themes use no camera, microphone or geolocation, so a
restrictive default denies capabilities nothing is asking for.

**CSP is the valuable one and the hard one.** The themes inline styles -
`/docs/api` served its whole theme block inline in the page - so a strict
policy will not fit today. That is an argument for
`content-security-policy-report-only` first, which costs nothing, breaks
nothing, and turns "we do not know what a policy would break" into a
measurement.

**COOP matters least here** and is worth taking only alongside CSP.

## Why it belongs in the engine rather than in operator advice

Every one of these is a per-response header, and the engine already sets
three of them plus per-path caching decisions. The site is served through
templates the project ships. An operator following the install docs gets
whatever those templates emit, and today that is a partial set with no
statement about the missing half.

[[SM293]] step 5 made the front door one rule and made routing testable
because *"the vhost templates could never be tested"* - which is how
[[SM248]], SM268 H17 and [[SM283]] each happened. Response headers are the
same category of thing: they live in the front end, they are invisible
until someone probes from outside, and they are exactly what a shipped
default should get right.

## Interaction worth noting

`X-Lazysite-Front` is also absent on this instance, so edge is on a stock
proxy template rather than the [[SM283]] one. That does not weaken gating,
because [[SM286]] moves protected content out of the served tree and the
31-extension sweep confirmed it gates. It does mean the header set is
whatever the stock template carries, and a site that HAS taken the SM283
template may already differ - so this should be measured on both before
being called a single default.

## The fix

Set HSTS and Permissions-Policy in the shipped templates and in
`FrontDoor`. Add CSP in report-only mode with a documented reporting
endpoint or a stated no-op, and record what it would break before making
it enforcing.

Then make it testable the way routing became testable: an integration
test that drives a real front end and asserts the header set, so the next
template that ships without them fails the gate rather than a field probe.

## Verification

- A response from a shipped template carries HSTS with a stated
  `max-age`, and the value is documented alongside the upgrade note.
- `permissions-policy` denies the capabilities the platform never uses.
- `content-security-policy-report-only` is present and the instance can
  report what it would have blocked.
- An integration test asserts the header set through a real server, for
  both the stock and SM283 templates.
- The existing three headers are unchanged.

## Related

[[SM283]] (the proxy template and its observable), [[SM293]] (front door
as one testable rule - the precedent for testing what the front end
emits), [[SM286]] (why gating does not depend on the header set), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
