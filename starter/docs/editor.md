---
title: Editor
subtitle: Web-based content editor for lazysite.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

The lazysite editor is a web-based content management interface built
into lazysite itself. It provides a file browser, page editor with
live preview, theme manager, user management, and cache manager. All
editor pages are regular lazysite `.md` pages served through the normal
pipeline.

## Enabling the editor

Add to `lazysite/lazysite.conf`:

```yaml
editor: enabled
editor_path: /editor
editor_groups: lazysite-admins
```

The editor is disabled by default. `editor_groups` restricts access
to members of the specified group(s). Multiple groups can be
comma-separated.

## Accessing the editor

Navigate to `/editor` (or the configured `editor_path`). You must be
authenticated and in the `editor_groups` group.

## File browser

The main editor page at `/editor` shows a file browser. You can:

- Navigate directories by clicking folder names
- Open files for editing by clicking file names
- Create new files with the "New file" button
- Delete files with the per-file delete button

## Page editor

The editor at `/editor/edit?path=filename.md` provides:

### Front matter

Common front matter fields (title, subtitle, date) are shown as form
inputs. The raw YAML is also editable in a collapsible section. Changes
to the form inputs sync to the raw YAML.

### Content editor

A monospace textarea for the page body (Markdown content after the
front matter).

### Live preview

The right pane shows a live preview of the rendered page. Click
"Preview" or save to refresh it.

### Save

The save button writes the file and invalidates the cached `.html`.
If the file was modified by another user since you opened it (mtime
conflict), the save is rejected with an error.

### Collaborative locking

When you open a file for editing, a lock is acquired. Other users
see a "Locked by username" indicator and cannot save. Locks expire
after 5 minutes and are renewed automatically every 60 seconds while
the editor is open. Locks are released when you navigate away.

## Theme manager

At `/editor/themes`:

- View all installed themes with active status
- Activate a theme (clears all cached pages)
- Delete inactive themes
- Rename themes
- Upload new themes as zip files (must contain `view.tt` and
  `theme.json`)

## User management

At `/editor/users`:

- Add new users with username and password
- Change user passwords
- Remove users (also removes from all groups)
- View groups and their members
- Add users to groups

This uses `lazysite-users.pl` in API mode. The users and groups files
at `lazysite/auth/users` and `lazysite/auth/groups` are managed
through this interface.

## Cache manager

At `/editor/cache`:

- View all cached `.html` files with age and source status
- Invalidate individual cached pages
- Clear all cache at once

## Security

### Editor group enforcement

Access to `/editor` and all sub-pages is restricted to authenticated
users in the configured `editor_groups`. Unauthenticated users are
redirected to the login page.

### Blocked paths

The editor API blocks read and write access to sensitive files:

- `lazysite/auth/.secret`
- `lazysite/forms/.secret`
- `lazysite/auth/users`
- `lazysite/auth/groups`
- All `.pl` files

User and group management is handled through the dedicated user
management interface, not through direct file editing.

### Path validation

All file operations validate paths with `realpath()` to ensure they
resolve within the document root. Path traversal attempts are
rejected.

## Installation

The installer copies `lazysite-editor-api.pl` to `cgi-bin/`
alongside `lazysite-processor.pl`. The editor pages in
`starter/editor/` are served as regular lazysite pages.

For manual installation:

```bash
cp lazysite-editor-api.pl /path/to/cgi-bin/
chmod 755 /path/to/cgi-bin/lazysite-editor-api.pl
cp -r starter/editor /path/to/public_html/editor
```
