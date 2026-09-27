---
id: SM852
title: "SM852: the bulk and operator-configured write paths do not ask where a gated file lives"
subtitle: "SM836's remainder was a review of every write path that builds its target from the docroot. It found sixty, not twenty-nine. The manager, MCP and DAV paths all resolve correctly; nine others can put a protected section's bytes in the served tree, and every one that creates a directory also pulls later writes under that folder out of the private store. Six are fixed, with two data-loss findings from the same review; three and the two MISS rows are open for 0.13.14."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-11
raised-by: engine (SM836 review)
area: security
status-note: "PARTIAL 2026-09-11. The review is docs/review/2026-09-11-docroot-write-paths.md (sixty rows, each classed). FIXED, each reproduced first unless marked: S1 a file handler's store (t/unit/lib/45); S2 package_apply (t/unit/manager/182); S4 backup restore of a pre-protection archive (t/unit/manager/183); S5 lazysite-bundle-apply, and its dry run (t/tools/03); S7 git-sync's pre-pull snapshot on a migrated site (from reading); S8 pandoc's PDF cache on a migrated site, with the relocation-blind engine writes under SM850; and two data-loss findings from the review's other list - MCP create_page overwriting a protected page it thought absent (t/unit/mcp/26) and the nav-file save deleting every hand-written .html (t/unit/manager/181). CLOSED 2026-09-27, all five remaining rows, and this note had gone stale on three of them. S3 domain_add with seed: FIXED in the N141D era and verified in the code today - it resolves through Private::resolve and ADOPTS a private content root rather than creating a public folder over it, with the reproduction named at the fix. MISS Plugins::_rewrite_store: FIXED and verified at the site, where the confinement check had been refusing its own answer because it admitted two roots and the private store is a third. MISS Domains::domain_remove purge: FIXED, reproduced first, and the `purged` claim is now derived from what actually happened rather than asserted. Those three were done and this note went on listing them as open - the same pattern WORK-PLAN-0150 records. S6 git-sync pull: CLOSED by [[SM881]] on 2026-09-27, with the exposure reproduced against a real remote first and the engine gaining `Acl::gating_for` as the one supported answer. S9 the per-content-root theme mirror: CLOSED by [[SM882]] on 2026-09-27, and NOT as a defect - measured, a theme asset inside a gated content root is governed by the same rule as its pages and refused anonymously, so there was nothing public to move. The relocation was built from the ruling and reverted on the measurement."
---

# What the review found

SM836 built one answer to "which tree owns this write" (`Lazysite::Private::write_root`)
and a lint that forbids hand-written copies of it. Its note said what that could
not see: a write path that resolves NOTHING - builds `"$DOCROOT/$rel"` and writes
- is the SM418 shape, and no source pattern tells a deliberate docroot-only write
from a forgotten one. It counted twenty-nine and left them for review per
handler.

The review is `docs/review/2026-09-11-docroot-write-paths.md`. It found **sixty**
write sites built from the docroot, because it lists each engine-tree build on
its own:

| class | count | meaning |
| --- | --- | --- |
| OK-ENGINE | 41 | engine or infrastructure territory; never content (23 of them ignore a moved engine tree) |
| OK-RESOLVED | 8 | content, resolved through Lazysite::Private - the manager, MCP, DAV, upload and page-cache paths |
| SUSPECT | 9 | can put a protected section's bytes in the served tree |
| MISS | 2 | resolve nothing, but can only miss the private copy, never make a public one |

**The second effect is the reason this matters more than a stray file.**
`resolve_for_write` decides a new path is public as soon as any ancestor exists in
the docroot; a protected folder works because it was MOVED out. So any write that
makes a public directory at a gated path exposes what it writes AND sends every
later write under that folder - including from the correctly resolved manager,
MCP and DAV paths - to the public tree.

# Fixed first

