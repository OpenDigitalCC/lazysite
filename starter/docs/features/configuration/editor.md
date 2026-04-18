---
title: Editor
subtitle: Web-based content editor with file browser, live preview, and theme manager.
tags:
  - configuration
  - development
---

## Editor

The lazysite editor is a built-in web-based content management
interface. It provides a file browser, page editor with live preview,
theme manager, user management, and cache manager.

### Enabling the editor

Add to `lazysite/lazysite.conf`:

    editor: enabled
    editor_path: /editor
    editor_groups: lazysite-admins

### Configuration keys

- `editor: enabled` - enable the editor (default: disabled)
- `editor_path` - URL prefix for editor pages (default: `/editor`)
- `editor_groups` - comma-separated groups that can access the editor

### Features

- File browser with create, edit, and delete
- Page editor with front matter form and content textarea
- Live preview pane showing rendered output
- Collaborative file locking (5-minute expiry, auto-renew)
- Save with mtime conflict detection
- Theme manager: install, activate, rename, delete themes
- User management: add/remove users, manage groups
- Cache manager: view and invalidate cached pages

### Notes

- Editor is disabled by default - must be explicitly enabled
- Access requires authentication and group membership
- Blocked paths prevent editing of auth secrets and scripts
- All file operations validated with realpath within docroot
- Editor pages are regular lazysite `.md` pages
- [Editor guide](/docs/editor) - full setup and usage
