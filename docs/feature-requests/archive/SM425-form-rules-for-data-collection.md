---
title: "SM425: two form enhancements for structured data collection"
subtitle: "Exempt signed-in users from the submission rate limit, and add the remaining field rules to the `:::form` grammar."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29 (3901541) - the flip its landing chain wrote was lost with the same tree rewrite that ate its changelog entry; restored at the post-cut pass. Item 1 as specified: a submission whose session cookie the shared verifier (SM411) accepts cryptographically bypasses the anonymous IP rate limit; anonymous unchanged; forged is anonymous; the SM402 no-actor line holds by behaviour; the exemption degrades to anonymous if the session module cannot load. Item 2 was already built under SM401 + the existing number min/max. ORIGINAL NOTE: FILED 2026-08-20 from a site-agent brief of 2026-08-19 (archived at inbox/archive/). TWO ITEMS. (1) RATE LIMITING: exempt a signed-in user from the anonymous submission rate limit - a member filling in a long form repeatedly is the case the limit is not aimed at, and hitting it reads as the site being broken. Needs care: SM402 established that the form handler reads NO verified identity, so 'signed-in' has to come from somewhere the handler can actually verify, which is exactly what SM411's extracted Lazysite::Auth::Session now makes possible - this item was arguably blocked before that landed and is not now. (2) FIELD RULES: extend the :::form grammar beyond SM401's radio/checklist/checklist-qty. The brief's item 3 is explicitly out of scope. SIZE: S-M; post-beta, and item 1 should cite SM411 as its enabler."
---

# Two items

rate limiting
: A signed-in member is not the traffic the anonymous rate limit exists to
  stop, and meeting it mid-form reads as a broken site. The gate needs a
  verified identity - which the form handler deliberately does not read
  (SM402) and now can obtain (SM411).

field rules
: The remaining `:::form` field rules, continuing the vocabulary SM401 started.
