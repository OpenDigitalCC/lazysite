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

### Config

`/manager/` (or `/manager/config`). Edit site settings and review the
plugin registry.

- **Site settings** - `site_name`, `site_url`, default theme,
  navigation file path, `search_default`, manager state, manager path,
  and manager groups. Saves to `lazysite/lazysite.conf`.
- **Plugins** - lists all discovered CGI scripts and tools that support
  `--describe`. Tick to enable, untick to disable. Per-plugin
  configuration lives on the Plugins page.

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

### Plugins

`/manager/plugins`. Per-plugin configuration UI.

Each enabled plugin appears with a form generated from its
`config_schema`. Save writes the plugin's config file (e.g.
`lazysite/forms/smtp.conf` for the SMTP plugin).

Plugins that declare `actions` (e.g. Run audit) show action buttons
that invoke the plugin and display the result.

### Themes

`/manager/themes`. Install, activate, rename, and delete themes.

- View all installed themes with active status
- Upload a theme zip (must contain `theme.json` at the root with a
  non-empty `layouts[]` array naming installed layouts)
- Activate a theme (writes `theme:` to `lazysite.conf`, clears the
  HTML cache)
- Rename or delete inactive themes (scoped to the active layout)
- Browse published releases of `layouts_repo` and install themes
  from a chosen release

Uploading a theme that would overwrite an existing directory prefixes
the install path with today's date (e.g. `20260419-mytheme`).

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
