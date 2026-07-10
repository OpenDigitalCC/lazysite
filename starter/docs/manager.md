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
```

The manager is disabled by default. Access is the **`ui` capability**,
granted through a group on the Groups page (the seeded `lazysite-admins`
group carries it). Bootstrap in one command:

```bash
perl tools/lazysite-users.pl --docroot /path/to/public_html setup-manager
```

or add a user to the admin group:

```bash
perl tools/lazysite-users.pl --docroot /path/to/public_html \
  group-add alice lazysite-admins
```

(Capabilities on groups are the mechanism of record; the legacy
`manager_groups:` conf key is retired and migrates itself away on upgrade.)

## Accessing the manager

Navigate to `/manager` (or the configured `manager_path`). You must be
authenticated and in a group carrying the `ui` capability. Unauthenticated
visitors are redirected to `/login`.

## Pages

### Site settings

`/manager/` (or `/manager/config`) - the **Site settings** item. Edit site
identity and review the plugin registry.

- **Site settings** - `site_name`, `site_url`, navigation file path,
  `search_default`, manager state, and manager path (manager *access* is
  granted on the Groups page, via the `ui` capability). The active
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
- Review the site's alias redirects in the read-only Aliases card
  (alias → target, with a 301/302 badge; aliases are authored in each
  page's front matter via `aliases:` / `aliases_temp:`)
- Step through a file's **version history** (when content history is
  enabled on the Backups page): each file's expand card gains a History
  panel listing every recorded version (when, who, what) with **View**
  (that version's raw content, read-only), **Diff** (against the current
  file) and **Restore**. A restore is written back as a normal save, so
  it becomes the newest version itself - always reversible.

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

`/manager/users`. User accounts (the same data files as
`tools/lazysite-users.pl`):

- Add, remove, and rename users
- Set or clear passwords
- Assign each user to groups from its card
- A read-only capability grid (channel x action, derived from groups -
  capabilities are edited on the Groups page), sub-users, credentials, and
  onboarding

### Groups

`/manager/groups` (under **Access** in the menu). View, create, and delete
groups, and tick membership per group. A group is defined by its membership, so
creating one needs a first member. (Per-user assignment is also available on the
Users page.)

### Sessions

`/manager/sessions` (under **Access**; needs the **Users & groups**
permission). Lists the live sessions - user, signed in, IP address, device,
with a marker on your own current session - and lets you:

- **Sign out** a single session (its cookie stops working immediately).
- **Sign out everywhere** for one user - all of that user's sessions,
  including any signed in before session listing existed.
- Invalidate **all** sessions at once by rotating the signing secret - every
  cookie, including yours, stops working and everyone signs in again.

Sessions are still signed cookies, not server-side records: the list is an
advisory registry written at login (self-pruned after 24 hours), and
revocations are enforced at cookie verification. Sessions from before this
feature cannot be listed, but per-user sign-out and secret rotation still
kill them. Revocations are recorded in the audit trail.

### Backups

`/manager/backups`. Typed snapshot sections - **Content backups** (create,
download, in-app restore with an automatic pre-restore safety snapshot) and
**Full-system backups** (download only; restored by a system user with
`install.pl --restore-full`, since they carry the auth secrets).

The **Content history** card enables and reports the per-file version history
(SM085): enabling takes an initial snapshot of the current site, then every
save becomes a recorded version, browsable per file on the Files page. The
history covers the content plus `lazysite.conf` / `nav.conf` and never
includes secrets or personal data (accounts, form submissions, logs), so it
is safe to sync to a private remote. It needs the `git` package on the host;
the card says so when git is missing. Full-system backups remain the
disaster-recovery mechanism for exactly what the history excludes.

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
live separately in Visitor statistics, not here. Viewing the audit trail
requires the **Audit trail** permission - its own capability, separate from
Analytics - granted through a group on the Groups page; it is read through an
append-only cache, so only newly-appended lines are parsed on each load.

### Visitor statistics

`/manager/stats`. A read-only dashboard from lazysite's own first-party access
log: the site records its traffic itself (always anonymised at write - a
daily-salted visitor key, never the IP), so statistics work out of the box
with no web-server setup. The web-server access log is the fallback source
when no first-party data exists. Because
lazysite uses no cookies or JS, it classifies traffic by log-only heuristics into
real people, the logged-in operator, AI assistants, bots and probe noise (each
reported separately), splits referrers into external / internal / direct, links
top pages to the live page, and shows per-day counts over a configurable window.
If a server error log is readable (auto-detected),
it also shows a synthesised summary of recent server errors (categories and
counts only - never raw lines, addresses or paths). It never exposes any log
file's path, and the raw logs are not downloadable through the manager.
Provided by the opt-in
**Visitor Statistics**
plugin: the nav item appears only when the plugin is enabled - enable it on Plugin
Manager (recording and retention are tunable on Plugin Config). An AI connector granted
the **Analytics** permission can analyse the same data for trends via the
`analyse_visitors` tool, getting only the aggregated, IP-anonymised figures (see
[AI connector tools](/docs/ai-connector-tools) and
[AI briefing - visitor analytics](/docs/ai-briefing-stats)).

## Admin bar on site pages

When the manager is enabled, the processor injects an admin bar on
site pages (non-manager pages) for authenticated users with manager
access (the `ui` capability). The bar shows:

- Manage - link to `/manager/`
- Edit - link to the editor for the current page
- Sign out
- Warning when the user has no password set

The admin bar sits in normal page flow at the top (it scrolls with the
page, so it never overlaps a theme's own sticky header). Unauthenticated
visitors and non-manager users do not see it.

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

### Manager access enforcement

Access to `/manager` and all sub-pages is restricted to authenticated
users whose groups carry the `ui` capability. Unauthenticated users are
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