**S1 - a file handler's store in the site's tree** (`Lazysite::Handlers::store_path`).
A handler with `path: members/submissions`, and `members/` protected: the next
anonymous submission made a public `members/` and appended the visitor's data
there. Reproduced by `t/unit/lib/45` before the fix. `store_path` now resolves a
site-tree path through `resolve_for_write`, so the record is written in the
private store with its section; the submissions viewer and the store rewrite call
the same function, so they find it there.

**S7 - git-sync's pre-pull snapshot on a migrated site.** It set the backup
module's engine directory to `"$docroot/lazysite"`, and the snapshot includes the
private store - so on a site whose engine tree moved beside the docroot, every
protected section landed in a tarball inside the served tree. It now asks
`Lazysite::Paths::lazysite_dir`. From reading; the plugin's tests pass.

# Fixed in 0.13.13

**S2 - a site package applied over a protected section** (`package_apply`). Every
file and folder it copies, and the content root itself, resolves through
`resolve_for_write`; a page under a folder protected on this site is written in
the private store and no public folder is made at the gated path. Reproduced by
`t/unit/manager/182`.

**S4 - restoring an archive taken before a folder was protected**
(`action_backup_restore`). The content pass extracts into a staging directory in
the engine tree, with every exclude it had, and each file is placed where
`resolve_for_write` says - a page in a now-protected section comes back in the
store. An empty directory in an archive is no longer recreated on its own.
Reproduced by `t/unit/manager/183`.

**S5 - `tools/lazysite-bundle-apply.pl`.** A content path resolves as every
other write does, a `lazysite/...` path goes to the engine tree wherever it is,
and the dry run says `overwrite, protected` for a protected page instead of
`create`. `t/tools/03`.

**S8 - pandoc's PDF cache on a migrated site** is fixed with the relocation-blind
engine writes under [[SM850]]: the plugin asks where the engine tree is. So are
the review's twenty-three relocation-blind rows, including the two it found
functional - the nav save with no `nav_file`, and the per-host cache unlinks.

**From the review's other list:**

- **MCP `create_page` over a protected page.** It checked only the public tree,
  so "create" overwrote a protected page it thought absent. It asks
  `Lazysite::Private::resolve` now and refuses as `exists`. `t/unit/mcp/26`.
- **Saving the nav file deleted hand-written pages.** The file-save path's sweep
  dropped every `.html` under the docroot, including legacy static pages (SM133)
  and include partials (SM072). It drops only a render - an `.html` with a `.md`
  or `.url` beside it - through the same `render_source_exists` Themes' sweeps
  use. `t/unit/manager/181`.

# Open, each graded from reading

- **S3** `Manager::Domains::domain_add` with `seed` - adding a domain whose content
  root is a protected folder makes an empty public folder and a public seeded
  `index.md`, and the domain then serves the seed.
- **S6** git-sync pull: `git merge` writes into the docroot worktree, so a remote
  commit adding a file under a protected folder makes it public. **Split out as
  [[SM881]]** — the sibling rows' fix does not apply, because the write is
  git's and happens first. **RULED 2026-09-14:** the engine gains an ACL-aware
  resolver and git-sync asks it after a merge.
- **S9** the per-content-root theme mirror recreates a fully gated content root.
  Whether a fully gated content root is a supported configuration is open.
  **Split out as [[SM882]]**, and **RULED 2026-09-14:** it is supported, and it
  must contain nothing public — so this IS a defect, and the assets move out of
  the gated root. Both rulings want the same new resolver; S6 and S9 are now one
  piece of work.
- **MISS** `Plugins::_rewrite_store` (finds no store once its folder is gated -
  fixed by S1, since it reads through `store_path`; to verify) and
  `Domains::domain_remove` purge (removes only the public half and reports it
  purged).

The review also lists six things seen while reading that are not this shape. Two
are fixed above; the rest (a DAV alias key built from the private path, and
others) are in the review record, not filed, until each is reproduced.

# Related

[[SM836]], [[SM418]], [[SM286]], [[SM850]].
