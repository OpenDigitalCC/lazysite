---
title: "SM435: manage_config still advertises two files it can no longer write"
subtitle: "0.8.1 moved nav.conf to manage_nav and the form configs to manage_forms over WebDAV. The capability descriptor was updated in both new places and missed in the old one, so manage_config still promises both - and a partner holding it alone gets a 403."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 off a field report, and the field's own conclusion was BACKWARDS - which is why this is worth a filing rather than a one-line fix in passing. The reporter found that a site's onboarding brief and its /.well-known/ai-partner descriptor disagree about nav.conf, and concluded the descriptor was the accurate one. It is the descriptor that over-promises. Capabilities.pm lists lazysite/nav.conf under BOTH manage_nav (line 84, correct) and manage_config (line 130, stale), and lists lazysite/forms/<name>.conf under both manage_forms and manage_config the same way. The ENFORCEMENT in lazysite-dav.pl authorise() requires manage_nav for nav.conf and manage_forms for the form configs, with no manage_config path to either. The comments at both branches say '0.8.1: WebDAV previously used the coarser manage_config here' - so the move was deliberate, both new entries were written, and the old entry was left behind. THE REPORTER'S EVIDENCE DOES NOT SETTLE IT EITHER WAY: they hold manage_config and observed a GET returning 200, but authorise() gates nav.conf on manage_nav for READS TOO ($is_write is a parameter and this branch ignores it), so a 200 means they also hold manage_nav, not that manage_config reaches the file. They had not tested the PUT, and were right not to - it is a live nav on somebody's site. SEVERITY IS LOW AND THE CLASS IS NOT: nothing is over-permitted, since enforcement is the strict side and a manage_config-only partner is correctly refused. The cost is that the descriptor is the thing partners are told to trust, so it sends an agent to a 403 and then to trial and error - the exact failure RI-002's deny reasons exist to end. It is also the SM421 rule read backwards: there the surface withheld what the permission granted; here the descriptor grants what no permission delivers. Surfaces agreeing has to mean the descriptor agrees with the code as well. REMEDY, and it is two lines: drop 'lazysite/nav.conf' and 'lazysite/forms/<name>.conf' from manage_config's webdav list in Capabilities.pm. Everything manage_config legitimately unlocks is on its api list and unaffected. Worth a lint alongside it, since this survived a deliberate refactor that touched all three entries."
---

# What each side says

```datatable
columns: Source | Says about lazysite/nav.conf over WebDAV
widths: 7cm | X
bold: 1
tone: medium
---
`Capabilities.pm:84` (`manage_nav`) | covered - **correct**
`Capabilities.pm:130` (`manage_config`) | covered - **stale since 0.8.1**
`lazysite-dav.pl` `authorise()` | `manage_nav` or 403, read and write alike
A site's onboarding brief | everything under `lazysite/` is internal, PUT refused
```

::: widebox
Three of the four agree. The one that disagrees is the one written to be
read by partners, which is the worst place for it to be wrong.
:::

# Why it survived

The 0.8.1 change moved two files to narrower capabilities and documented
itself carefully at both destinations - the code comments name
`Capabilities.pm` as the place that records ownership, which reads as though
the descriptor had been reconciled. It had been, in the two entries that
gained the files. Nothing looked at the entry that should have lost them.

A capability that lists a path is making a promise. Nothing currently checks
those promises against the code that enforces them, and this pair sat wrong
through every release since 0.8.1.

# What it is not

Not an over-permission: enforcement is the strict side, so a partner holding
only `manage_config` is correctly refused. Nothing needs a security round.

The brief the reporter compared against is also not wrong in spirit - it says
`lazysite/` is internal, which is true of everything except the carve-outs.
Whether it should name them is a separate question about that site's own
onboarding text, not about the engine.
