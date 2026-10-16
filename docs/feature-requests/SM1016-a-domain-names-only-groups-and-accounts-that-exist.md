---
id: SM1016
title: "SM1016: a domain names only groups and accounts that exist"
subtitle: "A domain's allowed_groups and locked_users took any name, so a misspelt group admitted nobody and said nothing; domain_set now refuses a new name the site does not have."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 U4, ruling of 2026-10-12 ("lazysite-domains.pl should reject invalid groups")
area: manager
status-note: "SHIPPED (0.15.5): domain_set refuses each unknown NEW name in allowed_groups / locked_users, naming them, writing nothing. Only names being added are checked; the release manager confirmed this on 2026-10-12: \"keep the design choice\" (t/unit/manager/284, t/tools/121, t/integration/150)."
---

# The ruling

"lazysite-domains.pl should reject invalid groups" - on every surface, so the
check is in `domain_set` (lib/Lazysite/Manager/Domains.pm), which the Domains
page, the control API's `domain-set`, MCP `domain_set` and every
`lazysite-domains.pl` command reach.

# What it does

`domain_set` refuses a NEW name in `allowed_groups` that is not a group on the
site (the groups file or groups-settings.json), or in `locked_users` that is
not an account. The refusal names every unknown name and nothing is written. A
store that cannot be read refuses the write.

A name the list already holds is not asked about. The Domains page shows a
refused save's reason; it used to carry on and say "Saved".

# The design choice, confirmed

The unknown-name check applies only to names being added. A group deleted
after it was allowed therefore never makes the list unwritable: the domain's
other access keys can still be saved, and the stale name can be taken out.

The release manager confirmed this on 2026-10-12, in their words: "keep the
design choice".

# Tests

t/unit/manager/284, t/tools/121, t/integration/150.
