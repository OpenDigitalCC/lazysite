---
id: SM1339
title: "SM1339: a served copy of a theme says so, and is not written"
subtitle: "A write into a host's /lazysite-assets/<layout>/<theme>/ is refused on every surface, for the operator too, naming the source path to write instead; list_files and the manager's listing mark each copy with its source and the hosts that serve it, and whether the theme is active there."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the sites agent (2026-11-05 inbox: a secondary domain's theme mirror is a third copy nobody can see; the served mirror of the active theme accepts a PUT its source refuses); ruling 81 (Q13) with triage T-39; rulings 109 and 110 (Q41, Q42)"
area: themes
status-note: "SHIPPED (PENDING) on n747: served_artifact_refusal answers a served copy (Themes::served_mirror), at the choke point and before WebDAV's writes; action_list marks served_copy. Ruling 109: active_artifact_refusal holds each domain's active theme (domain_active_themes). action_theme_copy takes the theme's path. t/unit/manager/432, t/unit/dav/38, t/unit/mcp/73."
---

# What happened

On theunited.fund (0.16.2) a theme's assets were in three places: the source,
the docroot's copy and harmony2050.org's copy. An agent uploaded six photographs
into the docroot's copy (kept out of the content history, so with no author
line), the manager uploaded them again into the source, and the page on
harmony2050.org, served from its own copy, showed the old ones with a `?v=4`
busting the cache of a file that had not changed. The same agent edited
`main.css` in a copy, which the next activation overwrites. Nothing it could read
said which copy a host serves: `list_files` showed all three alike.

The same day on lazysite.io (0.16.2), a PUT to the active theme's source was
refused 403 and a PUT to its served copy, the one the pages link, answered 204:
the rule that holds the live theme held its source and not the copy rendered.
The caller then followed the copy route, and `theme-copy` refused the theme's
path - the form the refusal and the theme's own `path` field give - wanting the
bare name.

# What shipped

**The write is refused.** `Manager::Common::served_artifact_refusal`, the SM976 F1
rule the choke point and WebDAV already share, also answers a host's served copy
(`Themes::served_mirror`): a path inside `<root>/lazysite-assets/<L>/<T>/` of an
installed theme, the `<L>/` folder or a file in it, or the `lazysite-assets`
folder itself, where `<root>` is the docroot or a content root. Kind
`served-artifact-refused`, naming the source path: `<source>/assets/<file>`, or
`theme.json` for `theme-tokens.css`.

- **Every surface**: the choke point's guard (manager Files, control API, MCP
  `write_file`, `upload_file`, `move_file` either end, `delete_file`, `copy_file`
  destination, mkdir, the multipart upload); WebDAV PUT, MKCOL, DELETE and MOVE
  of the path, and the destination of a COPY or MOVE.
- **The operator included** (ruling 110). The copy is replaced whole at the
  source's next write (SM1335), so the bytes are lost for the operator as for
  anyone, and the source is the one place a change lasts and has history. The
  copy of the active theme is refused as every copy is.
- **Not refused**: reading a copy, copying a file OUT of one, and a copy of a
  theme no longer installed (an orphan; removing it is cleanup). A collection
  DELETE of a domain's whole content root is not refused for the copy inside it.

**The listing says what a copy is.** `Files::action_list` (the manager's Files
page and MCP `list_files`) marks an entry under a `lazysite-assets` folder, and
the folder listed, with `served_copy`: its `level` (theme, layout, root), `layout`,
`theme`, `source` (the path to write instead) and `served_by`, the hosts whose
`/lazysite-assets/` is served from that root, each with `theme_active`. The
primary is named by its `site_url` host.

**A secondary domain's active theme is read-only** (ruling 109), as the
primary's has been since SM749. `active_artifact_refusal` takes the themes each
domain serves as its own (`Common::domain_active_themes`, the effective values
`Domains::domain_usage` reads, the primary left out), asked by the choke point
and by WebDAV's `authorise_layout`: a write into such a theme's source is
refused for every caller, kind `active-artifact-refused`, naming the domain and
the workflow - copy, edit, activate the copy with `host`. A theme only pages pin
stays writable, and its copies follow it (SM1335).

**`theme-copy` takes the theme by its path.** `action_theme_copy` (control API
`theme-copy`, MCP `copy_theme`) accepts `lazysite/layouts/<layout>/themes/<theme>`
as well as the bare name; the layout in the path is the layout, and one given in
`layout` too must be the same.

# Tests

- t/unit/manager/432: at the choke point, save (docroot and secondary copy),
  binary save, delete, mkdir, move into and out of, copy into, the tokens file
  and a file in the layout folder are refused for the operator, naming the
  source; copying out, deleting an orphan copy and writing the source are not.
  The listing marks the copies with source, hosts and `theme_active`. Save,
  upload, delete and copy into the secondary domain's active theme's source are
  refused by the active-theme rule naming the domain; the primary's keeps its
  words. `theme-copy` by path, with slashes, with a matching `layout`; a
  different `layout` and a malformed name refused.
- t/unit/dav/38: PUT (both copies), MKCOL, DELETE (file and whole copy), MOVE out
  and COPY in answer 403 with the source in `X-Lazysite-Deny-Reason`; GET, COPY
  out and an orphan DELETE are allowed. A PUT to the secondary domain's active
  theme's source is 403 naming the domain (ruling 109); with the primary's
  theme active, its source and its served copy are both 403, the copy's reason
  naming the source file (ruling 110, the lazysite.io case).
- t/unit/mcp/73: `list_files` names harmony2050.org and `theme_active`;
  `write_file` and `upload_file` into a copy are refused naming the source.

With Common.pm, Files.pm and lazysite-dav.pl as on main, every write lands and
the listing carries no mark. With the served pairs ignored, the secondary
domain's theme is written; with the path form removed, `theme-copy` refuses the
path.
