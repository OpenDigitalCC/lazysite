---
title: "SM618: `audit` and `manage_forms` returned personal data and described only the benign half"
subtitle: "Two rows of the capability-row campaign (R-11, R-13), measured on 0.10.34 under partner tokens holding one capability each. The reach of both is RULED CORRECT and unchanged; what changes is that the titles now say what they hand over. `audit` is the sharper case because of its neighbour: it sits beside `analytics`, which promises \"sanitised, IP-anonymised\" and keeps that promise, so a pair where one declares anonymisation and the other declares nothing invites exactly the wrong inference - that the trail read is at least as careful with personal data as the visitor read. It is the opposite, and an operator learned that only by granting it. MEASURED, not inferred: `audit` returned 93 pages of the WHOLE instance's trail, six distinct actors, 180 full IPv4 dotted-quads in 192 sampled entries, and origins `ui`/`cli`/`install` - which are not partner traffic but the OPERATOR's own manager sessions, command-line runs and installations, with the IP each came from; the target filter enumerated 1,051 distinct paths, 70 under another domain's content root. The engine states `scoped: false` in its own reply. `manage_forms` returned live submission bodies - name, email, phone, message and the submitter's IP - under the capability an operator grants so an agent can WIRE UP a form; its title spent its words on the notification never carrying content, which is a statement about the BELL and reads as a reassurance about the grant. THE RULING (operator, 2026-08-26) is that both reaches stand: an agent asked \"what changed here and who changed it\" needs the whole trail, and `purge` already set the precedent for an instance-wide capability being documented rather than scoped (SM577). The defect was never the breadth - it was that `purge` SAYS SO and these two did not. NO BEHAVIOUR CHANGES. Two strings, the generated capability map, the security register, and a test. THE FIELD AGENT READ NO PERSONAL DATA to establish this: actors and IPs were counted as digests and the `ip` field's shape was established by regex classification over 192 entries without printing a value - the right way to report a personal-data exposure without becoming a second copy of it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26)."
---

# What an operator reads at the moment of granting

The title is the only thing they read. It is not documentation that sits
alongside the decision - it *is* the decision's evidence.

| | Declared | Returned |
|---|---|---|
| `analytics` | "sanitised, IP-anonymised" | as declared |
| `audit` | "Read the append-only audit trail." | the whole instance, raw IPs, operator sessions |
| `manage_forms` | "Wire forms to delivery handlers." | that, **and** live submission bodies |

# Why this is filed as a security change that closes nothing

The register entry says so in those words. Two capabilities disclose personal
data to a partner token, and always did. Nothing was closed, so nothing may be
counted as closed. What changed is that the fact is now readable before the
grant instead of after it - and a register that logged only the narrowings
would make the release look better than it is.
