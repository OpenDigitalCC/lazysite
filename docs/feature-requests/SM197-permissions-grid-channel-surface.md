---
title: "SM197 - Permissions grid over-claims channel coverage (ignores per-capability surface)"
subtitle: "The Users-page capability x channel grid shows a tick wherever a group grants the capability AND the account holds the channel - without checking whether the capability has any surface on that channel. So it advertises reach the engine never implements (manage_domains on WebDAV, notifications on MCP, ...)."
brand: plain
status: candidate
status-note: "field diagnosis 2026-07-22 (0.9.10). A compliance-surface DISPLAY defect - enforcement is unaffected. renderPermGrid cell = by(action) && by(channel); it must also require the capability to have a surface on that channel."
---

# SM197 - Permissions grid over-claims channel coverage

## Why

The Users-page capability x channel grid (`starter/manager/users.md`,
`renderPermGrid`) decides each cell with:

    var ok = by(a) && by(c);   // action granted by a group  AND  channel held

i.e. a tick iff some group grants the action capability AND the account holds the
channel. It never consults whether that capability EXPOSES anything on that
channel. The per-capability channel surface is declared in
`Lazysite::Capabilities` (`unlocks => { ui/webdav/api/mcp => [...] }`) - the same
map `describe_capabilities` serves - but the grid payload (`cmd_permissions_grid`,
`tools/lazysite-users.pl`) returns only `granted_by` per capability and the held
channels separately; it carries no surface data, so the UI cannot and does not
gate on it.

Result: the grid ticks capability/channel combinations the engine never
implements. Confirmed against the `unlocks` map (0.9.10):

- Domains & site packages (`manage_domains`): unlocks api + mcp only -> the WebDAV
  tick is wrong.
- Analytics (`analytics`): api + mcp only -> WebDAV tick wrong.
- Notifications (`notifications`): ui only (the bell) -> WebDAV AND MCP ticks both
  wrong.
- Agent feedback (`feedback`): mcp only -> WebDAV tick wrong.
- Read submissions (`read_submissions`): api + mcp only -> WebDAV tick wrong.

The legend states "tick = has the action AND the channel", which is exactly what
the code does - but that is the wrong contract for an operator's compliance view.
It should mean "the account can actually DO this capability THROUGH this channel",
which additionally requires the capability to have a surface there.

Why it matters: this grid is the operator's audit surface for "who can do what,
where". Over-claiming reach (a tick for a channel a capability cannot touch)
undermines it as an audit tool - an operator reviewing an agent's WebDAV exposure
sees ticks that correspond to no real WebDAV surface. Enforcement is unaffected
(the engine gates correctly; nothing extra is actually reachable) - this is a
DISPLAY / compliance-integrity defect, the same reflect-reality theme as SM180
(dormant channels), SM190 and SM196.

## Design

1. Carry the surface in the payload. Have `cmd_permissions_grid` include, per
   capability, the channels it actually unlocks (derived from
   `Lazysite::Capabilities` `unlocks`) - a `surface => { cap => { channel => 1 } }`
   map, single source of truth, so a new capability's surface appears
   automatically.
2. Gate the cell on it: `ok = by(a) && by(c) && surface[a][c]`. A cell where the
   capability is granted and the channel held but the capability has NO surface
   there should render as a muted "granted, but no <channel> surface" state (a
   distinct glyph / tooltip), NOT a tick - so the operator sees the truth without
   the row silently vanishing.
3. Keep the SM180 dormant-channel warning orthogonal (channel held but service
   off): a cell can be both surfaced-and-dormant.

## Secondary (clarity)

The same diagnosis showed an operator can mistake WHOSE grid they are viewing: the
grid is account-scoped (`granted_by` resolved from the target user's groups), but
an operator viewing their own account - who sits in several groups - sees the
union of their groups and may read it as the agent's grants. Consider labelling
the grid with the account it describes, and offering a clearly group-scoped
catalogue view on the Groups page. Minor; the channel-surface fix is the SM.

## Not the same as the tools/list issue

Distinct from SM196 Part 3 (an authenticated MCP `tools/list` advertising tools
the caller cannot invoke). That is the agent-facing discovery surface; this is the
operator-facing compliance grid. Both are reflect-reality corrections; fix
independently.

## Tests

- `cmd_permissions_grid` payload includes the per-capability channel surface from
  `Lazysite::Capabilities` `unlocks`.
- A capability with no surface on a channel (e.g. `manage_domains` x webdav,
  `notifications` x mcp) renders as "no surface", not a tick, even when granted
  and the channel is held.
- A capability WITH surface (e.g. `manage_content` x webdav, `manage_domains` x
  mcp) still ticks when granted and the channel held.

Related: `starter/manager/users.md` (`renderPermGrid`, cell = `by(a) && by(c)`),
`tools/lazysite-users.pl` (`cmd_permissions_grid`), `Lazysite::Capabilities`
(`unlocks` - the channel-surface source of truth; `describe_capabilities` serves
the same map), SM095 (the permission viewer), SM180 (dormant-channel warnings),
SM196 (tools/list reflect-reality).
