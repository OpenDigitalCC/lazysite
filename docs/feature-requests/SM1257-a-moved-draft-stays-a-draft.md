---
id: SM1257
title: "SM1257: a page drafted through its stem stays a draft when it moves"
subtitle: "A rule set on /about is stored as about and holds about.md back. Every mover re-keyed the page's own key only, so a moved page left its draft behind and was published at its new path. The stem rule now moves with the page, on every surface."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "found while measuring SM1242; fix asked by the release manager's coordinator, 2026-10-22"
area: acl
status-note: "SHIPPED (PENDING) on n725: Acl::fold_page_stem folds a page's stem-keyed rule into its own key before a move, in action_move (the manager, MCP move_file and rename_page, the control API move) and WebDAV MOVE, so the existing re-key and store sync carry it. t/unit/manager/160, t/unit/dav/34."
---

# What happened

`set_permissions` on `/about` stores the rule under `about`. That key governs
`about.md` ([[SM268]] H14: a folder's rule covers its landing page). A move re-keyed the
page's own key (`about.md`) and the keys beneath it (CF-2, SM518) and never the stem. So
moving `about.md` to `other.md` left `{draft: true}` at `about`, and `other.md` was
governed by nothing. The engine served it to anyone, and the store sync moved its bytes
back into the document root, where a front end serves them too.

This is security-relevant: the page was held back, and an ordinary move published it.

# The movers

Every path that moves content goes through one of two functions:

- `Lazysite::Manager::Files::action_move`, used by the manager's move, MCP `move_file`,
  MCP `rename_page` (which calls it with `/old.md` and `/new.md`) and the control API
  `move` (lazysite-manager-api.pl);
- WebDAV MOVE (`lazysite-dav.pl`, `do_copy_move`).

A copy makes a new file with a fresh owner-only rule and inherits nothing (SM074), so it
is not affected.

# What shipped

- **`Lazysite::Auth::Acl::fold_page_stem($docroot, $rel)`** is one shared function, also
  used by both deletes ([[SM1242]], [[SM1258]]). For a page (`.md`, `.url`, `.html`) whose
  stem has a rule, and while no folder of that name exists in the docroot or the private
  store, it folds the stem's rule into the page's own key and removes the stem key.
  - Folding keeps the meaning in each mode. The engine asks the page's own key first and
    uses the stem only for a mode the own key does not carry. So the merged record takes
    the stem's value only where the own key has none (no key, an empty list, a false
    flag).
  - While a folder of that name exists, the stem key is the folder's rule and is left
    alone. Rules beneath the stem are never touched.
- **Both movers call it first.** The existing re-key then carries the rule to the new
  path, and the existing store sync puts the bytes where the rule says (the private
  store for a draft).

# Tests

- t/unit/manager/160, new subtest: drafts `/videos/about` through `action_acl_set`, writes
  the page, and moves it with `action_move`. The moved page is still a draft, its bytes
  are not in the document root, and no rule is left at the old stem. With the change
  reverted, all three fail: the page is published and its bytes land in the document
  root.
- t/unit/dav/34, MOVE subtest: the same over WebDAV. With `lazysite-dav.pl` reverted,
  the page is published.
