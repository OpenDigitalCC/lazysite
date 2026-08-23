---
title: "SM490: the manager under an enforcing CSP - the conversion, measured"
subtitle: "A headless-browser rig drove all sixteen manager pages under enforcement. 232 of 232 violations are script-src-attr; nothing else breaks. The fix is ~250 handler attributes converted to delegated data-action, page by page, behind the report-only mode already shipped"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-23 FROM THE 2026-08-19 MEASUREMENT, which answered SM380's open item and was never given a number. SM380 shipped the report-only rollout mode; SM384 fixed the hashing defect the report named as a release blocker. What remains is the conversion itself, and the report settles HOW with arithmetic rather than taste: a nonce is ruled out by the spec (nonces whitelist script ELEMENTS and have no effect on event-handler attributes at all); 'unsafe-hashes' is ruled out by counting (59+50 constant handler bodies would be ~109 hashes in every response header, and 119 interpolated sites - loadPermGrid('bob'), saveComment('carol') - generate unbounded distinct strings that cannot be enumerated at header time); per-element addEventListener works for one-offs but as the general mechanism means ~250 wiring points and re-wiring after every innerHTML re-render, the exact step the generated tiers would forget. EVENT DELEGATION WITH data-action IS RECOMMENDED: ~250 handler sites converted page by page, and one ~40-line dispatcher in manager-chrome.js. With the block hashes correct every inline script on all sixteen pages passes, CodeMirror needs no eval, there are no javascript: URLs, and no style, connect, font or frame violations. The report carries a conversion order that lands incrementally and a way to test it without a browser in CI. SIZE: L, mechanical. Not urgent - report-only mode means nothing is broken today - but it is the single largest piece of measured, undone work in the register, and the measurement will go stale as pages change."
---

# What was measured

A headless-browser rig drove all sixteen manager pages with the CSP
**enforcing**. Of 232 observed violations, **232 are `script-src-attr`** --
inline event-handler attributes. Nothing else: with the block hashes correct
every inline `<script>` passes, CodeMirror needs no `eval`, there are no
`javascript:` URLs, and no style, connect, font or frame violations.

# Why the obvious mechanisms are out

```datatable
columns: Mechanism | Ruled out by
widths: 5cm | X
bold: 1
tone: medium
---
A nonce | **the spec.** Nonces whitelist script *elements*; they have no effect on event-handler attributes. `'unsafe-hashes'` exists precisely because neither nonces nor plain hashes cover them
`'unsafe-hashes'` | **arithmetic.** 59+50 constant handler bodies is ~109 hashes in every response header, and 119 sites interpolate arguments -- `loadPermGrid('bob')` -- so their strings are unbounded and cannot be enumerated at header time
Per-element `addEventListener` | **maintenance.** ~250 wiring points, IDs invented for elements that have none, and re-wiring after every `innerHTML` re-render -- the exact step the generated tiers would forget
```

# The recommended mechanism

**Event delegation with `data-action`.** One dispatcher of ~40 lines in
`manager-chrome.js`; each handler attribute becomes a `data-action` naming a
function, with arguments in sibling `data-*` attributes. Page-scoped and
mechanical, so it lands page by page behind the report-only mode SM380
shipped, and each page flips to enforcing when its own count reaches zero.

The full conversion order, the per-page counts, and the CI test that needs no
browser are in the archived report: `inbox/archive/2026-08-19-manager-under-csp-enforce.md`.
