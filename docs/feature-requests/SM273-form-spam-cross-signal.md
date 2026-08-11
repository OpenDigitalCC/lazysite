---
title: "SM273 - Form spam controls, parts 3-5: cross-signal correlation"
subtitle: "Quarantine and observability shipped. The remaining parts correlate submissions with the scanner and bad-URL signals the platform already collects."
brand: plain
status: candidate
status-note: "SPLIT from SM216 on 2026-08-11. SM216's parts 1-2 went out with the 0.10.1 edge build (quarantine with URL-count and keyword scoring; PII-free outcome lines folded into the SM213 day-buckets). Parts 3-5 were always 'not for this release' and were captured for the roadmap; keeping them in SM216 made a shipped anti-spam feature read as half-built. Not started."
---

# SM273 - form spam, parts 3-5

## What shipped, and why the rest is separate

SM216 parts 1 and 2 gave the product a quarantine: a submission scoring above
the URL-count threshold or matching a keyword is stored but flagged, held
out of the notification bell, and shown in the viewer with a per-row
Confirm. Outcomes (stored / quarantined / blocked, with the reason) are
logged PII-free and folded into the stats day-buckets.

That is a complete, useful feature. The remaining parts are a different
programme: instead of judging a submission on its own contents, they
correlate it with signals the platform already collects elsewhere.

## What remains

**Cross-signal with the scanner classification.** SM213's visitor stats
already classify a session as SCANNER when it probes. A submission from a
session already marked scanner is a different proposition from the same
text arriving from an ordinary reader, and today the form handler cannot
see that.

**Cross-signal with bad-URL data.** SM128's bad-URL scanner records hosts
probing for paths that never existed. The same correlation applies.

**Reject counters into the day-buckets.** Blocks are logged; they are not
yet summarised per day in a way an operator can look at and say "this
started on Tuesday".

## Constraints, unchanged from SM216

The published stance holds and is not up for renegotiation here: no
third-party anti-spam service, no CAPTCHA, no fingerprinting, no
JavaScript requirement, and no accessibility regression. Anything in this
filing that cannot be built inside those constraints is not to be built.

## Note on evidence

SM216 was written after a spam run that passed every control because it
behaved like a human. Cross-signal is the answer to that specific case -
the content looked fine, the session did not. Worth confirming the current
signal quality before building: if scanner classification is noisy, this
correlates noise.

## Related

SM216 (parts 1-2, shipped), SM213 (the stats store this reads),
SM128 (bad-URL scanner).
