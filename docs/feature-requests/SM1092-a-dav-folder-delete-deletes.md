---
id: SM1092
title: "SM1092: a WebDAV folder DELETE deletes the folder, or says why it did not"
subtitle: "A path held in both trees is deleted from both, and a member the caller may not write refuses the whole DELETE with nothing removed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.5 test plan, "Found outside the rows" (release manager ruled T3 for fixing, 2026-10-16)
area: dav
status-note: "SHIPPED on n603: lazysite-dav.pl do_delete, _delete_twin, _delete_member_refusal; t/unit/dav/32."
---

# What happened

The 0.15.5 test plan reported, under "Found outside the rows":

> WebDAV DELETE of a folder answered 204 and left files. /zz-0155-f7/ held two
> pages whose rule had just been removed (content moved back from the private
> store); DELETE of the folder returned 204, and the folder and both .md files
> were still there; deleting the files then the folder worked.

A rule on a page moves the page into the private store, and the move creates
the page's folder there too (SM286). Removing the rule moves the page back and
leaves that folder behind, empty. After that the folder exists in both trees.
`resolve_under_docroot` asks `Private::write_root`, which prefers the private
copy. DELETE then removed the empty private twin, saw its target gone and
answered 204, and the public folder and its pages were untouched. Deleting
the files first worked because the second folder DELETE found no twin left.

The same handler removed every member of a folder after checking only the
folder: a page inside it whose rule refused the caller write was deleted with
the rest.

# What shipped

- **Every copy is a target.** `do_delete` deletes the path in the tree the
  resolver chose and, through `_delete_twin`, its copy in the other tree,
  each one confined the same way. It answers 204 only once neither tree
  holds the path. The engine tree and the theme-asset mirror have one home
  and no twin.
- **Pages in either tree are housekept.** The aliases, registries, rules and
  brief entries are cleared for pages found in both trees. After a partial
  delete (SM939, 507), a page still in the private store does not count as
  gone.
- **Members are asked.** Before anything is removed, every path beneath the
  folder, in both trees, goes through `authorise`, the same check `main`
  makes of the request path: scope, blocklist and per-file rule. If one
  refuses, the DELETE answers 403 and removes nothing. The body and
  `X-Lazysite-Deny-Reason` name the member and the reason, and the audit
  trail records `member-refused`. RFC 4918 9.6.1 also allows deleting what
  is permitted and answering 207. That was not chosen, because it leaves a
  half-deleted folder nobody asked for. The safe choice, refusing the whole
  DELETE, is the one implemented.

`t/unit/dav/32` reproduces the field shape: rules set on two pages, then
removed, then a folder DELETE. It also covers a folder whose private twin
holds a gated page, and a folder with a member owned by someone else.
