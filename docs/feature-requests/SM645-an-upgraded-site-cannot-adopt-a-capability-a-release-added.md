---
title: "SM645: an upgraded site can never adopt a capability a later release added, and every refusal points at a shell the operator does not have"
subtitle: "Operator, 2026-08-27 on 0.11.0: 'You cannot add anyone to family-admins: it grants housekeeping, which you may not confer... i am in the group... can i fix in ui? is this resolved in later versions?'"
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-27 by the operator, from a live site, and BLOCKING them. The answer to both their questions is no. A capability added by a release - `housekeeping` and `purge` arrived with SM591 - is absent from every manager group that already existed, so nobody on that site HOLDS it. The SM195 ceiling lets a non-'local' actor confer only what they hold or what an operator placed in their group's grantable set, and it is applied to granting the capability itself as well as to conferring it. So the Groups page lists the new capability as a pending decision and then refuses to let the operator make that decision: they cannot grant it, because they do not hold it, because it was never granted. THE ONLY ESCAPE IS THE CLI AS `local`, which is the sysadmin side of a line the operator keeps deliberately - and all four refusals name exactly that route, so the product's advice to an app admin is 'get a shell'. NOT FIXED BY SM630: that gives manager groups full grant authority, but `_ensure_manager_group_caps` returns early for any group that already has a record, so it reaches fresh sites only and every upgraded site keeps the trap - which deepens with each release that adds a capability."
---

# The circle

| | |
|---|---|
| Adding someone to `family-admins` | confers `housekeeping` |
| May the operator confer it | only if they hold it, or hold grant authority for it |
| Do they hold it | no - `housekeeping` postdates their group |
| Can they grant it to themselves | no - **the same ceiling refuses that too** |

The second refusal is the one that closes the circle:

    if ( $on && $key ne 'manager' && !_may_confer( $actor, $key ) ) {
        return { ok => 0, kind => 'forbidden', ... };
    }

`_may_confer` deliberately does not treat `manage_users` as operator - an
adversarial review found that exact bypass, and the comment in the source says
so. That reasoning is right. Its consequence, unnoticed, is that on a secured
site nobody reachable through the manager can adopt a new capability at all.

# Why the pending banner makes it worse rather than better

SM496 computes, server-side, the capabilities a manager group has never decided
on, and the Groups page renders them as a decision list. The decision is then
routed through `group-settings-set`, which applies the ceiling above.

So the product identifies the gap, presents it to the right person, and refuses
their answer. An operator reasonably concludes the banner is broken.

# Why upgraded sites and not fresh ones

`_ensure_manager_group_caps` opens:

    return if ref $gs->{$group} eq 'HASH' && %{ $gs->{$group} };

A group with any record is skipped entirely. SM630 widened what a manager group
is seeded with - all capabilities, and `grantable` for all of them - but only
where there was nothing there before. A fresh 0.11.x site is fine. A site that
existed before SM591 has a manager group that will never learn about
`housekeeping`, and will never learn about the next one either.

# The fix, and the line it must not cross

**Top up an existing manager group's `grantable`, and only `grantable`.**

That is the whole of it. `grantable` is authority to confer WITHOUT holding
(SM195), and `caps_for` never reads it - `_may_confer` is its only consumer -
so topping it up grants nobody the ability to do anything. What it restores is
the operator's ability to *decide*: the pending banner starts working, and the
operator chooses whether their site adopts the capability.

**It must not grant the capability itself.** Silently granting `housekeeping`
to every existing manager group on upgrade would widen live grants on
seventeen sites without anybody asking for it - the same thing SM633 refused to
do for `manage_services`, for the same reason. Offering the decision is the
product's job; making it is the operator's.

# The four refusals

Adding to a group, issuing a credential, creating a setup link, and granting a
capability all end with:

    An operator can allow it with: group-set <your-group> grantable <cap>

SM467 added that wording to name a remedy rather than stopping at a refusal,
which was the right instinct. But the remedy is a shell command, and the reader
is an app admin who by policy does not have a shell. `t/unit/tools/41` already
states the rule this breaks - "App support must not need a sysadmin: the UI is
the remedy, the CLI the fallback" - and asserts it for `lazysite-check.pl`
while these four say the opposite.

They should name what the reader can actually do. Once the top-up above is in
place, that is a real instruction rather than a redirection.
