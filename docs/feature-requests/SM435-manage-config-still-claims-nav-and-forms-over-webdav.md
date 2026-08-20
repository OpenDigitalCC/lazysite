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

# Why the field cannot settle this, and what that implies

The reporter holds `manage_nav` AND `manage_config` on the grant they tested
from. The `nav.conf` branch of `authorise()` ignores `$is_write`, so it gates
reads too. Two sufficient causes, one observation, no attribution available -
their 200 was incapable of coming out either way.

A decisive test needs a grant holding `manage_config` and NOT `manage_nav`,
which a partner cannot create for itself. So reading the enforcement was not
the faster route to the answer here. It was the only one.

::: widebox
That generalises past this filing. **A partner cannot determine which
capability grants a given access**, because the only instrument available -
try it and see - reports the union of everything they hold. The descriptor is
the sole thing that claims to break the grant down per capability, and this
filing exists because it was wrong.
:::

That bears on the permission-explanation work: whatever text tells an operator
what a capability unlocks is not a convenience. It is the only account of the
boundary that anyone outside the code can read, and nothing currently checks it
against the code. Worth carrying into that thread rather than leaving here.

# The test that would have caught it

Proposed from the field, and it is better than the vague "add a lint" this
filing started with, because it checks the two things against each other in
the one place a partner actually meets them.

Every WebDAV denial already names its capability, in a parseable shape:

```
'editing lazysite/nav.conf requires the manage_nav capability'
'editing lazysite/forms/<name>.conf requires the manage_forms capability'
'theme/layout authoring over WebDAV requires the manage_themes or manage_layouts capability'
```

So a test can extract, per governed path, the capability set the DENY REASON
names, and compare it with the set of capabilities whose `webdav` list in
`Capabilities.pm` contains that path.

::: widebox
**It only works as SET EQUALITY.** A membership check - "the capability the
denial names does appear in the descriptor" - passes cleanly against exactly
this defect, because `manage_nav` does list `nav.conf`; the surplus
`manage_config` entry is invisible to it. The failure here is an EXTRA claim,
not a missing one, so the assertion has to be that no other capability claims
the path either.
:::

That distinction is the whole value of the test. Written the loose way it is
another green test that proves nothing, and this filing would not exist to
show it. Sabotage it against the current `manage_config` entry before trusting
it: it must fail while line 130 stands, and pass once it is removed.

The class is wider than WebDAV - the API and MCP planes make the same
per-capability promises - but the deny reasons make WebDAV the plane where the
check is nearly free, and it is where the defect is.

# The evidence a partner can and cannot supply

From the field, and it sharpens what to expect from that direction:

```datatable
columns: Observation | What it settles
widths: 8cm | X
bold: 1
tone: medium
---
SUCCESS while holding several capabilities | **nothing** - the grant is a union, any member may be the cause
REFUSAL while holding the capability the descriptor names | **the descriptor's promise is false for that grant**
```

So the field can CONTRADICT an over-claim and can never CONFIRM one. Anything
arriving from a partner on this will be a denial, and that is the useful
direction: this filing is an over-claim.

::: widebox
**With one qualification, because the refusal is decisive about the PROMISE
and not automatically about the CAUSE.** `authorise()` refuses on four other
grounds that have nothing to do with capabilities - outside the assigned
WebDAV scope, the server blocklist, a per-file ACL, and the active
theme/layout read-only rules. A 403 falsifies "holding this capability lets
you write this path" however it arose, but it does not by itself say the
capability mapping is what went wrong.

What closes that gap is already shipped: RI-002 makes every denial name its
own ground. So a field refusal becomes decisive about the mechanism as soon as
the report carries the deny reason verbatim - which is worth asking for, and
is a use for those strings beyond ending an agent's trial and error.
:::

For `nav.conf` specifically the qualification does not bite: the capability
branch is reached before scope, blocklist and ACL, and returns allowed
outright when `manage_nav` holds. A refusal there can only be the capability.
That is a property of this path's position in `authorise()` rather than a
general rule, and it is worth knowing it is not general.
