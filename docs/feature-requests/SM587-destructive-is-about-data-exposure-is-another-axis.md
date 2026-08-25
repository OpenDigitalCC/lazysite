---
title: "SM587: does destructive mean the object cannot be recovered, or the effect cannot be undone?"
subtitle: "acl-remove is reversible as an object - the rule can be re-set - and irreversible as an effect: content that was exposed cannot be un-exposed. SM576's copy test does not decide this case."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED BY THE SITE AGENT 2026-08-25 while verifying SM572 on 0.10.32, as a classification question rather than a finding: in its 23-action set, 8 are flagged mutating and 1 destructive (brief-delete); acl-remove is mutating but not destructive. Under SM576's proposed rule - does the engine retain a copy? - that is correct, because an ACL rule can simply be re-set. But the CONSEQUENCE of removing a rule is exposure of content that was gated, and exposure cannot be undone the way a rule can be re-added. The two readings of 'destructive' diverge here and nowhere else either party has looked. RECOMMENDATION, for the operator to take or leave: keep destructive meaning DATA CANNOT BE RECOVERED (the copy test, which is objective and already drafted), and treat exposure as a separate axis with its own word - fold exposure into destructive and every read-enabling change becomes destructive, at which point the flag stops discriminating and a caller learns nothing from it. A second flag (or a per-action note) costs little and keeps both facts sayable. PLANNED with SM576, whose tiers this decides."
---

# The case

| | `brief-delete` | `acl-remove` |
|---|---|---|
| Object afterwards | gone, no copy | re-settable |
| Effect afterwards | the record is lost | the content was exposed, and that happened |
| Copy test says | destructive | not destructive |

# Why it matters beyond the label

SM576 splits the lateral housekeeping grant on the copy test. If
`destructive` silently also means "exposing", the split stops being
derivable from a rule and becomes a per-action argument - which is the
thing the copy test was chosen to avoid.
