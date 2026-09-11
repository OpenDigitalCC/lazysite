---
id: SM852
title: "SM852: the bulk and operator-configured write paths do not ask where a gated file lives"
subtitle: "SM836's remainder was a review of every write path that builds its target from the docroot. It found sixty, not twenty-nine. The manager, MCP and DAV paths all resolve correctly; nine others can put a protected section's bytes in the served tree, and every one that creates a directory also pulls later writes under that folder out of the private store. Two are fixed here; seven are open."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-11
raised-by: engine (SM836 review)
area: security
status-note: "PARTIAL 2026-09-11. The review is docs/review/2026-09-11-docroot-write-paths.md (sixty rows, each classed). FIXED: S1 - a file handler's store in the site's tree now resolves through Lazysite::Private::resolve_for_write, so a submission to a store inside a protected section is written in the private store and no public folder is made; reproduced first (t/unit/lib/45 failed before the fix), and the readers use the same resolver. S7 - git-sync's pre-pull snapshot asks Lazysite::Paths::lazysite_dir where the engine tree is, instead of writing a tarball that includes the private store into <docroot>/lazysite/backups on a migrated site; from reading, with the plugin's tests passing. OPEN: S2 package_apply, S3 domain_add with seed, S4 backup restore of a pre-protection archive, S5 lazysite-bundle-apply, S6 git-sync pull into a gated folder, S8 pandoc's PDF cache on a migrated site, S9 the per-content-root theme mirror (edge; whether a fully gated content root is supported is itself open); the two MISS rows; and the relocation-blind engine writes, which belong with SM850. All open items are graded FROM READING, not reproduced."
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

# Fixed here

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

# Open, each graded from reading

- **S2** `Manager::SitePackage::package_apply` copies a package's content into
  `"$DOCROOT/<content_root>"`; a package carrying files under a protected folder
  writes public copies beside the private ones.
- **S3** `Manager::Domains::domain_add` with `seed` - adding a domain whose content
  root is a protected folder makes an empty public folder and a public seeded
  `index.md`, and the domain then serves the seed.
- **S4** `Manager::Backups::action_backup_restore` extracts content members with
  `tar -C $DOCROOT`; an archive taken before a folder was protected restores it
  public, beside the private copy, and nothing re-syncs the store.
- **S5** `tools/lazysite-bundle-apply.pl` writes each bundle file to
  `"$docroot/$p"` with no store check; its dry run reports `create` for a page
  that exists privately.
- **S6** git-sync pull: `git merge` writes into the docroot worktree, so a remote
  commit adding a file under a protected folder makes it public.
- **S8** `plugins/pandoc.pl` caches a PDF - which may include a gated part - at
  `"$docroot/lazysite/cache/pdf"`, inside the served tree on a migrated site. The
  plugin loads no Lazysite module, so the fix is not a one-line change.
- **S9** the per-content-root theme mirror recreates a fully gated content root.
  Whether a fully gated content root is a supported configuration is open.
- **MISS** `Plugins::_rewrite_store` (finds no store once its folder is gated -
  fixed by S1, since it reads through `store_path`; to verify) and
  `Domains::domain_remove` purge (removes only the public half and reports it
  purged).
- **Relocation-blind engine writes** - twenty-three rows building
  `<docroot>/lazysite/...` - belong with [[SM850]]. Two are functional on a
  migrated site: a nav save with no `nav_file` writes where the processor does not
  read, and the per-host cache unlinks miss the copies the processor wrote.

The review also lists six things seen while reading that are not this shape
(an MCP `create_page` that overwrites a gated page it thinks absent, a DAV alias
key built from the private path, and others). They are in the review record, not
filed, until each is reproduced.

# Related

[[SM836]], [[SM418]], [[SM286]], [[SM850]].
