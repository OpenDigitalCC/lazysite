---
title: "SM850: on a site whose engine tree was moved out of the docroot, the data store is looked for where it used to be"
subtitle: "Found building SM842: the form handler read its forms from inside the docroot on a migrated site; the data tables do the same, and a lint claims they cannot"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11 (0.13.13). Every hand-built <docroot>/lazysite path in the shipped Perl - 110 places across 38 files, not the two named here - asks Lazysite::Paths, and t/lint/37 now reads every file instead of nine. A configured `lazysite/...` path (nav_file) and the file surfaces' `lazysite/...` carve-outs (validate_path, WebDAV) resolve to the engine tree too. Each fixed behaviour was reproduced on a migrated fixture before the fix: t/unit/data/62, t/unit/manager/184 and 185, t/unit/dav/26. Not done here, from reading only: the front-end ACL guard in the shipped vhost templates (below)."
---

# What was found

SM293 lets a site move its engine tree out of the document root: `lazysite/`
becomes `<docroot>-lazysite/`, beside it, and `Lazysite::Paths::lazysite_dir`
answers with whichever exists. `t/lint/37` states the rule it holds: the
processor carries its own copy of that resolution, and *"everything else calls
Lazysite::Paths::lazysite_dir"*.

Building SM842 found two places that do not:

- **`plugins/form-handler.pl`** built `$DOCROOT/lazysite` by hand. On a migrated
  site it looked for `lazysite/forms/<form>.conf` inside the docroot, found
  nothing, and refused every submission as "not configured" - while the
  processor, which does resolve the tree, wrote the form secret to the new
  place. **Fixed in SM842**: the handler loads the module tree now and asks
  `lazysite_dir` like everything else.
- **The data store**: `Lazysite::Data::Tables::descriptor_dir` is
  `"$docroot/lazysite/db/tables"` and `Lazysite::Data::Connect` opens
  `"$docroot/lazysite/db/data.sqlite"`. On a migrated site every declared
  table is looked for in a directory the migration removed.

Neither is caught by `t/lint/37`, which drives the processor's copy against the
module and does not look for a hand-built `$docroot/lazysite` anywhere else.

# What was done (0.13.13)

**It was not two places.** A survey for any interpolated `<something>/lazysite`
found 110 in 38 files: the data store, the scheduler and supervisor, briefs,
notifications, aliases, the bad-URL cache, git, i18n, the per-host render cache,
the stats, pandoc, audit, git-sync and form plugins, and the CLI. The lint had
missed them because it read nine named files for two spellings (`$docroot`,
`$DOCROOT`); the others were `$root`, `$d`, `$_[0]` and `_docroot(...)`.

- Every one asks `Lazysite::Paths::lazysite_dir`. The standalone plugins (audit,
  form-smtp, payment-demo, stats, pandoc) gained the house bootstrap and a lazy
  `_lz`; the CLI loads the resolver for the verbs that read a site's tree.
- `Lazysite::Paths::internal_lazysite_dir` names the in-docroot place for the few
  callers whose question is about that place: a render-cache sweep that must not
  descend into a stray tree (it also stopped matching `lazysite-assets/`), and
  the migration reporting what it would move.
- `t/lint/37` reads every `.pm`/`.pl` that ships, for the general shape, with five
  named exceptions and a check that each is still needed: the two module-free
  copies of the resolver (processor, installer), nginx configuration text, the
  core-only Hestia root tool, and the bench fixture builder.
- **Configured paths.** `nav_file: lazysite/nav.conf` and a domain's
  `alias.<host>.nav_file` were joined to the docroot by the manager and, when set,
  by the processor. `Lazysite::Paths::site_path` says a leading `lazysite/` means
  the engine tree; the processor's `_site_path` is its module-free copy, and
  `t/lint/37` drives the two against each other. A nav save on a migrated site
  made a stray engine tree inside the served tree and the live nav did not change
  (t/unit/manager/184).
- **The file surfaces.** `validate_path` - the file editor, the control API and
  MCP's `write_file` - joined `lazysite/nav.conf` and the layout and theme
  carve-outs to the docroot: a save made a stray tree and answered `created`, a
  read said not found (t/unit/manager/185). WebDAV's `resolve_under_docroot` did
  the same and refused the write with 409 (t/unit/dav/26). Both root a
  `lazysite/...` rel at the engine tree now, confined to it as strictly as the
  docroot branch is to the docroot.
- The migrated-site fixture the filing asked for: a declared table, a `db:`
  binding and a form into the table through the real handler (t/unit/data/62).

# Not done here

**The front-end ACL guard in the shipped vhost templates** - graded from reading,
not reproduced. The Hestia Apache and proxy templates and the nginx snippet route
an existing static file through the engine when `<docroot>/lazysite/auth/acls.json`
exists (`%{DOCUMENT_ROOT}/lazysite/auth/acls.json`, `$document_root/lazysite/...`).
On a migrated site that file is beside the docroot, so the guard never fires. The
private store is the protection - a protected file is moved out of the served
tree, so the front end has nothing to serve - which makes this guard defence in
depth rather than the gate; it goes inert exactly where the engine tree has
moved. The fix is an `[OR]` for `%{DOCUMENT_ROOT}-lazysite/auth/acls.json` (and
the nginx equivalent), and wants proving against a real Apache and nginx, which
is why it is not in this change.

# What is not known

Whether any site has been migrated. `lazysite migrate-engine-tree --all` exists
and nothing here records it being run. If none has, all of the above was latent.

# Related

[[SM293]] (the migration), [[SM842]] (where it was found; the form handler half
is fixed there), [[SM852]] (the review that listed the relocation-blind writes,
including the nav save).
