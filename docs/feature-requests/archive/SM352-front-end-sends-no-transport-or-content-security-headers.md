---
title: "SM352 - The front end sends no transport or content security headers"
subtitle: "`x-content-type-options`, `x-frame-options` and `referrer-policy` are all set correctly. `strict-transport-security`, `content-security-policy`, `permissions-policy` and `cross-origin-opener-policy` are absent on every response measured."
brand: plain
status: shipped
status-note: "STEP 4 DONE 2026-08-18: THE SITE SIDE NOW EMITS NOTHING INLINE. The theme custom properties - the last inline block a visitor received - are written into the theme's asset mirror as `theme-tokens.css` by `_write_theme_tokens`, and the page links that file. THE FLASH WORRY WAS WRONG and is recorded because it nearly bought a nonce we did not need: a `<link>` in `<head>` is render-blocking, so the browser does not paint before it arrives and there is no unstyled frame. That worry belonged to the manager's SCRIPT prelude, which runs after paint, and conflating a stylesheet with a script is what made a solved problem look open. THE GENERATOR STAYS as the fallback for a site whose mirror predates the change - SM365's lesson, that an upgrade does not refresh what it does not touch - so the fact now exists TWICE and t/lint/61 pins the two copies by value, including the escaping and the key filter, because the file is read only by a browser and nothing else in the suite would have compared them. CONSEQUENTLY THE INVENTORY STILL LISTS THE SITE ENTRY: the source emits the block, a refreshed site does not receive it, and those are different questions - the site-side count is 0 for a rewritten mirror and 1 for a stale one, so an enforcing policy needs the operator to know which every site is. WHAT REMAINS on the site side is therefore an operational question rather than a code one; the manager's head script is unchanged and still wants a hash rather than a move. STEPS 1-3 OF THE CSP WORK DONE 2026-08-18: ten inline blocks down to TWO, and the remaining two are for DIFFERENT AUDIENCES. The fallback page chrome and the SM098 multi-step form rules are /assets/lazysite-chrome.css; the frame suppressor, the SM099 auth-control sync and the admin bar's frame hiding are /assets/lazysite-chrome.js. TWO FILES rather than seven, at the operator's direction and it is the right call - a rule that only matters on a page with a multi-step form costs nothing to carry, while a second request costs a round trip on every page that has one. The JS bundle is SELF-CONTAINED, each behaviour looking for its own elements and doing nothing when they are absent, which is what lets one reference serve three callers; it is injected once per response and deferred, since every behaviour adjusts an element already on the page and none writes content. NO REPORT-ONLY PHASE AND NO COLLECTOR is needed for the rest: t/lint/56's inventory already does what collected reports would have, completely rather than representatively, so the end state is an enforcing policy directly. WHAT REMAINS: the two form scripts (they interpolate $form_name and the markup already carries data-form=, so they can read the attribute and become static), the manager's HEAD script - 349 lines carrying four per-user values, a nav built from plugin conditionals, a theme prelude that must run before first paint and a fetch wrapper that must replace window.fetch before anything captures a reference, two of which are ORDERING constraints an external file cannot satisfy without a round trip in front of the render, so it wants a hash or a looser manager policy rather than a move - and, on the site side, the theme custom properties - which the asset mirror can hold as a per-theme tokens.css rather than needing a nonce, though a flash of unstyled content is the thing to prove before promising that. AND SM369 STILL APPLIES: on a stock front end the engine never answers these new asset files, so none of this is verifiable in the field on edge - it is provable in the suite and on an SM283-template instance and nowhere else we can currently reach. PARTIAL, 2026-08-17. HSTS and Permissions-Policy shipped, CSP and COOP deliberately did not. The filing's premise needed correcting first: the three existing headers were NOT all set correctly, they were set correctly on one of four response paths - `_serve_content_static` sent nosniff alone, so every stylesheet, script, SVG and image the processor served was short by two, which is precisely what a probe of the homepage could not see. All four paths now emit one set from `Lazysite::SecurityHeaders`, pinned to the processor's ADR-0001 copy by t/lint/55 and asserted through the real engine by t/integration/44. HSTS is `max-age=300`, unqualified, and only over TLS. The header set is emitted BY THE ENGINE and nothing was added to any front-end template, so SM286 holds - and the comment that previously justified the omission (\"both belong in the Apache vhost config\") is quoted in the module as a decision overturned rather than dropped. CSP: the operator ruled out building a collector, and correctly - a report-only header with nowhere to report is inert, so the proposal was really an unauthenticated cross-origin write endpoint to discover something the source already states. t/lint/56 holds that answer instead as a ten-entry inventory of every inline `<script>` and `<style>` the engine emits, and FAILS when an eleventh appears. Under `script-src 'self'` every page violates ten times before a layout or any content is considered, so CSP is a project - moving these to served assets or threading a nonce - not a header. COOP was to be taken alongside CSP and waits with it. CLAIM NARROWED 2026-08-18 (SM369). The headers reach every response THE ENGINE ANSWERS. On a stock proxy template the engine never answers a static at all, so on most of the fleet that is pages only - and edge, measured after the 0.10.13 deploy, carries no security headers whatever on its statics, not even the nosniff this filing describes as the prior state. That is consistent rather than alarming: the absence is TOTAL, which is what a front end answering everything looks like, and not the short-by-two state the fix addressed. No deployed instance the project can reach answers a static from the engine, so nothing outside the suite has ever seen these headers on a stylesheet. The fix is not in doubt; what was overstated is the reach. CLOSED 2026-08-23: the correction IS the remaining content, and it is recorded. A filing held open because one of its own claims turned out to be too broad is a filing waiting for nothing - the overstatement is fixed by saying so, which this note does."
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
