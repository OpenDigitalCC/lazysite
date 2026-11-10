---
title: "Manager: enabling and configuring"
subtitle: Web-based content manager with file browser, live preview, and theme manager.
tags:
  - configuration
  - development
---

## Manager

The lazysite manager is a built-in web-based content management
interface. It provides a file browser, page editor with live preview,
theme manager, user management, and cache manager.

### Enabling the manager

Add to `lazysite/lazysite.conf`:

    manager: enabled
    manager_path: /manager

### Configuration keys

- `manager: enabled` - enable the manager (default: disabled)
- `manager_path` - URL prefix for manager pages (default: `/manager`)
- manager access itself is granted by groups: any group with the `ui`
  capability (see the Groups page; `setup-sysop` creates one)

### Features

- File browser with create, edit, and delete
- Page editor with front matter form and content textarea
- Live preview pane showing rendered output
- Collaborative file locking (5-minute expiry, auto-renew; shared with
  the WebDAV endpoint so editor and deploy locks respect each other)
- Save with mtime conflict detection
- Theme manager: install, activate, rename, delete themes
- User management: add/remove users, manage groups, per-user UI/WebDAV
  toggles, WebDAV path scope, and one-time credential generation
- Cache manager: view and invalidate cached pages

### Extension system

Components such as the form SMTP handler and link audit tool
integrate with the manager via a self-describing extension interface.
Each script supports a `--describe` flag that returns its
configuration schema as JSON. The manager renders a generic config
form from this schema.

Enable extensions in `lazysite/lazysite.conf`:

    extensions:
      - extensions/audit.pl
      - extensions/form-smtp.pl

Then access via Manager > Extensions.

### Notes

- Manager is disabled by default - must be explicitly enabled
- Access requires authentication and group membership
- Blocked paths prevent editing of auth secrets and scripts
- All file operations validated with realpath within docroot
- Manager pages are regular lazysite `.md` pages
- [Manager guide](/docs/manager) - full setup and usage
