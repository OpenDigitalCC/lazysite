---
title: "SM564: a group is judged by its reach, not its record"
subtitle: "The operator built a dedicated testing group rather than trust the existing ones. A group's declared capabilities and its EFFECTIVE reach are different things - SM570 proved an account holding no content capability could rewrite ACLs."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): Lazysite::Capabilities::reach_for maps a capability set to per-channel {held, unlocked, callable} from the unlocks tables, and tools/lazysite-users.pl gains the read-only `group-reach [GROUP]` command reporting it per group through the nesting closure (groups existing only in the membership file included). Proving test t/unit/users/33-a-group-is-judged-by-its-reach.t: one capability + its door yields exactly the table's unlock list, a door alone yields nothing, nesting inherits. The seeded-groups review is a section in this filing: four groups still fit, agent-ai/mcp-ai drifted (SM431 gave them ACL verbs; five newer capabilities undecided), `members` has no reach at all. ASKED BY THE OPERATOR 2026-08-25 via the site agent: verify whether the existing groups still make sense or want reorganising. The agent's angle is the right one - answer it EMPIRICALLY: for each group, what set of actions can a member actually call across all four surfaces, then compare with what the group is for. Live group data stays on the operator's sites (the tool is handed over, never the enumeration), so the deliverable is (1) a `group-reach` report in tools/lazysite-users.pl computed from the same four tables the dispatchers use, and (2) that report run against the STARTER's seeded groups here, with a written review. PLANNED for the cycle after the beta publish."
---

# The ask

Per group: the effective callable set on Manager UI, WebDAV, API and MCP, derived from the live capability tables, beside the group's stated purpose. Drift between the two is the finding.

# The review of the seeded groups (2026-08-25, run at 0.10.32)

`group-reach` run against a fresh `install.pl` of the starter (never a live site). The surface today: 16 action capabilities; 74 control-API actions, 67 MCP tools, 5 WebDAV path shapes, 4 table-recorded manager-UI unlocks. One caveat first: the `unlocks` tables record `ui` entries only for the four capabilities that are ABOUT the manager (users pages, notifications bell, sub-user creation and its delegation) - the content/theme manager pages are "the manager itself" and carry no table rows, so a `ui` door reads `open 0 callable` for editor-shaped groups. That is a property of the tables, not of the groups.

Still make sense
: **content-editors** (ui+webdav; manage_content/nav/forms - 3 WebDAV shapes callable, 23 API actions and 36 MCP tools correctly behind closed doors): the interactive editor role, coherent. **design-team** (ui+webdav; manage_themes/layouts): coherent; its WebDAV reach is the two read-only layout/theme paths, its real work is manager pages. **user-managers** (ui; manage_users, notifications, create_sub_users, delegate_sub_user_creation - exactly the 4 table-recorded ui unlocks): the cleanest fit of the six. **lazysite-admins** (all 16 action capabilities, ui+webdav, grantable: api/mcp): `74 unlocked / unreachable on api` and `67 on mcp` reads alarming but is the designed SM127/SM467 shape - manager groups are interactive-only and may CONFER the remote doors without holding them.

Drifted as capabilities were added
: **agent-ai** (webdav+api) and **mcp-ai** (mcp) hold the identical six action capabilities (content, nav, forms, themes, layouts, analytics) and differ only by door - one role, two groups, kept apart so each door is granted deliberately. Their REACH has drifted twice over. First, SM431 folded acl-get/set/remove into manage_content, so agent-ai gained the power to rewrite content ACLs over the API (3 of its 38 callable actions) with no grant changing - exactly the SM570 shape this SM exists to surface. Second, five capabilities added since the seed (manage_domains, manage_data, audit, feedback, read_submissions) are granted to neither, so an agent partner cannot touch typed data (17 API actions / 13 MCP tools) or domains without a manual grant; read_submissions matters less (form-submissions admits manage_forms too). Both gaps may be right, but nobody has decided them - that decision is the follow-up.

No reach at all
: **members** exists only in the seeded groups FILE (`members: manager`) with no settings entry: it holds nothing and opens no door; its only meaning is as an `@members` ACL target. Give it that one sentence of purpose in the starter, or retire it from `groups.example`.

# The proving test

A unit test seeding a group with one capability and asserting the report lists exactly the actions the four tables unlock for it - and nothing a channel flag alone would add.
