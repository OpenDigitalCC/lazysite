---
title: "SM380: the CSP shipped enforcing, with no way to turn it down"
subtitle: "SM352 step 5 emitted one enforcing Content-Security-Policy on every HTML response, with no config key and no report-only mode - and a CSP hash covers a <script> block, not an inline event-handler attribute, which is what the manager's own controls are built on."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19 on claude/sm380-csp-rollout-mode, before the cut. `csp: enforce | report-only | off` in lazysite.conf, defaulting to REPORT-ONLY, mirrored into the processor's ADR-0001 copy and pinned across all five inputs by t/lint/55. An unrecognised value reads as report-only, never off - a typo must not silently disable a security header, the direction SM356 found failing open. FOUND BY THE PRE-BETA REVIEW, not by the suite, and that is the point: the failure is a browser refusing to run an onclick= handler, which nothing driving the processor can see."
---

# What shipped

SM352 step 5 emitted `Content-Security-Policy` - enforcing - on every
HTML response. No config key, no report-only mode, no manager branch,
and no way for an operator to turn it down on a site that has not been
walked.

# Why that is worse than it looks

**A CSP hash covers a `<script>` BLOCK. It does not cover an inline
event-handler ATTRIBUTE.** The manager's own pages are built on
`onclick=` - cache invalidation, audit, sessions, plugins - so under the
shipped policy those controls silently stop firing.

::: widebox
**No test could have caught it.** The failure happens in a browser, on a
page the suite renders but never executes. Every processor-driven
assertion about the header was correct and the operator's buttons still
would not have worked.
:::

# The fix

`csp: enforce | report-only | off` in `lazysite.conf`, defaulting to
**report-only** for the rollout window.

```datatable
columns: Value | Header emitted
widths: 4.0cm | X
bold: 1
tone: medium
---
`report-only` (default) | `Content-Security-Policy-Report-Only`
`enforce` | `Content-Security-Policy`
`off` | none
anything else | `Content-Security-Policy-Report-Only`
---
```

The **policy is identical in either mode** - only the header name
differs - so a site that flips to `enforce` gets exactly what it had
been reporting.

`off` exists because a header that cannot be turned off is one an
operator routes around by other means, and an unrecognised value reads
as report-only rather than off: a typo must not silently disable a
security header, which is the direction [[SM356]] found the update
channel failing.

# What remains

The manager's `onclick=` handlers still need converting to
`addEventListener` wiring before a manager surface can be enforced. That
is the larger, cleaner change and it coordinates with the `t/lint/56`
inventory. Until then, **walk the manager with the browser console open
before setting any site to `enforce`** - recorded in `MANUAL-CHECKS.md`.

# Verification

- All five inputs drive the real processor end to end and produce the
  right header name, or none.
- `t/lint/55` pins the processor's copy against the module across every
  mode, including the typo case.
- The docs that said the engine deliberately emits no CSP - both false
  since step 5 - now describe the policy and the key.

# Related

[[SM352]] (the work this completes), [[SM356]] (fail-closed on an
unrecognised value), [[SM286]] (why the engine emits it at all).
