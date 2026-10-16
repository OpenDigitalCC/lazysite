---
id: SM1013
title: "SM1013: a group or user added to a domain's Access section is saved"
subtitle: "On the Domains page, adding a group or user to a domain's access and pressing Save said \"Nothing had changed.\" and kept nothing; a connector's caller groups were dropped on every save the same way."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 U1, the release manager on the 0.15.4 upgrade of sites.lazysite.io ("adding group to domains, then press save - message: Nothing had changed")
area: manager
status-note: "SHIPPED (0.15.5): the Domains page's Access pickers mark the field changed and Save posts domain-set with the new list (t/unit/manager/280); a connector's caller groups are saved from the boxes that are drawn (t/unit/manager/281). Landed ee93c190, dbf5f52d."
---

# What was wrong

On the Domains page, adding a group to `allowed_groups` (or a user to
`locked_users`) and pressing Save said "Nothing had changed." and kept
nothing. The dirty check recognised the picker by a class it was never drawn
with, so it read as empty before and after.

# What it does now

Adding or removing a pill marks the field changed, the unsaved count says so,
and Save posts `domain-set` with the new list. t/unit/manager/280.

# Found on the way

Checking every page for a picker its save does not read found one more. A
connector's caller groups were drawn as checkboxes and read back from a text
box that is only drawn when the group list cannot be read, so every save on a
site whose groups could be read dropped them - the connector then refused every
signed-in caller - and said "Saved". The ticked boxes are now what is saved.
t/unit/manager/281.

# Note

This filing was written on 2026-10-13, after the change landed: the branch
carried a CHANGELOG entry but no filing, which the 0.15.5 release gate's
lint 26 found. The text is taken from the landed commits and the CHANGELOG
entry.
