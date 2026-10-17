---
id: SM1133
title: "SM1133: a directory group name is mapped to a lazysite group name"
subtitle: "An optional auth_group_map wins, otherwise the name is normalised to lowercase letters, digits, hyphen and underscore; applied to proxy-sourced groups only."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: united/platform project, planned in SM1128 (P1-5, ruling R3), ruled 2026-10-17 "rulings as proposed"
area: auth
status-note: "SHIPPED on n631 (claude/n631-every-reader-reads-the-proxy-the-same-way): Lazysite::Auth::Identity; t/unit/auth/62, t/integration/265."
---

# What happened

SM1128, "What the code does today", item 5:

> **Group names.** Lazysite group names are `[A-Za-z0-9_-]{1,64}`; "Site Editors"
> cannot be one.

the plan, P1-5:

> Group-name mapping for header groups (R3): normalise (lowercase, spaces and
> other characters to hyphens) or an explicit map in lazysite.conf.

and the ruling, R3, ruled as proposed: "Normalise, with an optional explicit map
that wins".

A page gated on `site-editors` could not be opened by a directory group called
`Site Editors`, and the page's author could not write the directory's name in
`auth_groups:` because the gate and the ACLs compare lazysite names.

# What shipped

In `Lazysite::Auth::Identity`, for groups that come from a trusted proxy:

1. `auth_group_map:` in lazysite.conf. One line, comma-separated entries
   `Directory Name = lazysite-name` (the shape of `alias_hosts` and
   `trusted_proxies`; the conf reader is one `key: value` per line):

       auth_group_map: Site Editors = editors, Platform Admins = operators

   The directory name matches ignoring case and runs of spaces. The target is
   returned as written, so a site can map onto an existing mixed-case group; it
   must be a valid group name, and an entry whose target is not (or has no name)
   is ignored with a WARN naming it. The map wins.
2. Otherwise normalise: lowercase, any run of characters outside `[a-z0-9_-]`
   becomes one hyphen, hyphens trimmed from both ends, cut to 64 (the group-name
   rule, `tools/lazysite-users.pl` and `Manager::Groups`).
3. A name that normalises to nothing is dropped, with a WARN in the log
   (`directory group dropped`).

Not applied to a cookie session's groups, which are already lazysite names; they
come back as stored. A name a person has already typed correctly (`editors`)
normalises to itself.

Documented in starter/docs/configuration.md; `auth_group_map` is declared in
`lazysite-auth.pl`'s settings beside the header names.

Tests: t/unit/auth/62 (normalising, the cut at 64, the map, the WARNs);
t/integration/265 (`site-editors` opened by `Site Editors`, `Platform Admins`
mapped onto a page gated on `operators`, an unmapped `Operators Club` not matching).
