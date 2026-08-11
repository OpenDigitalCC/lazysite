---
title: "SM277 - Two manager-UI follow-ups, closed scope"
subtitle: "The reciprocal capability counts on the Services page, and in-place regeneration of a connect code. Both were deferred inside shipped filings where nobody would find them."
brand: plain
status: shipped
status-note: "BUILT on main (unreleased), both items, closed to additions as filed. (1) New read-only capability-holders resolver returns, per capability, how many groups grant it and how many accounts hold it - through the NESTING CLOSURE, because that is what enforcement uses; counting direct membership would under-report exactly the grants hardest to audit. Groups are named, accounts are counted only: a roster on the settings screen buys nothing the Users page does not already answer. channel-services now also returns the conf-key-to-channel map so the Services page needs no second copy of it in JavaScript. The counts sit behind manage_users, so an operator with manage_config alone sees NOTHING rather than zero - zero would read as 'nothing depends on this'. Covered by t/unit/manager/66. (2) The connect-code panel counts the code's life down, says plainly when it has expired and strikes it through, and Regenerate re-mints IN PLACE - superseding the old timer and poll rather than rebuilding the panel and scrolling the operator back to the top of a flow they are midway through. cmd_onboarding_web now passes through the absolute expiry SM200 already computed and this caller dropped. THE UI IS NOT SUITE-COVERED: docs/MANUAL-CHECKS.md steps 10-14. SPLIT on 2026-08-11 from SM180 and SM200."
---

# SM277 - two manager-UI follow-ups

## Why this is two items and not a bucket

A filing that collects "small UI things" becomes a place to put anything
small, and then it is never finished because it never can be. This one
names two items and is closed to additions: a third small follow-up gets
its own filing or joins a batch with a stated theme.

Both belong together only in the sense that they are manager JavaScript,
which the test suite cannot reach - so they share a manual verification
pass, and doing them separately pays that cost twice.

## 1. Reciprocal capability counts on the Services page (from SM180)

SM180 shipped dormant-capability indicators: the Groups and Users grids
show when a capability is granted but inert because the service that would
use it is switched off. The reciprocal view was deferred - on the Services
page, each service showing **"held by N groups / M users"**.

Why it matters: the current asymmetry means an operator can see "this
grant does nothing" from the grant's side, but not "switching this off
would strip N accounts" from the switch's side. The second is the one they
need before turning something off.

Both numbers come from the same resolver SM180 already uses.

## 2. In-place connect-code regeneration (from SM200)

SM200 shipped the connector first-time-connection work: distinct 401
reasons, a 30-minute code TTL with the expiry surfaced, fresh-chat
guidance, and a `lazysite-check` probe for a misconfigured `site_url`. The
server side is proven by `oauth/02-flow.t`.

What remains is a nicety: when a connect code has expired, the panel says
so but the operator must leave and re-enter the flow to get a new one.
A **Regenerate** button in place would save that round trip.

Deliberately recorded as a nicety, not a defect. The flow works; this
removes a small indignity from it.

## Testing note

Neither can be covered by the suite - both are manager JavaScript. They
need a stated manual pass, and that pass is the real cost of this filing.
Worth batching with [[SM265]], [[SM266]] and [[SM267]], which are in the
same position for the same reason.

## Related

SM180 and SM200 (both shipped; these were their deferred halves),
SM265/SM266/SM267 (the other untestable-by-suite UI work).
