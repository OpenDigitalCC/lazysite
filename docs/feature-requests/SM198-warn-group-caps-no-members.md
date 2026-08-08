---
title: "SM198 - Warn when a group grants capabilities but has no members"
subtitle: "A group can carry capabilities yet have zero members - so it grants nothing to anyone, silently. Create-then-forget and remove-last-member both hit it; a live operator lost time to exactly this. Surface it in the Groups UI."
brand: plain
status: shipped
status-note: "IMPLEMENTED (UI) on claude/cluster-a-plus-sm192 (2026-07-23): groups.md shows a muted 'no members' badge in the group summary and an inline amber warning by the Members section when a group has >=1 capability and 0 members; both refresh in place on cap-toggle / add / remove-member. Client-side only (manager pages are excluded from the render smoke; no JS harness), same as the SM180 dormant badge. Optional API/CLI echo not done. Awaiting gate + vcs-review."
---

# SM198 - Warn when a group grants capabilities but has no members

## Why

Membership and capabilities are two separate stores: the groups file
(`group: members`, read by `read_groups`) and the group-settings file (caps,
label, dav_scope - `read_group_settings`). A capability grant reaches a user only
through MEMBERSHIP: `caps_for` consults only the groups a user is actually in
(`_effective_groups`). So a group that carries capabilities but has no members
grants nothing to anyone - it is inert, silently.

Two ways to land there, both easy:

1. Create-then-forget. Create a group, set its capabilities, and never add a
   member. A live operator did exactly this (a new `mcp-ai-admin` with the caps
   set but the agent account never added as a member), then spent time chasing why
   the agent's grants never changed - because nothing was ever wired to it.
2. Remove-the-last-member. `write_groups` drops any group with an empty member
   list (`next unless @{ $groups{$g} }`), so removing the last member makes the
   membership line vanish while the group's caps persist in the settings file. The
   group still shows in the Groups view (the settings union) but confers nothing.

Nothing in the manager flags this. The Groups editor renders "No members yet." for
the member list but does not say the capabilities above it are therefore doing
nothing.

## Design

UI-first (the Groups page already holds each group's caps and members client-side
- `allGroups[g].caps` / `.members`):

1. Inline warning on the group. When a group has at least one capability set AND
   zero members, show a clear notice on that group: e.g. "This group grants
   capabilities but has no members, so it applies to no one. Add a member to put
   its access into effect." Place it by the Members section, where the fix is.
2. Badge in the group list. Mark such groups in the overview (a muted "no members"
   / "inert" tag) so it is visible without opening each group.
3. Save-time nudge (optional). When an operator sets a capability on a
   member-less group, a non-blocking hint that it will not take effect until a
   member is added - caught at the moment the misconception forms.

Optional API/CLI echo: `group-settings-get` / `_group_settings_view` already
carries `members` per group, so a consumer can compute this, and
`lazysite-users.pl groups` could annotate a member-less group that holds caps.
Keep it advisory (never auto-delete or auto-strip - an operator may deliberately
be staging a group before adding members).

## Not the same as SM197

SM197 is the permissions GRID over-claiming channel coverage. This is a different
gap in the same "make the manager tell the truth" family: a group that looks
configured (caps set) but does nothing. Fix independently.

## Tests

- A group with >=1 capability and 0 members renders the inline warning + list
  badge; a group with members, or a group with no caps, does not.
- Removing a group's last member surfaces the warning (the caps persist, the
  membership does not).

Related: `starter/manager/groups.md` (`allGroups`, `memberPillsHtml` "No members
yet.", `refreshGroupSummary`), `tools/lazysite-users.pl` (`write_groups` drops
empty groups, `_group_settings_view`, `caps_for` / `_effective_groups` -
membership-gated resolution), SM197 (grid channel-surface), and the 2026-07-22
connector diagnosis that surfaced it.
