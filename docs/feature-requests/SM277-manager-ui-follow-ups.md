---
title: "SM277 - Two manager-UI follow-ups, closed scope"
subtitle: "The reciprocal capability counts on the Services page, and in-place regeneration of a connect code. Both were deferred inside shipped filings where nobody would find them."
brand: plain
status: candidate
status-note: "SPLIT on 2026-08-11 from SM180 and SM200, both shipped. Each carried one small deferred follow-up in its note, which is where deferred work goes to be forgotten. THE SCOPE OF THIS FILING IS THE TWO ITEMS BELOW AND NOTHING ELSE - see 'Why this is two items and not a bucket'. Not started."
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
