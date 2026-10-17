---
id: SM1132
title: "SM1132: one rule splits a groups header, and the separator is configurable"
subtitle: "A groups header splits in the accessor only, on auth_header_groups_separator (default comma, Authentik sends a pipe), each part trimmed, empties dropped."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: united/platform project, planned in SM1128 (P1-3), ruled 2026-10-17 "rulings as proposed"
area: auth
status-note: "SHIPPED on n631 (claude/n631-every-reader-reads-the-proxy-the-same-way): Lazysite::Auth::Identity; t/unit/auth/62, t/integration/265."
---

# What happened

SM1128, "What the code does today", item 5:

> **Group names.** [...] The page gate splits a group list on commas, the manager
> on commas or whitespace, so a name with a space reads differently on the two.
> Authentik's groups header is pipe-separated.

and the plan, P1-3:

> One rule for splitting a groups header, used everywhere; the separator
> configurable (`auth_header_groups_separator`, default comma, Authentik pipe).

`X-Authentik-Groups: Site Editors|Members` was one group `Site Editors|Members` to
the page gate and four to the manager (`Site`, `Editors|Members`...), and the
three data readers split on `/\s*,\s*/` again.

# What shipped

`auth_header_groups_separator:` in lazysite.conf, default `,`. The split happens in
`Lazysite::Auth::Identity::request_identity` and nowhere else (t/lint/268): on the
separator, each part trimmed, empty parts dropped, a name listed twice kept once.
A space inside a name is not a separator, so `Site Editors, Members` with the
default is two groups.

For a trusted proxy that is the whole rule. For a cookie session the wrapper
writes lazysite group names joined by commas, and those split on commas or
whitespace (a lazysite name has neither); the separator setting applies to the
proxy's header only.

**What case the names come back in.** A proxy's groups come back lowercase,
because SM1133 normalises them, unless `auth_group_map` names a target, which is
returned as written. A cookie session's groups come back exactly as stored; this
change does not lowercase them. The page gate and the ACLs lowercase both sides
when they compare, so either case matches them. Capability lookup
(`Settings::groups_grant_cap`) is case-sensitive and is not changed here: a
directory group reaches a mixed-case group record through the map.

`auth_header_groups_separator` is declared in `lazysite-auth.pl`'s settings and
documented in starter/docs/configuration.md.

Tests: t/unit/auth/62 (pipe, spaces, empty parts, default comma, duplicates);
t/integration/265 (`Site Editors|Members` through the page gate, the ACL read and
the manager; `Site|Editors` is not `Site Editors`).
