---
title: "SM252 - The form time token is baked into the cached page, so the timing check does nothing"
subtitle: "One minted timestamp is reused for every visitor until the page next renders. The minimum-dwell check passes unconditionally, and the expiry can be spent before anyone arrives."
brand: plain
status: candidate
status-note: "Reported by a site agent 2026-07-28 on edge.explore.lazysite.io, and NOT filed at the time - found in the inbox 2026-08-08 while archiving. Verified: _ts and _tk are emitted into the form HTML at render time and lazysite serves the cached render until the source changes. This defeats one of only two automated-submission defences the handler has, so it is more urgent than its age suggests."
---

# SM252 - the form time token is defeated by the page cache

## Why

The form emits its timing token into the page body:

```html
<input type="hidden" name="_ts" value="$ts">
<input type="hidden" name="_tk" value="$tk">
```

Those are minted when the page is **rendered**, and lazysite serves the cached
render until the source changes. So one timestamp is captured in the cached HTML
and handed to every visitor, for as long as the page stays unchanged.

The handler's timing check requires a submission to arrive between 3 seconds and
2 hours after the token was minted. Against a cached page that breaks in both
directions:

**Minimum dwell stops working.** The check exists to require a short pause
between the page being received and a submission arriving - the cheapest possible
signal that a human was involved. On a cached page that interval is already
satisfied before anyone loads it, so the check passes unconditionally. On a busy
contact page that rarely changes, this control is effectively absent.

**Expiry can be spent before a visitor arrives.** The same token carries the
two-hour window. A page cached for longer than that hands out an already-expired
token, and a genuine visitor's submission is rejected for being too late when
they filled it in immediately.

So the control is simultaneously too weak for the case it exists to catch and too
strict for the case it should let through - which is the signature of a check
measuring the wrong interval.

## Measured on a live 0.10.3 instance, 2026-08-08

The filing above was reasoned from the code. A site agent then measured it on
edge.explore.lazysite.io, which turns the argument into a demonstration.

Three fetches of `/contact`, two seconds apart, all returned the same token - and
it was already **363 seconds older than the moment it was served**:

```
fetch 1   _ts = 1786211775
fetch 2   _ts = 1786211775
fetch 3   _ts = 1786211775
wall clock at fetch 3 = 1786212138
```

Posting that token straight to the handler, having never loaded the page in a
browser, was **accepted**: `{"ok":1,"message":"Thank you - your message has been
sent."}`, and `form_list` went from 2 rows to 3. There was no dwell to measure at
all. The check passed because the arithmetic is `now - last_render`, already six
minutes, rather than `now - visitor_received_page`, which was zero.

That is the defect exactly: **the check cannot distinguish a visitor who read the
page from a client that never fetched it.**

The store carried the proof historically too. Two rows from 2026-07-27 were
already present, the second reading *"TEST 3 of 3: submitted under the minimum
dwell - should be rejected."* It was stored. The control was inert on the
previous release, under a deliberate test, and the row recording that has been
sitting in the store ever since.

## Why it matters more than its size

The handler has two automated-submission defences that need no configuration: the
honeypot field and this timing check. SM216 added content scoring on top, but
those two are the baseline every form gets. One of them is silently inert on
exactly the pages most worth attacking - the long-lived, heavily-cached contact
page.

Silently is the operative word. Nothing reports it. The form works, submissions
arrive, and the control reports nothing because it is passing.

## Directions, none of them free

**Exempt form pages from the cache.** Correct and expensive: a contact page is
often among a site's most-hit, and this trades a real control for a real cost.
The `nocache: true` front-matter key already exists, so the cheapest immediate
mitigation is to document that a page carrying a form should set it - which is a
workaround, not a fix, and should be recorded as such.

**Mint the token outside the cached body.** The token is per-visitor data in a
per-page cache, which is the actual mismatch. A small endpoint that issues one on
demand, or a cookie set at render time, removes the token from the cached HTML
entirely. This is the direction most likely to be right, and it costs a request
or a cookie and needs care not to become a JavaScript requirement - the published
stance says forms work without JS.

**Measure something else.** If the dwell signal cannot be made honest under
caching, say so and lean on the honeypot and SM216's content scoring instead,
rather than keeping a check whose passes mean nothing. A control that always
passes is worse than no control, because it looks like coverage.

## Verification

- On a cached page, two visitors receive tokens that differ, or the timing check
  is honestly reported as not applicable.
- A page cached longer than the expiry window does not reject a genuine
  submission.
- Forms still work with JavaScript disabled.
- Whatever is chosen, the block/allow reasons already counted into the stats
  day-buckets (SM216 part 2) reflect it, so the effect is visible rather than
  inferred.

## Not in scope

- The honeypot or SM216's content scoring, both of which are unaffected.
- Any third-party anti-spam, CAPTCHA or fingerprinting - the published stance
  rules them out and this does not reopen it.
