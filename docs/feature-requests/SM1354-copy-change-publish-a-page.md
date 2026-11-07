---
id: SM1354
title: "SM1354: copy a page, change the copy, publish it over the original"
subtitle: "A preview should be a simple workflow: the page is copied, the copy is changed (by a person, a wizard or an agent), the owner looks at it, and publishing replaces the original. Content history gives the rollback."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: content
status-note: "SHIPPED (PENDING, 0.16.8) on n772 with ruling 155: page-copy, page-copy-publish, page-copy-discard, page-copies; copy_page, publish_copy, discard_copy; preview_page renders a copy; the editor's Copy, Publish, Discard and Undo; publish_copies, off by default. t/unit/mcp/76, 77; t/unit/manager/490."
---

# Proposed

- **Copy:** `page-copy <page>` makes a private copy, readable only by people who may edit the page. One open copy per page. The copy renders exactly as the page would, with its layout, theme and data.
- **Change:** the copy is edited like any page (manager, MCP, wizard, agent).
- **Publish:** it replaces the original as one recorded change, with who published it and where the change came from (person, wizard, photo update, agent). A copy is not published if the original changed after it was taken; the owner is shown both.
- **Discard:** removes the copy, leaving no trace in the page's history.
- **Roll back:** the previous version of the page is restored from content history. It is offered as "Undo" right after a publish.
- **Connectors:** `copy_page`, `publish_copy` and `discard_copy` tools. `preview_page` renders a copy. An agent proposes by copying and changing; publishing needs a person unless the site allows that agent to publish.

# Questions for ruling

1. Should an agent ever be allowed to publish a copy itself, by a per-site grant?

Ruled (155): an agent may publish its own copy over the original only by a per-site
grant, off by default; the publish is recorded naming the agent and Undo is offered as
for a person.

# Shipped

## Where the copy lives, and why there

A page's copy is a page source at `lazysite/copies/pages/<page path>`:
`lazysite/copies/pages/about.md` is the copy of `about.md`. The path rule is
`Lazysite::PageCopy` (pure, no I/O); the records and verbs are
`Lazysite::Manager::PageCopy`. The records (who took the copy, when, the page's version
at that moment, who changed it since) are `lazysite/copies/records.json`.

The engine tree is never served, which is what keeps a copy out of every public surface:

- **the public render**: the processor renders pages from the content tree, and a copy
  has no URL; it is rendered only as a draft of its page (SM1030's draft path), which
  writes nothing.
- **the navigation**: a nav names URLs, and a copy has none.
- **search and sitemaps**: both walk the content tree and skip `lazysite/`.
- **the cache**: a cache entry is written for a rendered URL, and a draft render writes
  none. A save of a copy drops no cache and indexes no alias.
- **content history**: `lazysite/copies/` is in `Lazysite::Git`'s exclude list, and a
  save of a copy records no commit, so a discarded copy leaves nothing behind and a
  published one is recorded once, as its page's change.

A path was kept, rather than a store, so that a copy is edited like any page: `read_file`,
`write_file`, `replace_text`, `validate_page` and the manager's editor all take a path.
The path's rules follow the page, never the folder:

- **who may read or write it**: whoever may write the page. `Auth::Acl`'s
  `_acl_allows` and `_acl_denied` map a copy path to its page in write mode, so a
  reader of a page who may not change it does not see a change being prepared.
- **which scope it is in**: the page's. The MCP and control-API scope checks ask
  `scope_path` before they skip `lazysite/`, so a grant confined to one folder does not
  reach another folder's copies.
- **what capability reaches it**: `manage_content`, through `Manager::Common`'s
  carve-out (`carveout_requirement`).
- **what a save is held to**: what a save of the text at the page would be held to
  (`_content_write_refusal` asked of the page's path).

The folder takes an open copy's text and nothing else: an upload (single or multipart),
a delete, a folder, a move into or out of it and a file copy into it are each refused
by name (`Manager::Files::_copy_path_refusal`, `Manager::Upload`), and a save there with
no open copy is refused as `no-copy`. A copy carried out by `move_file` would be a
publish that skipped the publish's gate and stale check. WebDAV denies the whole
`lazysite/` tree outside the layouts carve-out, copies included.

## The doors

| Door | Copy | Publish | Discard | List |
|---|---|---|---|---|
| Control API | `page-copy` | `page-copy-publish` | `page-copy-discard` | `page-copies` |
| MCP | `copy_page` | `publish_copy` | `discard_copy` | - |
| Manager editor | Copy | Publish (then Undo) | Discard | - |

`preview_page` with a copy's path, and the manager's preview, render the copy's saved
text at the page's path, with the page's layout, theme, navigation and data, as a public
visitor; nothing is written.

## Publishing, staleness and Undo

A publish is `Manager::Files::action_save` of the copy's text at the page's path, so
every rule a save applies applies to a publish, with one content-history commit whose
message names the publisher, the door (`person` or `agent`, and `via <word>` when the
caller says what made the change, such as `wizard`) and who prepared the copy:
`publish about.md from its copy - by editor (person); prepared by bot, editor`.

The copy records the page's version when it was taken: the digest of its bytes, and its
content-history version when history is kept. A publish whose page digest differs is
refused as `stale-copy`, nothing written, and the answer carries both versions
(`taken_from`, `current`). A copy published unchanged records nothing and says so.

A publish answers `undo` with the version before it (`restore_version` / `git-restore`);
the editor offers it as Undo straight after. Where content history is not kept, the
answer says there is no version to undo to.

## Gates

- Taking, changing, listing and discarding a copy: `manage_content` and the page's own
  write rule.
- Publishing in the manager (a person, cookie session): `manage_content`, as a save.
- Publishing over MCP or the control API: `publish_copies` and `manage_content`.
  `publish_copies` is a new capability in the Content section, off by default: no seed,
  top-up or shipped role grants it (`Auth::Settings::@OFF_BY_DEFAULT`, honoured by the
  users tool's seed, top-up and migration and by `lazysite check`), and a manager group
  is offered it to grant. Without `manage_content` beside it the publish is refused,
  naming it.

## Tests

t/unit/mcp/76 (copy, change, preview, the publish_copies gate, the stale refusal,
discard leaves no history, publish as one recorded change naming the publisher and
`via`, Undo, the copies folder's refusals, the page's write rule), t/unit/mcp/77 (a copy
is in its page's scope), t/unit/manager/490 (the manager and control-API doors, a person
publishes on manage_content, a token needs publish_copies and manage_content, a manager
group is seeded without publish_copies and offered it, a multipart upload into the copies
folder is refused).
