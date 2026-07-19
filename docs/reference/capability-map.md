---
title: "lazysite - capability map"
subtitle: "What a connected partner may do, and how"
brand: plain
standard-margins: true
---

**Generated file - do not edit by hand.** Produced by `tools/gen-capability-docs.pl` from `lib/Lazysite/Capabilities.pm`, the same builder behind the `describe_capabilities` endpoint. An agent with a session should call that endpoint (it also reports what THIS account holds); this doc is the static model for humans and un-authenticated readers.

## Channels

A capability is a channel (where you operate) crossed with an action (what you may do). All four channels are enforced.

ui
: Interactive manager UI over a browser cookie session.

webdav
: The /dav publishing endpoint (files, themes, layouts).

api
: The token-authenticated control API (structured actions).

mcp
: The MCP connector (Claude.ai / ChatGPT / Code tools).

## Capabilities

```datatable
columns: Capability | What it lets you do | Where
widths: 4.6cm | X | 5cm
bold: 1
tone: medium
text: 2
---
manage_content | Read and write site content (pages, assets). | webdav: write anywhere in the content namespace (within dav_scope); api: aliases-list, git-status, git-history, git-show, git-restore; mcp: list_files, read_file, write_file, replace_text, copy_file, move_file, delete_file, create_page, delete_page, rename_page, list_pages, read_page, preview_page, page_status, search_files, validate_page, invalidate_cache, read_nav, audit_site, create_form, get_permissions, set_permissions, list_versions, view_version, restore_version
manage_nav | Edit site navigation. | webdav: lazysite/nav.conf; api: nav-read, nav-save, pages; mcp: set_nav
manage_forms | Wire forms to delivery handlers. | webdav: lazysite/forms/<name>.conf (not smtp.conf / handlers.conf); mcp: list_form_handlers, bind_form
manage_themes | Install and activate themes. | webdav: lazysite/layouts/<layout>/themes/<theme>/ (active theme read-only); api: theme-activate, theme-list, themes-for-layout, themes-list-all; mcp: list_themes, activate_theme
manage_layouts | Install, author and activate layouts. | webdav: lazysite/layouts/<layout>/ (active layout read-only); api: layout-activate, layout-install, layout-delete, layouts-available, layouts-manifest; mcp: activate_layout, install_layout, delete_layout, list_layout_catalogue
manage_domains | Manage the domains this instance serves, and portable site packages. | api: domains-list, domain-add, domain-set, domain-remove, domain-preview, domain-check, site-backup-create, site-backup-upload, site-backup-apply; mcp: site_backup, site_apply
manage_config | Read and set safe site configuration. | webdav: lazysite/nav.conf, lazysite/forms/<name>.conf; api: config-read, config-set, git-init
manage_users | Manage user accounts and group membership. | ui: the manager Users and Groups pages
analytics | Read sanitised, IP-anonymised visitor analytics. | api: analyse_visitors; mcp: analyse_visitors
audit | Read the append-only audit trail. | api: audit
notifications | See operator notifications (the manager bell: new form submissions, requests awaiting a response). | ui: the notifications bell + unread badge in the manager header
feedback | Submit agent feedback over MCP. Off by default: the operator opts a group in so an agent may write to lazysite/feedback/ and notify the operator. | mcp: submit_feedback
create_sub_users | Create sub-accounts under your own account. | ui: sub-user creation
delegate_sub_user_creation | Grant sub-accounts the ability to create their own sub-users. | ui: onward delegation of sub-user creation
```

## Engine-owned paths (do not write)

These are protected - the WebDAV endpoint refuses them. Use the API or MCP tools rather than trying to edit the engine:

- lazysite/auth/**  (credentials, tokens, TOTP seeds, HMAC secret)
- lazysite/cache/** (generated HTML cache)
- lazysite/forms/smtp.conf, lazysite/forms/handlers.conf (delivery secrets)
- lazysite/manager/** (manager UI internals)
- cgi-bin/**, *.pl   (the engine scripts)

## Getting started

See [the quickstarts](quickstarts) for copy-pasteable recipes, or call the `describe_capabilities` MCP tool / `describe-capabilities` control-API action to get this map plus your own grant in one response.
