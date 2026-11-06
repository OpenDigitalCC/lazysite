---
id: SM1335
title: "SM1335: a theme's copies follow its source"
subtitle: "A theme's served copies were written at activation, apply, domain-add and creation only, so an edit to a theme a page pins, or one a secondary domain serves, never reached a visitor. A write to a theme's source, on any surface, now re-mirrors that theme to every host's copy and drops the cached pages that use it; a write to a layout's own files drops the pages that use the layout."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the sites agent (2026-11-04 inbox: an inactive theme's edit never reaches its served copy; the gallery redeploy observations, §1); ruling 81 (Q13) with triage T-32, T-38 and T-39; rulings 111 and 112 (Q43, Q44)"
area: themes
status-note: "SHIPPED (0.16.5) on n747: Manager::Themes::follow_source_write, asked by Files (save, save_binary, delete, move, copy), the multipart upload, WebDAV (PUT, DELETE, MOVE, COPY), create_theme and theme_delete. _mirror_theme_assets refuses a link or a server-run file in assets/. t/unit/manager/430, t/unit/dav/38, t/unit/mcp/73."
---

# What happened

A theme has one source, `lazysite/layouts/<L>/themes/<T>/`, and one served copy
per host that serves `/lazysite-assets/` from its own root: the docroot's, and
one under each content root (SM734). The copies were written when the theme was
activated, applied, bound to a domain or created, and at no other time.

- **An inactive theme's edit** (04/11): lazysite.io's design kit pins pages to
  `layout: default18` / `theme: clarity` (SM120). A fix PUT to the theme source's
  `main.css` answered 204 and the pinned pages kept the old stylesheet. The only
  route to the fix was activating clarity, which changes the live site for
  everyone.
- **A pinned layout's edit** (the gallery redeploy, T-38 §1): every demo
  layout's `layout.tt` was replaced over WebDAV, and each of the 48 pages pinning
  them kept its old render until the page itself was re-PUT.
- **A secondary domain's copy** (05/11, T-39): six photographs uploaded twice,
  once into the docroot's copy and once into the source, and neither reached
  `/sites/harmony2050.org/lazysite-assets/harmony/harmony-r3/`, written once at
  the theme's creation and what that domain serves.

# What shipped

`Manager::Themes::follow_source_write($docroot, @rels)`, one function every
surface asks after a write:

- **A theme's source written** (`lazysite/layouts/<L>/themes/<T>/...`): that
  theme is re-mirrored through `_mirror_theme_assets` to every host's copy, with
  the build-beside-and-switch (SM756), tokens (SM352) and fingerprint (SM830) of
  every other mirror write. A host whose copy is missing - never written, or
  removed - gets it then too (ruling 111). A theme whose source is gone takes
  its copies with it.
- **A layout's own files written** (`layout.tt`, `layout.json`, `strings/`): no
  copy to refresh.
- **Either way**, the cached renders that use it are dropped: the content tree's
  renders beside their sources, and every alias host's slot (SM110). Which pages
  use a theme is read from the renders themselves, which link the theme's copy by
  path (`/lazysite-assets/<L>/<T>/`), so a host's theme, a page's pin and a
  section's (SM812) are found alike (ruling 112).
- **Bounded**: one theme per theme written, however many files the write
  carried (a multipart upload is one call), never every theme of the site.

Asked by `Manager::Files` (save, save_binary, delete, move, copy, so the
manager, the control API and MCP `write_file`, `upload_file`, `move_file`,
`delete_file`, `copy_file`), the manager's multipart upload, WebDAV (PUT, DELETE,
MOVE, COPY), `create_theme` (a made theme has its copies before anything
activates it) and `theme_delete` (which removed the docroot's copy only). A
write's reply carries `mirrors_refreshed` (themes, copies, pages invalidated)
when it refreshed one.

**SM1303's protections on the new path.** A source write now re-mirrors on its
own, so the copy runs far more often than an activation did: `_mirror_theme_assets`
refuses to switch in a copy whose `assets/` holds a symbolic link or a file type
the web server runs, naming the entry, and the copy before it stays served.

# Limits

- A render on a layout that resolved no theme and has no default theme links no
  copy, so a layout write does not find it.
- Each source write re-reads every cached render once to find the ones that use
  the theme; nothing else is rewritten.

# Tests

- t/unit/manager/430: through the choke point, a source save reaches the
  docroot's and the secondary domain's copy (tokens and version with it) and
  leaves another theme's copy alone; the pinning page's render, the secondary
  domain's and an alias host's go, the others stay; a layout.tt save drops every
  render on the layout; upload, copy and delete follow; a removed source takes its
  copies; a link in assets/ is refused and the copy before it stays; a removed
  secondary copy is written again at the next source write.
- t/unit/dav/38: the same over WebDAV, PUT, MOVE and DELETE, and a PUT to a pinned
  layout's template.
- t/unit/mcp/73: `write_file` to the source reaches the secondary copy.

With Files.pm, lazysite-dav.pl and Themes.pm as on main, the copies keep the old
bytes and the renders stay.
