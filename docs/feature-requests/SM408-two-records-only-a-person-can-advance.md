---
title: "SM408: the conformity declaration and the significant-change register"
subtitle: "One is a placeholder stamped 0.8.0 and unsigned; the other's newest entry is 2026-08-14 and covers none of the six releases since. The second is load-bearing: ADR 0007's pentest deferral is conditional on exactly that register being kept."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-19 by the compliance gate during the 0.10.16 edge cut, both as advisories. NEITHER BLOCKS AN EDGE OR BETA CUT and neither blocked this one - the declaration attaches to a stable release and the register check is a proxy. THE REGISTER IS THE URGENT ONE, and not because of a gate: ADR 0007 defers the first third-party pentest ON CONDITION that significant changes are assessed and recorded, with expiry 2026-12-31 or on a trigger. A deferral whose conditions are not recorded is not a deferral - so six unassessed releases weaken the waiver itself, which is a real-world position rather than a warning in a log. THE DECLARATION is stamped '0.8.0 - placeholder, to be finalised at the 0.8.0 stable cut', a cut that happened long ago, and signed '(unsigned draft)'. It blocks at the next STABLE, which is where D5's signoff_required: yes attaches. Two CRA obligations fall due 2026-09-11 independently of both. Shares a cause with [[SM407]]: records only a person can advance, all three stopping in the same week the line accelerated to seven releases in five days."
---

# Two findings, different weights

## The significant-change register - the load-bearing one

`docs/SECURITY.md` carries dated entries. The newest is **2026-08-14**, for
0.10.9. Six releases have shipped since and none is assessed there.

::: widebox
This is not a documentation gap. [[ADR 0007]] defers the first third-party
pentest **on condition** that significant changes are assessed and recorded,
with expiry at 2026-12-31 or on a trigger, whichever comes first. The compliance
tool says it plainly: *"a deferral whose conditions are not being recorded is
not a deferral, so an unreferenced release weakens the waiver."*
:::

The six releases are not trivial ones. They include the security header set
(0.10.15), protected content leaving the document root, the front-door rework,
and a cache clear that deleted pages. Whether any of them is a *trigger* under
the ADR is exactly the assessment nobody has recorded - and "we looked and none
fired" is a valid entry. An absent entry is not.

**The work is the assessment, not the writing.** Somebody has to decide, per
release, whether a trigger fired.

## The declaration of conformity

`docs/DECLARATION-OF-CONFORMITY.md` reads:

```
Version   | 0.8.0 - placeholder, to be finalised at the 0.8.0 stable cut
Signature | (unsigned draft)
```

The 0.8.0 stable cut has been and gone. The document is a placeholder that
outlived the event it was waiting for.

It is advisory on edge and beta - correctly, since neither channel carries a
conformity declaration, which is the same reasoning that made keeping
`signoff_required: no` defensible for the beta promotion (D5, recorded
2026-08-19). It **blocks at the next stable**, and it needs a person to sign it,
which is why no amount of engineering closes it.

# The common cause

0.10.9 was cut on 2026-08-14. Seven releases followed in five days.

All three records that only a person can advance - this pair and [[SM407]]'s
feature timeline - stopped in that same week. Nothing failed: each check is an
advisory, correctly, because none of them is a reason to refuse a build.

The honest reading is that the validating cadence has not kept up with the
fixing cadence, which is what the pre-beta review said in its own words and is
the reason it recommended promotion as the moment to let one catch the other.

# Dates that do not move

- **2026-09-11** - two CRA obligations fall due, independently of any switch or
  channel
- **2026-12-31** - ADR 0007's pentest waiver expires at the latest; after that
  an absent report is a finding rather than a deferral
