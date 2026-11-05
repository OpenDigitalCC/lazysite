---
id: SM1339
title: "SM1339: a served copy of a theme says so, and is not written"
subtitle: "A write into a host's /lazysite-assets/<layout>/<theme>/ is refused on every surface, for the operator too, naming the source path to write instead; list_files and the manager's listing mark each copy with its source and the hosts that serve it, and whether the theme is active there."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the sites agent (2026-11-05 inbox: a secondary domain's theme mirror is a third copy nobody can see); ruling 81 (Q13) with triage T-39"
area: themes
status-note: "SHIPPED (PENDING) on n747: Manager::Common::served_artifact_refusal answers a served copy (Themes::served_mirror); the choke point's guard asks it of lazysite-assets paths, and WebDAV before PUT, MKCOL, DELETE, MOVE and a COPY's destination. Files::action_list marks served_copy. t/unit/manager/432, t/unit/dav/38, t/unit/mcp/73."
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
- **The operator included.** The copy is replaced whole at the source's next
  write (SM1335), so the bytes are lost for the operator as for anyone, and the
  source is the one place a change lasts and has history.
- **Not refused**: reading a copy, copying a file OUT of one, and a copy of a
  theme no longer installed (an orphan; removing it is cleanup). A collection
  DELETE of a domain's whole content root is not refused for the copy inside it.

**The listing says what a copy is.** `Files::action_list` (the manager's Files
page and MCP `list_files`) marks an entry under a `lazysite-assets` folder, and
the folder listed, with `served_copy`: its `level` (theme, layout, root), `layout`,
`theme`, `source` (the path to write instead) and `served_by`, the hosts whose
`/lazysite-assets/` is served from that root, each with `theme_active`. The
primary is named by its `site_url` host.

# Tests

- t/unit/manager/432: at the choke point, save (docroot and secondary copy),
  binary save, delete, mkdir, move into and out of, copy into, the tokens file
  and a file in the layout folder are refused for the operator, naming the
  source; copying out, deleting an orphan copy and writing the source are not.
  The listing marks the copies with source, hosts and `theme_active`.
- t/unit/dav/38: PUT (both copies), MKCOL, DELETE (file and whole copy), MOVE out
  and COPY in answer 403 with the source in `X-Lazysite-Deny-Reason`; GET, COPY
  out and an orphan DELETE are allowed.
- t/unit/mcp/73: `list_files` names harmony2050.org and `theme_active`;
  `write_file` and `upload_file` into a copy are refused naming the source.

With Common.pm, Files.pm and lazysite-dav.pl as on main, every write lands and
the listing carries no mark.
