---
title: "lazysite - control API actions"
subtitle: "Every action the control API dispatches, what it requires, and what it takes"
brand: plain
standard-margins: true
---

**Generated file - do not edit by hand.** Produced by `tools/gen-capability-docs.pl actions` from `lib/Lazysite/ControlApi/Actions.pm`, which `t/lint/58-action-reference-matches-the-dispatch.t` re-extracts from the dispatcher in `lazysite-manager-api.pl` and fails on any difference.

An authenticated caller should ask `action=actions-list` instead: it returns this same table already narrowed to what that account may call. This page is the static model, for humans and for readers with no credential.

## Reading the capability column

any of the listed
: hold any ONE of them and the action is available.

any authenticated
: introspection - no particular grant needed.

cookie only
: **not reachable with a token.** The manager UI calls it and an agent cannot. This is the state a caller can discover no other way, and the reason a refusal here is a boundary rather than a missing grant.

## Reading the parameters column

`query`
: read from the query string.

`body`
: read from the JSON request body.

`query_or_body`
: the action accepts either. Several read the query string and fall back to the body, so a caller sending only one of them still works.

A blank cell means the dispatcher reads no parameter of its own for that action. Where a branch hands the request to a helper that reads one internally, neither the table nor the lint can see it - so this page is accurate about what it lists rather than exhaustive per action.

## The actions

