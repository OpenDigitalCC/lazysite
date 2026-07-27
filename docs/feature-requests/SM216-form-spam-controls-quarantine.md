---
title: "SM216 - form spam controls for the low-volume human/agentic case (quarantine, not sharper reject)"
subtitle: "The existing form controls (honeypot, HMAC dwell token, per-IP rate limit) stop bulk dumb automation and demonstrably do, but hand-typed and LLM-browser-agent spam that loads the page, waits, and posts once sits outside the model. Add server-side, content-based, no-JS spam scoring that QUARANTINES rather than rejects - so cheap heuristics are safe on by default - plus reject-counter visibility, all consistent with the no-tracker/no-CAPTCHA stance."
brand: plain
status: in-progress
status-note: "PART 1 (quarantine keystone) SHIPPED in 0.10.1 edge (branch claude/sm216-spam-controls): server-side content scoring at accept time (>= spam_url_threshold URLs in visible text, default 2, plus a per-form spam_keywords list), a suspect submission is STORED but flagged _quarantined + _spam_reason and held OUT of the notification bell; the Submissions viewer marks quarantined rows, offers a Quarantine-only filter, and a per-row Confirm (un-quarantine, keeps the row) beside Delete; new control-API action form-submission-confirm (gate manage_forms, audited). Defaults ON - a false positive still arrives, just unannounced. Parts 2-5 remain per the order below. Original proposal: PROPOSED 2026-07-27 by the lazysite.io site agent (inbox note, prompted by one SEO-spam row on cloudient.net that passed every control because it behaved like a human). A multi-part program, NOT for 0.9.17 - captured for the roadmap with the agent's suggested order. Highest-value first item (quarantine + url-count + keyword list) is small; later parts (cross-signal with scanner/bad-URL data, reject counters into the stats day-buckets) pair with SM213 stats and the goals work. Holds the published stance: no third-party anti-spam/CAPTCHA, no fingerprinting, no JS requirement, no accessibility regression."
---

# SM216 - form spam controls (quarantine + content signals)

## Why

The one spam row stored on cloudient.net (hand-written SEO link-building: three
URLs, a delist link, a fabricated address, a junk phone, a gmail sender) passed
every control because it behaved like a human. Verified against
`plugins/form-handler.pl`: honeypot-empty, an HMAC time-token (min dwell 3s,
expiry 2h), a 5-per-IP-per-hour rate limit, and a content-presence check. To pass,
a submitter loads the real page, leaves the hidden field alone, waits three
seconds, posts once - which every human does, and so does any agentic bot driving
a real browser. The controls are calibrated for bulk dumb automation (direct
POSTs, replays, sub-second scripts) and stop it; low-volume human-typed and
LLM-browser-agent spam sit outside the model, and that class is getting cheaper.

## Constraints (the published stance - all proposals hold it)

No third-party anti-spam or CAPTCHA, no client fingerprinting, no JavaScript
requirement (forms keep working no-JS), no accessibility regression. Everything is
server-side and content-based.

## Design (the agent's proposals, triaged)

Quarantine, not a sharper reject - the keystone
: Score a submission at accept time; a suspect row is STORED but flagged
  `quarantined` - excluded from operator notifications (or batched into a daily
  digest line) and shown under a Quarantine filter in the Submissions viewer, with
  one-click confirm/delete. A false positive then costs nothing (the message still
  arrives, just unannounced), which is what makes cheap heuristics safe to enable
  by default. A `read_submissions` agent can triage the quarantine on request.

Score signals (small, transparent, per-site configurable - not ML)
: URL count in the body (>= 2 suspect by default); an operator keyword list per
  site (like the stats plugin's `noise_paths`); submission language vs the site's
  `lang` (the language sets already give the engine this); trivial coherence
  checks (URL-shaped text in a phone field, name absent from the email local-part,
  all-caps ratio). Each signal is one line in the report ("quarantined: 2 urls +
  keyword 'SEO'") so operators see and tune why.

Cross-signal with data the box already has
: A submission whose (anonymised) source the stats classed scanner/noise in the
  window (SM213), or that tripped the bad-URL blocker, quarantines automatically -
  one lookup, both datasets already on disk.

Observability: count the blocks
: Rejects currently die into the log with no operator-visible trace. Count them
  per form per reason (honeypot / token / too-fast / expired / rate) into the
  stats day-buckets (SM213) so the report shows blocked vs stored - today an
  operator cannot tell "controls are perfect" from "nobody attacks us". Pairs with
  the goals work: stored-genuine, quarantined and blocked become three lines of
  the same trend.

Tunable dwell + rotating field names
: Make the 3s min dwell a per-form config (default higher for textarea forms, e.g.
  8s); optionally derive the visible field names per render from the existing HMAC
  token (a short suffix) so template-POST bots that never fetch the page break -
  no client-side cost (the server rendered the names, the server maps them back).

Rate limit by network as well as IP
: A /24 (v4) / /48 (v6) bucket alongside the per-IP one catches rotating
  single-use addresses inside one campaign.

Optional hard modes, OFF by default (documented with trade-offs)
: An email-confirmation loop for email-collecting forms (submission pending until
  a signed link is clicked); and - explicit opt-in only, since it breaks the no-JS
  posture - a client-side proof-of-work. Neither belongs on by default.

## Suggested order (from the agent)

1. Quarantine + URL-count + keyword list (ends silent spam delivery at near-zero
   false-positive cost). DONE - 0.10.1 edge.
2. Reject counters into the stats day-buckets (visibility).
3. Cross-signal with scanner/bad-URL data; network-bucket rate limit.
4. Dwell config + rotating field names.
5. Documented opt-in hard modes.

## Not in 0.9.17

This is a program, not a single change; it is captured for a later beta. Items 2-3
depend on and extend SM213's day-buckets (reject counts + the scanner class), so
they land most naturally after 0.9.17.

Related: `plugins/form-handler.pl` (the existing controls), the Submissions viewer
(SM182/SM187), SM213 (the stats day-buckets + scanner class this cross-signals
with), the bad-URL blocker, and the published privacy stance. Site agent's inbox
note archived at `inbox/archive/2026-07-27-form-spam-controls-proposal.md`.
