---
id: SM1014
title: "SM1014: a group is @name wherever one is picked or shown beside people"
subtitle: "Files and Data offered @staff; the other group pickers and lists named it staff. All now show @staff through one helper; what each store keeps is unchanged."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 U2, ruling of 2026-10-12 ("groups should be prefixed with something say @ so they can be distinguished from users, and this should be consistent anywhere a group is picked")
area: manager
status-note: "SHIPPED (0.15.5): every group picker and group named beside people shows @name through one layout helper; groupPrefix retired (lint 230); input with or without @; each store keeps its form (t/unit/manager/282, 283). Landed 76a6c505."
---

# The ruling

"groups should be prefixed with something say @ so they can be distinguished
from users, and this should be consistent anywhere a group is picked"

# What it does

Files and Data already offered `@staff`. The Groups members picker, the Domains
access picker, the add-user group picker, Connectors' caller groups, the Users
page's group ticks and capability grid, the Settings "Granted by" note and the
approval message named it `staff`. All now show `@staff`, through one layout
helper. The shared picker's `groupPrefix` option, which let a page name groups
plainly, is retired, and lint 230 keeps it so.

On the Groups page the `@` is what decides nest-or-add, so a person who shares
a group's name can now be added.

A group is accepted with or without its `@`. Storage is unchanged: ACL rules
keep `@staff`, while `allowed_groups`, a group's member list, a connector's
callers and group-add keep `staff`. `domain_set` takes `@staff` in
`allowed_groups` on every surface and stores `staff`. `lazysite-users.pl
groups` lists a nested group as `@staff`.

Docs: the manager guide's Groups, Users and Domains pages. Tests:
t/unit/manager/282, 283; t/lint/230.

# Note

This filing was written on 2026-10-13, after the change landed: the branch
carried a CHANGELOG entry but no filing, which the 0.15.5 release gate's
lint 26 found. The text is taken from the landed commit and the CHANGELOG
entry.