```datatable
columns: Action | Requires | Parameters
widths: 5.4cm | 4.8cm | X
bold: 1
tone: medium
---
`acl-get` | webdav | path (query)
`acl-remove` | webdav | path (query)
`acl-set` | webdav | path (query_or_body), read (body), write (body), owner (body), draft (body)
`actions-list` | any authenticated |  
`aliases-list` | manage_content | host (query), path (query)
`analyse_visitors` | analytics | window (query), day (query), month (query), index (query), trails (query)
`artifact-backups-delete` | manage_layouts / manage_themes | path (query)
`artifact-manifest` | manage_themes / manage_layouts |  
`artifact-validate` | manage_themes / manage_layouts |  
`audit` | audit | user (query), target (query), start (query), end (query), page (query), per_page (query)
`backup-create` | cookie only | scope (query)
`backup-delete` | cookie only | name (query_or_body)
`backup-download` | cookie only | name (query)
`backup-list` | cookie only |  
`backup-restore` | cookie only | name (query)
`bad-url-blocks` | manage_config |  
`bad-url-unblock` | manage_config | ip (query)
`cache-invalidate` | cookie only | path (query), host (query)
`cache-list` | cookie only |  
`channel-services` | cookie only |  
`config-read` | manage_config |  
`config-set` | manage_config | key (query_or_body), value (query_or_body)
`copy` | cookie only | path (query), to (query)
`csrf-token` | cookie only |  
`data-export` | manage_data | table (query), format (query)
`data-migrate` | manage_data | table (query)
`data-rebuild` | manage_data | table (query_or_body), confirm_lost (body)
`data-row-delete` | manage_data | table (query_or_body), key (query_or_body)
`data-row-save` | manage_data | table (query_or_body), key (query_or_body), row (body)
`data-rows` | manage_data | table (query), order_by (query), order (query), limit (query), offset (query)
`data-table` | manage_data | table (query)
`data-table-save` | manage_data | table (query_or_body), descriptor (body)
`data-tables` | manage_data |  
`delete` | cookie only | path (query)
`describe-capabilities` | any authenticated |  
`domain-add` | manage_domains | host (body), content_root (body), site_url (body), site_name (body), theme (body), layout (body), nav_file (body), search_default (body), lang (body), lang_group (body), seed (body)
`domain-check` | manage_domains | host (query)
`domain-preview` | manage_domains | host (query)
`domain-remove` | manage_domains | host (body), purge (body)
`domain-set` | manage_domains | host (body), key (body), value (body)
`domains-list` | manage_domains |  
`file-download` | cookie only | path (query)
`file-upload` | cookie only | path (query)
`file-zip-download` | cookie only |  
`form-list` | manage_forms / read_submissions |  
`form-submission-confirm` | cookie only | file (query_or_body), id (body)
`form-submission-delete` | cookie only | file (query_or_body), id (body)
`form-submissions` | manage_forms / read_submissions | file (query)
`form-submissions-delete-bulk` | cookie only | file (query_or_body), ids (body)
`form-targets-read` | cookie only | form (query)
`form-targets-save` | cookie only | form (query), targets (body)
`git-history` | manage_content | path (query), limit (query)
`git-history-summary` | manage_content |  
`git-init` | manage_config |  
`git-restore` | manage_content | path (query), sha (query)
`git-show` | manage_content | path (query), sha (query)
`git-status` | manage_content |  
`handler-delete` | cookie only | id (body)
`handler-list` | cookie only |  
`handler-save` | cookie only |  
`key-revoke` | cookie only |  
`keys-list` | cookie only |  
`lang-status` | manage_content | group (query)
`layout-activate` | manage_layouts | path (query), layout (query)
`layout-delete` | manage_layouts | path (query)
`layout-install` | manage_layouts |  
`layouts-available` | manage_themes / manage_layouts |  
`layouts-install` | cookie only |  
`layouts-manifest` | manage_themes / manage_layouts |  
`layouts-release-contents` | cookie only | tag (query)
`layouts-releases` | cookie only |  
`layouts-repo-get` | cookie only |  
`layouts-repo-set` | cookie only | value (body)
`list` | cookie only | path (query)
`lock` | cookie only | path (query)
`migrate-to-local` | cookie only | path (query)
`mkdir` | cookie only | path (query)
`move` | cookie only | path (query), to (query)
`nav-read` | manage_nav | host (query)
`nav-save` | manage_nav | items (body), host (query_or_body)
`notices` | notifications |  
`notices-seen` | cookie only |  
`pages` | manage_nav |  
`plugin-action` | cookie only | plugin (query), script (body), action_id (body), params (body)
`plugin-disable` | cookie only | script (body)
`plugin-enable` | cookie only | script (body)
`plugin-list` | cookie only |  
`plugin-read` | cookie only | plugin (query), script (body)
`plugin-save` | cookie only | plugin (query), script (body), values (body)
`preview` | cookie only | path (query)
`preview-clear` | cookie only |  
`preview-grant` | manage_themes / manage_layouts |  
`preview-public` | manage_content | path (query)
`principals` | cookie only |  
`protected-sections` | cookie only | path (query)
`read` | cookie only | path (query)
`recent-changes` | cookie only | window (query)
`regenerate-registries` | manage_content |  
`renew-lock` | cookie only | path (query)
`rotate-auth-secret` | cookie only |  
`save` | cookie only | path (query), content (body), mtime (body)
`session-revoke` | cookie only |  
`sessions-list` | cookie only |  
`site-backup-apply` | manage_domains |  
`site-backup-create` | manage_domains | host (query_or_body), data_tables (body)
`site-backup-delete` | manage_domains | name (query_or_body)
`site-backup-download` | manage_domains | name (query_or_body)
`site-backup-inspect` | manage_domains | name (query), host (query)
`site-backup-upload` | manage_domains |  
`site-export-primary` | manage_content | data_tables (body)
`theme-activate` | manage_themes | path (query), theme (query)
`theme-delete` | manage_themes | path (query)
`theme-list` | manage_themes / manage_layouts |  
`theme-rename` | cookie only | path (query), new_name (body)
`theme-upload` | cookie only | filename (query)
`themes-for-layout` | manage_themes / manage_layouts | layout (query)
`themes-list-all` | manage_themes / manage_layouts |  
`unlock` | cookie only | path (query)
`user-revoke` | cookie only |  
`users` | cookie only |  
`version` | cookie only |  
`whoami` | any authenticated |  
---
```
