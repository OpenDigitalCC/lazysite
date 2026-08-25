---
title: "SM558: the link audit sees the root page"
subtitle: "A link to /index or /index.html is always reported broken by the link audit."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-audit-index-link.pl; class: correctness; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. canonical at audit.pl 370-377 maps index.md to the empty string, but the check at 150-158 only tries stripping a trailing /index from the target and never the bare index case, so /docs/index resolves while /index and /index.html are reported broken. The probe reports BROKEN LINKS (1) about.md -> /index and flags it as a false broken. The fix handles the bare index case in the check."
---

# The finding

A link to the root page as `/index` or `/index.html` is always reported
broken: `canonical` (`plugins/audit.pl 370-377`) maps `index.md` to `''`,
but the check at `plugins/audit.pl 150-158` only tries `s{/index$}{}`
on the target and never the bare `index` case (`/docs/index` resolves).
The probe output reads `BROKEN LINKS (1) about.md -> /index`, `FALSE
BROKEN reported`.

# Why it matters

Correctness: the audit report flags a working link to the home page,
and an operator who trusts the report will chase a fault that is
absent, or learn to ignore the broken-links table.

# The proving test

NEW `t/unit/plugins/32-the-link-audit-sees-the-root-page.t` with
`unlike($out, qr{about\.md\s+->\s+/index})`.

# Fix shape

Have the check at 150-158 treat a bare `index` (and `index.html`) target
the same way `canonical` treats `index.md`, resolving both to the root.
