---
title: "SM191 - Discoverability hints for capability-gated areas (grant X to enable)"
subtitle: "The inverse of SM180: when a manager area is hidden because a capability is not granted, tell the operator which capability unlocks it and where to grant it - instead of it silently not appearing"
brand: plain
status: candidate
status-note: "IMPLEMENTED on claude/cluster-a-plus-sm192 (2026-07-23): the processor surfaces the content-area caps (content/nav/themes/layouts) + audit in manager_caps; layout.tt gates the Files / Navigation / Appearance / Audit-log nav entries with the SM186 3-way pattern (real link if held, muted grant-to-enable hint if the operator holds manage_users, nothing otherwise). Tests in 28-domains-nav.t. SCOPE for review: applied to the content group + audit; left the access-admin (Users/Groups/Sessions), config/system (Site settings/Cache/Backups/Plugins) and plugin-gated (stats) entries as-is - extending to those is a UX judgement for the reviewer. Awaiting gate + vcs-review."
---

# SM191 - Discoverability hints for capability-gated areas

## Why

A manager area that needs a capability the operator's group does not hold simply
does not appear - no nav entry, no explanation. The operator cannot tell whether
the feature is missing, broken, or just ungranted, and there is no pointer to how
to enable it. This is the confusion behind several field questions ("I added
domains to the admins group but it is still not on the menu"). SM186 added a
single instance of the fix - a "Domains" grant-to-enable nav hint - and this
generalises it to every gated area.

It is the INVERSE of SM180: SM180 flags a capability that IS granted but is
DORMANT because its service is off; SM191 flags an area that is HIDDEN because the
capability is NOT granted. Together they cover both seams between the grant plane
and what the operator sees.

## Design

For each capability-gated manager area (nav entry / page), when the current
operator does NOT hold the gating capability but COULD grant it (they hold
manage_users), render a muted, disabled-looking hint in place of the missing
entry - e.g. a greyed "Domains &#128274;" with a tooltip "Grant 'Domains & site
packages' on the Groups page to enable this." Clicking it goes to the Groups page.

- Drive it from the same capability model SM180 uses: the manager already knows
  the operator's caps and the per-area gating capability (Capabilities.pm and the
  @CAP_KEYS <-> area map). This is a client-side cross-reference - no new backend.
- Only show the hint to an operator who can act on it (holds manage_users). A
  non-granting user sees nothing - no point teasing an area they cannot unlock.
- Keep it at the nav / section level, not every button, so it informs without
  clutter. SM186's Domains hint is the template; extend the same treatment to the
  other gated areas (Users, Forms, Themes, Layouts, Analytics, Audit, ...).

## Why it is cheap

The nav is already rendered per request with the operator's resolved capabilities
(SM186 made manager pages uncached), and the area-to-capability map already
exists. The hint is a presentational branch on data the manager already has -
like SM180's dormant indicators, but on the "not granted" side.

## Acceptance

- An operator with manage_users but not manage_domains sees a disabled "Domains"
  hint pointing to the Groups page; granting the capability makes the real entry
  appear (already true for Domains via SM186 - extend to the rest).
- An operator who cannot grant capabilities (no manage_users) sees neither the
  area nor a hint.
- No area is unlocked or bypassed by the hint - it is purely informational.

Related: SM180 (dormant-capability indicators - the inverse), SM186 (the Domains
grant-to-enable nav hint, the first instance), Capabilities.pm (the capability
model that both read).
