---
title: "SM587: does destructive mean the object cannot be recovered, or the effect cannot be undone?"
subtitle: "acl-remove is reversible as an object - the rule can be re-set - and irreversible as an effect: content that was exposed cannot be un-exposed. SM576's copy test does not decide this case."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33: the second axis is named `changes_access` - named after its TEST (does the call alter who may read?) rather than after an outcome, because `exposes` would be a false word on every acl-set that TIGHTENS a rule and the next classifier would be arguing about direction, which is what Option B was rejected for. The rule for BOTH flags is written once beside %MUTATING / %DESTRUCTIVE / %CHANGES_ACCESS in lazysite-manager-api.pl and referenced from MCP's %ANNOTATE, so neither is ever assigned by argument; a flag is a property of the ACTION and never of its arguments (`save` writing `draft: true` is not a carrier). Carriers: acl-set, acl-remove, preview-grant, preview-clear on the control API and set_permissions on MCP - there is no separate publish verb, acl-set's `draft` flag being the draft/publish pair, so one action carries both directions. acl-remove is not destructive (it never was) and does carry the exposure flag. Surfaced by _action_effects on actions-list and describe-capabilities, and as a fourth %ANNOTATE slot published as `changesAccessHint`; t/lint/23 gains a third twin check so the two spellings cannot drift. Proving test t/unit/manager/112-exposure-is-its-own-axis.t drives the real CGI and asserts the divergence in both directions. DECIDED BY THE OPERATOR 2026-08-25: OPTION A PLUS A SECOND AXIS. `destructive` means THE DATA CANNOT BE RECOVERED, assigned by the copy test (does the engine retain a copy?), which is mechanical and keeps the flag discriminating. A SECOND FLAG carries what Option B was reaching for - THIS CHANGES WHO CAN SEE THINGS - and is borne by acl-set, acl-remove, set_permissions, preview-grant and the draft/publish verbs. So `acl-remove` is not destructive and does carry the exposure flag, which is the honest description of it. THE WORK THIS BECOMES: name the second flag, apply it across the action table beside SM572s mutating/destructive pair, surface it on actions-list and describe-capabilities the way SM572 surfaces the others, and state the rule once where a future action gets classified - so neither flag is ever assigned by argument. UNBLOCKS SM591, whose tiers are now derivable: the lateral grant covers the deletion verbs by the copy test, and the ACL verbs stay under manage_content carrying the exposure flag rather than joining a housekeeping grant. ORIGINAL QUESTION BELOW. RAISED BY THE SITE AGENT 2026-08-25 while verifying SM572 on 0.10.32, as a classification question rather than a finding: in its 23-action set, 8 are flagged mutating and 1 destructive (brief-delete); acl-remove is mutating but not destructive. Under SM576's proposed rule - does the engine retain a copy? - that is correct, because an ACL rule can simply be re-set. But the CONSEQUENCE of removing a rule is exposure of content that was gated, and exposure cannot be undone the way a rule can be re-added. The two readings of 'destructive' diverge here and nowhere else either party has looked. RECOMMENDATION, for the operator to take or leave: keep destructive meaning DATA CANNOT BE RECOVERED (the copy test, which is objective and already drafted), and treat exposure as a separate axis with its own word - fold exposure into destructive and every read-enabling change becomes destructive, at which point the flag stops discriminating and a caller learns nothing from it. A second flag (or a per-action note) costs little and keeps both facts sayable. PLANNED with SM576, whose tiers this decides."
---

# The decision, and what it makes buildable

**Option A plus a second axis** (operator, 2026-08-25).

| Flag | Means | Test | Example |
|---|---|---|---|
| `destructive` | the data cannot be recovered | does a copy survive? | `brief-delete` yes; `data-table-drop` no (safety export) |
| the second axis | this changes who can see things | does it alter who may read? | `acl-remove` yes; `brief-delete` no |

`acl-remove` is therefore **not destructive and does carry the exposure
flag** - which is the honest description of it, and neither half is lost.

The work: name the second flag, apply it across the action table beside
SM572's pair, surface it on `actions-list` and `describe-capabilities`
as SM572 surfaces the others, and state the rule once where a future
action is classified - so neither flag is ever assigned by argument.

# The two options, in full

**Option A - "the data cannot be recovered."** Test: does the engine
retain a copy? Mechanical, answerable by reading the code.

**Option B - "the effect cannot be undone."** Test: can the world be put
back as it was? Requires reasoning about consequences.

They agree nearly everywhere: `brief-delete` is destructive under both,
`data-table-drop` under neither (it mints a safety export),
`cache-invalidate` under neither (it rebuilds). The divergence found so
far is `acl-remove`, and only that.

## Why Option B degrades the flag

**It stops discriminating.** Under B, publishing a page is destructive
(someone may have read it), sending a form notification is destructive
(the mail has gone), and SM579's API callouts are destructive by
definition. A flag true of most writes tells a caller nothing - and
SM572 exists so a sweep can ask instead of remember.

**It stops being mechanical.** Every new action becomes an argument
about consequences rather than a lookup.

## The recommendation: A, plus a second axis

Option B is reaching for something real - `acl-remove` IS dangerous and
A alone under-warns about it. The answer is a second flag meaning THIS
CHANGES WHO CAN SEE THINGS, carried by `acl-set`, `acl-remove`,
`set_permissions`, `preview-grant` and the draft/publish verbs. Two
questions, two answers, both mechanical: what happens to the data, and
what happens to who can read it.

# What it decides for SM591

SM591 makes destruction a GRANT in two tiers, assigned by this rule, so
the rule must exist first. The sharper reason is what Option B would do
to the grant's shape:

**Under B, permission management is pulled into the housekeeping grant.**
If `acl-remove` is destructive and the irreversible tier is "the
destructive things", then whoever may clear old backups may also un-gate
content - and an operator who wanted a housekeeper has handed over the
ACL surface. Housekeeping and permission management are different jobs.

Under A they stay apart: the lateral grant covers `brief-delete`,
`data-safety-export-delete`, `backup-delete`, artefact backups, sweeps
and retention; the ACL verbs stay under `manage_content`, and the second
axis is what warns about them.

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
