---
title: Manager
subtitle: Web-based admin and content manager for lazysite.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

The lazysite manager is a web-based admin UI built into lazysite itself.
It lets you configure the site, manage users, install themes, enable
plugins, edit pages, and clear the cache - all from the browser.

Manager pages are ordinary lazysite `.md` pages served through the
normal pipeline, using a dedicated manager theme for consistent chrome.

## Enabling the manager

Add to `lazysite/lazysite.conf`:

```yaml
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
```

The manager is disabled by default. `manager_groups` restricts access
to members of the listed group(s). Multiple groups can be
comma-separated.

At least one user must be in `manager_groups`. Create one with:

```bash
perl tools/lazysite-users.pl --docroot /path/to/public_html \
  group-add alice lazysite-admins
```

## Accessing the manager

Navigate to `/manager` (or the configured `manager_path`). You must be
authenticated and in a configured `manager_groups` group. Unauthenticated
visitors are redirected to `/login`.

## Pages

### Site settings

`/manager/` (or `/manager/config`) - the **Site settings** item. Edit site
identity and review the plugin registry.

- **Site settings** - `site_name`, `site_url`, navigation file path,
  `search_default`, manager state, manager path, and manager groups. The active
  layout and theme are shown read-only here with a link to **Appearance**, where
  they are changed. Saves to `lazysite/lazysite.conf`.
- **Plugin Manager** (`/manager/plugins`) - lists all discovered plugins
  (every `plugins/*.pl` that answers `--describe`); tick to enable, untick
  to disable.
- **Plugin Config** (`/manager/plugin-config`) - the per-plugin configuration
  UI for the plugins that are enabled.

### Files

`/manager/files`. File browser for the docroot. You can:

- Navigate directories
- Open a page for editing (`/manager/edit?path=...`)
- Create new `.md`, `.url`, and directory entries
- Delete files (with confirmation)

The editor at `/manager/edit` shows:

- Front matter form (title, subtitle, date) plus raw YAML toggle
- Monospace editor for the page body
- Live preview pane
- Save button (writes file and invalidates cache)
- Collaborative edit lock - only one user can edit a file at a time

Locks expire after 5 minutes and are renewed automatically while the
editor is open.

### Nav

`/manager/nav`. Visual editor for `lazysite/nav.conf`:

- Drag and drop to reorder items
- Indent and outdent to change nesting
- Edit labels and URLs inline
- Toggle between link items and group headings

Saves back to `lazysite/nav.conf` as YAML.

### Plugin Manager and Plugin Config

Plugins are split across two pages: **Plugin Manager** (`/manager/plugins`)
enables and disables them, and **Plugin Config** (`/manager/plugin-config`)
configures the enabled ones.

On Plugin Config, each enabled plugin appears with a form generated from its
`config_schema`. Save writes the plugin's config file (e.g.
`lazysite/forms/smtp.conf` for the SMTP plugin).

Plugins that declare `actions` (e.g. Run audit) show action buttons
that invoke the plugin and display the result.

### Appearance

`/manager/appearance` (formerly "Themes"; `/manager/themes` redirects here).
Manage layouts and themes and switch the active pair.

- **Active layout & theme** - the switcher (moved here from Config); activating
  clears the HTML cache.
- **Layouts repo** - the `layouts_repo` setting (and `layouts_ref` for the
  branch the catalogue is read from).
- **Browse the repo** - the repo's `manifest.json` catalogue: install a single
  layout and its theme(s) on demand, with version info.
- **Installed layouts & themes** - activate a layout; **delete a layout** (which
  removes its themes too, behind a confirm, and only when it is not active);
  per-theme activate / preview / rename / delete. Preview now works across
  layouts.
- **Upload a theme** zip (must contain `theme.json` at the root with a non-empty
  `layouts[]` array naming installed layouts).

The same per-layout operations are available to partners over the control API
and the MCP connector (`layout-install` / `layout-delete` / `layouts-manifest`;
`install_layout(update:true)` redeploys a changed layout).

### Users

`/manager/users`. User and group management using the same data files
as `tools/lazysite-users.pl`:

- Add, remove, and rename users
- Set or clear passwords
- Add users to groups and remove them
- View all groups and members

### Cache

`/manager/cache`. Cache inspection and invalidation:

- Lists all cached `.html` files with age and source status
- Invalidate a single cached page
- Clear all cache at once (useful after theme changes)

### Audit

`/manager/audit`. The material-action trail (logins, edits, deletes,
config/theme changes, denied attempts) with who/what/when/where and the
outcome. Filter by user, target, or a From/To date range; each row records
the action's target (the page, the plugin, `nav`, etc.). Browsing analytics
live separately in Visitor statistics, not here.

### Visitor statistics

`/manager/stats`. A read-only dashboard from the web-server access log. Because
lazysite uses no cookies or JS, it classifies traffic by log-only heuristics into
real people, the logged-in operator, AI assistants, bots and probe noise (each
reported separately), splits referrers into external / internal / direct, links
top pages to the live page, and shows per-day counts over a configurable window,
with optional IP anonymisation. It never exposes the log file's path, and offers
an operator-only raw-log download. Provided by the opt-in **Visitor Statistics**
plugin: the nav item appears only when the plugin is enabled - enable it on Plugin
Manager, then set its access-log path on Plugin Config.

## Admin bar on site pages

When the manager is enabled, the processor injects an admin bar on
site pages (non-manager pages) for authenticated users in
`manager_groups`. The bar shows:

- Manage - link to `/manager/`
- Edit - link to the editor for the current page
- Theme switcher - dropdown if more than one theme is installed
- Sign out
- Warning when the user has no password set

The admin bar is a compact fixed-position bar at the top of the page.
Unauthenticated visitors and non-manager users do not see it.

## Installation

The installer copies `lazysite-manager-api.pl` to `cgi-bin/` alongside
`lazysite-processor.pl`. The manager pages in `starter/manager/` are
served as regular lazysite pages; the manager's internal template in
`starter/lazysite/manager/` (D013: outside both `layouts/` and
`themes/`) supplies its chrome.

For manual installation:

```bash
cp lazysite-manager-api.pl /path/to/cgi-bin/
chmod 755 /path/to/cgi-bin/lazysite-manager-api.pl
cp -r starter/manager /path/to/public_html/manager
cp -r starter/lazysite/manager /path/to/public_html/lazysite/
```

## Security

### Manager group enforcement

Access to `/manager` and all sub-pages is restricted to authenticated
users in the configured `manager_groups`. Unauthenticated users are
redirected to `/login`.

### Blocked paths

The manager API blocks read and write access to sensitive files:

- `lazysite/auth/.secret`
- `lazysite/forms/.secret`
- `lazysite/auth/users`
- `lazysite/auth/groups`
- All `.pl` files

User and group management is handled through the dedicated Users page,
not through direct file editing.

### Path validation

All file operations validate paths with `realpath()` to ensure they
resolve within the document root. Path traversal attempts are
rejected.
