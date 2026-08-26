---
title: "SM631: the seeded groups are a capability list wearing job titles, and two of them differ only by which channel they use"
subtitle: "Operator, after finding an agent grant with an all-blank MCP column: 'maybe groups need another review, or some aggregate groups, so that they emerge on the user page as roles'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26) on the operator's ruling - fixing up old grants as they go, so the new-site-only reach is accepted rather than worked around. Ten backend bundles (seven cap-*, three ch-*) and eight roles, nested so a role resolves to the union of its bundles through caps_for - the same resolver the gate uses, so a role that reads right on the page cannot resolve wrong at the door. NESTING DIRECTION IS WRITTEN ONCE, in _default_group_nesting: _group_closure walks from a user's own groups UPWARD, so a bundle LISTS the roles that draw on it, not the reverse. Getting that backwards is the obvious mistake and no caller has to avoid it twice. THE MEMBERSHIP WRITE IS MERGED, NOT OVERWRITTEN, and happens only where the settings file was absent: an existing site's memberships are never touched, because re-homing a live grant is exactly the operation that must not happen by accident. TOOLTIPS: every bundle and role carries a description, and the Users-page picker now shows the LABEL with the description on hover, offers only assignable roles - a backend bundle is refused by group-add (SM616), so listing one was offering a control that can only fail - and still shows any group already HELD even when it is not assignable, because hiding it would hide part of what an account has and leave no way to take it away. PURGE IS IN NO BUNDLE: destroying the last copy never arrives as a side effect of a job title. Six sabotages, all fail, including the two that would quietly undo the design - a capability bundle that also grants a channel, and app-dev given design so the two agent roles collapse back into one. ORIGINAL PROPOSAL BELOW, written before the operator ruled on it. THE MACHINERY ALREADY EXISTS AND THE SEED DOES NOT USE IT: groups nest to arbitrary depth with cycle protection (_group_closure), membership in a sub-group confers the parent's grants, caps_for walks that closure, and `assignable` already separates a ROLE (given to a person) from a BACKEND group (aggregates capabilities and other groups) - which SM616 made the Groups page explain. What ships is six FLAT groups. THE DUPLICATION THAT PROMPTED THIS: `agent-ai` and `mcp-ai` carry IDENTICAL capability sets - manage_content, manage_nav, manage_forms, manage_themes, manage_layouts, analytics - and differ only in channel (webdav+api versus mcp). Two copies of one fact, maintained in parallel, which drift the moment a capability is added to one; and an operator looking at an agent whose MCP column is entirely '·' gets no hint that a sibling group exists. THE FIX IS TO SPLIT THE TWO AXES the capability model already separates everywhere else: WHAT a grant may do, and THROUGH WHICH DOOR. Capability bundles and channel bundles as backend groups; roles as the only assignable groups, composed from them. Adding a capability to `cap-content` then reaches every role that uses it, and a role gains a channel by nesting one more bundle rather than by growing a twin. WHAT THE OPERATOR ASKED FOR is roles that read as jobs - 'web dev, intranet apps, user manager' - with overlaps accepted. That is what the Users page should show: a role name, with the 19x4 capability grid as the detail behind it rather than the primary view. MIGRATION IS THE HARD PART AND IS WHY THIS IS A PROPOSAL: _ensure_groups_seeded returns early when the settings file exists, so this reaches NEW sites only unless someone writes a migration that re-homes live grants - and re-homing a live grant is exactly the operation that must never widen one by accident. A safe migration ADDS the bundles and roles, leaves existing groups and memberships untouched, and lets an operator move people across deliberately."
---

# What ships now

| Group | Capabilities | Channels |
|---|---|---|
| `content-editors` | content, nav, forms | ui, webdav |
| `design-team` | themes, layouts | ui, webdav |
| `agent-ai` | content, nav, forms, themes, layouts, analytics | webdav, **api** |
| `mcp-ai` | content, nav, forms, themes, layouts, analytics | **mcp** |
| `user-managers` | users, sub-users, notifications | ui |
| `lazysite-admins` | everything bar the remote channels | ui, webdav |

`agent-ai` and `mcp-ai` are the same row twice.

# Proposed: three layers, one of them assignable

**Capability bundles** - backend, `assignable: 0`:

| Bundle | Holds |
|---|---|
| `cap-content` | manage_content, manage_nav, manage_forms |
| `cap-design` | manage_themes, manage_layouts |
| `cap-data` | manage_data, manage_briefs |
| `cap-site` | manage_domains, manage_config |
| `cap-people` | manage_users, create_sub_users, delegate_sub_user_creation, notifications |
| `cap-observe` | analytics, audit |
| `cap-tidy` | housekeeping |

`purge` joins no bundle: it is the irreversible tier (SM587/SM591) and stays an
explicit, separate decision.

**Channel bundles** - backend, `assignable: 0`: `ch-interactive` (ui, webdav),
`ch-agent` (mcp), `ch-script` (api, webdav).

**Roles** - the only `assignable: 1` groups, and the only thing an operator picks:

| Role | Composed from |
|---|---|
| Website editor | `cap-content` + `ch-interactive` |
| Designer | `cap-design` + `ch-interactive` |
| Web developer (AI) | `cap-content` + `cap-design` + `ch-agent` |
| App developer (AI) | `cap-content` + `cap-data` + `ch-agent` |
| Site administrator | `cap-content` + `cap-design` + `cap-site` + `cap-tidy` + `ch-interactive` |
| User manager | `cap-people` + `ch-interactive` |
| Analyst | `cap-observe` + `ch-interactive` |
| Lead reader | read_submissions + `ch-script` |

Overlaps are intended: a web developer and an app developer share `cap-content`,
and changing what "content work" means changes both at once.

# What this buys, and what it costs

**Buys.** One capability set per job rather than one per job-and-channel. A
capability added to a bundle reaches every role using it, so the drift that
`agent-ai`/`mcp-ai` invites cannot happen. An operator assigning access picks
from eight named jobs instead of composing nineteen capabilities across four
channels. And `assignable` already refuses to put a person directly into a
bundle, so the layering is enforced rather than merely documented.

**Costs.** More groups exist, though only the roles are visible where assignment
happens. The nesting direction is counter-intuitive - membership in the SUB
confers the PARENT's grants - so the page must say "this role includes
`cap-content`" and never show raw nesting. And the migration question above is
real: this is safe for a new site and needs a deliberate, operator-driven move
for an existing one.
