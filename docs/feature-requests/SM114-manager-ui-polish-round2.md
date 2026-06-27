---
title: "SM114 - manager UI polish, round 2"
subtitle: "Follow-ups from the SM109 live review"
brand: plain
---

::: widebox
Smaller refinements raised after living with the modernised manager (SM109). The
dark-mode contrast bugs from the same review are fixed separately (in the release that
files this doc); these are the remaining behaviour/ergonomics items.
:::

## Site settings (Config page)

Manager access groups as a picker
: `manager_groups` is still free text; make it a multi-select of existing groups
  (this is [[SM107]]).

Booleans as toggles, not dropdowns
: site-settings fields that are enabled/disabled or true/false selects (manager,
  webdav_enabled, search_default) should render as switches, matching the rest of the
  manager.

Warn before disabling the manager
: setting `manager` to disabled locks out the manager UI; the Save should confirm
  ("This disables the manager UI for everyone - continue?") before applying, like the
  rotate-secret danger flow.

Logical grouping + ordering
: review the site-settings order and group it logically (e.g. Identity: site name /
  URL; Appearance: layout / theme / nav file; Access: manager / manager path / groups /
  WebDAV; Content: searchable-by-default) with section headers, rather than one flat
  list.

## File manager

Breadcrumb root as a file icon
: the editor breadcrumb shows `/` as the root; replace it with a file/home icon. Use
  the *same* breadcrumb component on the Files page as in the editor, for consistency.

(Sortable columns + pagination are [[SM111]]; not repeated here.)

## Status

Queued. Each item is small and local (config.md for the settings ones; files.md /
edit.md for the breadcrumb). The booleans-as-toggles and grouping are the most
visible; the disable-manager warning is a safety item worth doing with them.
