---
title: "SM180 - Dormant-capability indicators (service off vs capability granted)"
subtitle: "Warn, don't block: show when a granted channel capability can't work because its site service is disabled"
brand: plain
status: candidate
status-note: "proposed 2026-07-19, target 0.9.5. Follows the 0.9.x service killswitches (0.9.4 stable). UI-only, no backend or migration."
---

# SM180 - Dormant-capability indicators

## Why

0.9.x put every remote surface behind a site-level killswitch (`webdav_enabled`,
`mcp_enabled`, `control_api_enabled`, `token_exchange_enabled`, and `manager:`
for the interactive UI), default off. Capabilities, meanwhile, are granted
per user/group (`webdav`, `api`, `mcp`, `ui`, and the action caps that only
function *over* one of those channels).

Those two planes are independent, so a grant can be **dormant**: the account
holds the capability but the corresponding service is off, and it silently does
nothing. Worse, when an operator *disables* a service, every holder of that
channel capability becomes dormant at once - with no visibility into who is
affected or why their integration just stopped.

This is the same "each unit correct, the seam invisible" gap that produced the
0.9.0 config-save bug and the ungrantable-`feedback` drift (SM042 / the grid
parity guard). Here the seam is between a per-principal grant and a per-site
service state.

## What (not) to do

**Rejected - block the toggle** (refuse to grant `webdav` while `webdav_enabled`
is off). Rejected because it:

- does not cover *later* deactivation - a service switched off after grants
  exist leaves every holder dormant with no signal;
- hides the blast radius - the operator can't see who is affected;
- wrongly forbids legitimately pre-granting a capability before a service is
  switched on (a normal provisioning order).

**Proposed - indicate, don't block.** Surface the dependency; never prevent the
grant.

## Design

1. **Groups + Users capability grids.** When a *channel* capability
   (`ui` / `webdav` / `api` / `mcp`) is ticked but its service is disabled
   site-wide, render a warning dot on that cell with a tooltip, e.g.
   *"The WebDAV service is disabled site-wide - a site admin must enable it in
   Settings -> Services for this grant to take effect."* Channel -> killswitch
   map: `webdav` -> `webdav_enabled`, `mcp` -> `mcp_enabled`,
   `api` -> `control_api_enabled`, `ui` -> `manager`. An *action* capability
   (e.g. `manage_content`) is dormant only if the account holds no live channel,
   so the honest signal lives on the channel caps; the action row can carry a
   softer "no active channel" hint when all of the account's channels are off.

2. **Services page, reciprocal view.** Beside each service, show
   *"held by N groups / M users"* so that before flipping a killswitch the
   operator sees the blast radius, and after, exactly who to notify.

## Why it is cheap

The grids already load `config-read` (which surfaces the `*_enabled` states since
SM042) and the capability set; the indicator is a pure client-side
cross-reference - no new backend, no new endpoint. It composes with the existing
`t/lint/18` (config-key parity) and `t/lint/19` (capability-grid parity) guards,
and it is purely informational - nothing is ever blocked, so there is no new
failure mode and no migration.

## Acceptance

- A group/user granted `webdav` while `webdav_enabled: disabled` shows a warning
  indicator on the `webdav` cell; enabling the service clears it live.
- Disabling a service that live grants depend on makes every holder's indicator
  appear, and the Services page reports the affected counts.
- No grant is ever blocked by a service being off.
