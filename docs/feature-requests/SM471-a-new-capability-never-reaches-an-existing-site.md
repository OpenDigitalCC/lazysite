---
title: "SM471: a capability added after a site was created never reaches it"
subtitle: "The manager group is seeded once with the capabilities that exist that day. Every capability added later is invisible to that site forever, and the operator meets it as a refusal telling them to grant something they thought they already had."
brand: plain
standard-margins: true
status: partial
status-note: "REPORTING SHIPPED (PENDING), BACKFILL DELIBERATELY NOT. lazysite-check now names any manager group missing capabilities this release has, says WHY they are absent - added after the site was created - and gives the exact group-set command. api and mcp are excluded because SM127 keeps manager groups off the remote channels, so their absence is the design and flagging them would cry wolf on every site. The capability list is a DELIBERATE local copy: lazysite-check is core-Perl by design and cannot load Lazysite::Auth::Settings, so it carries the list the way the processor carries its ACL copy, and t/lint/81 pins the pair - a stale copy would make the check silent about the NEWEST capability, the only one anybody is likely to be missing, failing at its one job while reporting OK. STILL OPEN: whether an upgrade should ever backfill. It cannot today because the code cannot distinguish 'did not exist when this group was made' from 'an operator turned it off', and recording which capabilities existed at seed time would be the way to tell them apart - that is a design question rather than a fix. REPORTED 2026-08-22 by the release manager, from the edge site: 'You cannot grant manage_data - you do not hold it, and it is not in your groups grant authority.' REPRODUCED: a FRESH install's manager group holds manage_data; an existing site's does not, and re-running setup-manager does not backfill it - _ensure_manager_group_caps returns early when the group already has an entry ('return if ref $gs->{$group} eq HASH && %{$gs->{$group}}'). THE DEFECT IS GENERAL, not about manage_data: the manager group is seeded ONCE, with whatever capabilities existed that day, and every capability added in any later release is absent from every site created before it. manage_data is simply the first new capability since the seed was written, so it is the first to expose this. WHAT THE OPERATOR MEETS: a refusal that says 'you do not hold it' about a capability their role is designed to hold, followed by advice to set grant authority - which is the right advice for a delegate and the wrong diagnosis for an admin whose group should simply have the capability. WHY THIS IS NOT FIXED BY BACKFILLING SILENTLY, which was the first instinct: the code cannot distinguish 'this capability did not exist when the group was made' from 'an operator deliberately turned it off'. Granting on upgrade would silently re-grant something an operator had taken away, and this codebase's posture is that a permission change is a decision rather than a side effect - SM455 argued exactly that days ago. Undoing an operator's removal is worse than the inconvenience of being told. SO: REPORT IT. lazysite-check names the manager groups missing capabilities that exist in this release, and gives the command. The operator decides, which is also what makes the answer safe on a site where somebody DID remove one on purpose. NOT PROPOSED: changing what the manager group is for, or granting api/mcp - SM127 keeps manager groups off the remote channels and that stays."
---

# What the operator sees

```datatable
columns: | Fresh install | Site created earlier
widths: 5cm | 3.5cm | X
bold: 1
tone: medium
---
Manager group holds `manage_data` | yes | **no, and never will**
Re-running `setup-manager` | seeds it | leaves it alone
Granting it to somebody else | works | refused: *you do not hold it*
```

# Why the refusal reads wrong

The message is correct and its advice is aimed at a different person. Setting
`grantable` is right for a **delegate** who should be able to hand out a
capability they do not themselves hold. An admin whose group is designed to
hold everything but the remote channels does not need grant authority -- they
need the capability, and being told to configure a delegation mechanism sends
them somewhere that will not fix it.

# Why not backfill

The code cannot tell these apart:

- the capability did not exist when this group was created
- an operator turned it off on purpose

Granting on upgrade gets the second case silently wrong, and re-granting
something somebody removed is worse than telling them about something they are
missing. A permission change is a decision; this codebase has spent a lot of
effort making that true elsewhere.
