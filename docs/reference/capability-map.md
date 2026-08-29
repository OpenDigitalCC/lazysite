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
: The /dav publishing endpoint (files, themes, layouts). Also gates the per-file ACL actions on the control API (acl-get / acl-set / acl-remove) - alongside manage_content since SM431, because a capability that lets you CREATE gated content must let you inspect and set the rule governing it, on the same surface.

api
: The token-authenticated control API (structured actions). Call `action=actions-list` for the actions THIS account may use, with the parameters each takes and where each is read from - the control API's equivalent of MCP's tools/list (SM350). This map says what you may do; that says what you may call.

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
manage_content | Read and write site content (pages, assets). | webdav: write anywhere in the content namespace (within dav_scope); api: aliases-list, git-status, git-history, git-history-summary, git-show, git-restore, lang-status, site-export-primary, regenerate-registries, preview-public, acl-get, acl-set, acl-remove, data-table-acl-get, data-table-acl-set, data-table-acl-remove, brief-read, briefs-list, nav-read, pages; mcp: list_files, read_file, write_file, upload_file, replace_text, copy_file, move_file, delete_file, create_page, delete_page, rename_page, list_pages, read_page, preview_page, page_status, search_files, validate_page, invalidate_cache, regenerate_registries, read_nav, audit_site, create_form, get_permissions, set_permissions, read_brief, list_briefs, list_versions, list_content_history, view_version, restore_version, preview_public_page
manage_nav | Edit site navigation. | webdav: lazysite/nav.conf; api: nav-read, nav-save, pages; mcp: set_nav, read_nav
manage_forms | Wire forms to delivery handlers: which handler a form delivers through, and the handler configuration itself. This grant does NOT read submissions - SM652 narrowed `form-submissions` and `form-list` to `read_submissions` on every channel, so an agent that processes leads needs that capability and this one only changes how forms are wired. SM660: deleting or confirming a submission needs BOTH, because destroying what you may not read is not a coherent grant. A submitted form also raises an sysop notification of its own accord (the manager bell, plus chat where notify-xmpp is configured) naming the form and the time but never the content - so nothing needs to poll to learn that something arrived. See /docs/forms. | webdav: lazysite/forms/<name>.conf (not smtp.conf / handlers.conf); api: form-delete; mcp: list_form_handlers, bind_form, delete_form
manage_themes | Install and activate themes. | webdav: lazysite/layouts/<layout>/themes/<theme>/ (active theme read-only); api: theme-activate, theme-list, themes-for-layout, themes-list-all, artifact-manifest, artifact-validate, preview-grant, theme-delete, layouts-available, layouts-manifest; mcp: list_themes, theme_tokens, activate_theme, create_theme, delete_theme
manage_layouts | Install, author and activate layouts. | webdav: lazysite/layouts/<layout>/ (active layout read-only); api: layout-activate, layout-install, layout-delete, layouts-available, layouts-manifest, artifact-manifest, artifact-validate, preview-grant, theme-list, themes-for-layout, themes-list-all; mcp: activate_layout, install_layout, delete_layout, list_layout_catalogue
manage_domains | Manage the domains this instance serves, and portable site packages. | api: domains-list, domain-add, domain-set, domain-remove, domain-preview, domain-check, site-backup-create, site-backup-download, site-backup-upload, site-backup-apply, site-backup-delete, site-backup-inspect; mcp: list_domains, domain_set, preview_domain, site_backup, site_apply
manage_config | Read and set safe site configuration. | api: config-read, config-set, git-init, bad-url-blocks, bad-url-unblock, git-history-summary
manage_services | Switch the remote surfaces on and off (WebDAV, MCP, OAuth, the control API, the pairing-key exchange). | api: config-set
manage_users | Manage user accounts and group membership. | ui: the manager Users and Groups pages
analytics | Read sanitised, IP-anonymised visitor analytics. | api: analyse_visitors; mcp: analyse_visitors
audit | Read the append-only audit trail. SM618: THE TRAIL IS INSTANCE-WIDE and is NOT scoped by the grant that authorised the read - one instance serves many domains into one trail, so this reaches entries for OTHER sites, and every entry names the actor and carries a RAW source IP, the sysop's own manager, command-line and install sessions among them. Sanctioned instance-wide for the same reason as `purge`. Its sibling `analytics` is the sanitised, anonymised read; this one is neither, and the two sit together deliberately. | api: audit
notifications | See sysop notifications (the manager bell: new form submissions, requests awaiting a response). | ui: the notifications bell + unread badge in the manager header; api: notices
feedback | Submit agent feedback over MCP. Off by default: the operator opts a group in so an agent may write to lazysite/feedback/ and notify the operator. | mcp: submit_feedback
read_submissions | Read form submissions over the API/MCP. A least-privilege, read-only grant for an agent that processes form leads - it does NOT include managing form configs (that is manage_forms). Off by default. | api: form-submissions, form-list; mcp: read_form_submissions, form_list
create_sub_users | Create sub-accounts under your own account. | ui: sub-user creation
delegate_sub_user_creation | Grant sub-accounts the ability to create their own sub-users. | ui: onward delegation of sub-user creation
manage_data | Read and write the site's data tables. | api: data-tables, data-table, data-table-save, data-rows, data-migrate, data-rebuild, data-row-save, data-row-delete, data-export, data-import, data-table-source, data-migrate-plan, data-safety-exports, data-safety-export-read, data-safety-export-restore; mcp: list_data_tables, describe_data_table, save_data_table, read_data_rows, migrate_data_table, rebuild_data_table, save_data_row, delete_data_row, list_data_safety_exports, read_data_safety_export, restore_data_safety_export, read_data_table_source, plan_data_migration
write_data | Write rows in data tables that name your group, and nothing else. | api: data-row-save, data-row-delete; mcp: save_data_row, delete_data_row
manage_briefs | Write authoring briefs - the "why" record kept beside a content file. Reading a brief is also admitted by manage_content; creating and appending to one needs this. DELETING a brief needs `purge`, not this capability, because no copy survives it. Declared by the briefs plugin, so it is grantable only where that plugin is installed. | api: brief-read, brief-append, briefs-migrate, briefs-list; mcp: read_brief, append_brief, list_briefs
housekeeping | Destroy things the engine keeps a copy of. The RECOVERABLE tier of the housekeeping grant: a drop mints a safety export of every row before anything goes, so the object is gone and the data is not. Granting a module capability lets a partner USE that module; this is what lets them destroy inside it, which are two different decisions. | api: data-table-drop; mcp: drop_data_table
purge | Destroy things NO copy survives. The IRREVERSIBLE tier: deleting a safety export is what makes an earlier table drop permanent, and deleting a brief or a backup ends the only record there was. Held separately from `housekeeping` and not implied by it. SM577: A BACKUP STORE IS INSTANCE-WIDE - one instance serves many domains from one backups directory, so this reaches archives of OTHER sites on the same instance and a deletion is NOT scoped by the site whose grant authorised it. | ui: the manager Backups page: backup-delete (instance-wide store); api: brief-delete, data-safety-export-delete, artifact-backups-delete; mcp: delete_brief, delete_data_safety_export
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
