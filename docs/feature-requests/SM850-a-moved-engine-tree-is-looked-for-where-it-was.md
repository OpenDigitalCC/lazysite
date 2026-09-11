---
title: "SM850: on a site whose engine tree was moved out of the docroot, the data store is looked for where it used to be"
subtitle: "Found building SM842: the form handler read its forms from inside the docroot on a migrated site; the data tables do the same, and a lint claims they cannot"
brand: plain
standard-margins: true
status: candidate
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
  table is looked for in a directory the migration removed. **Not fixed**: it
  touches every data path, and it wants its own proof on a migrated fixture.

Neither is caught by `t/lint/37`, which drives the processor's copy against the
module and does not look for a hand-built `$docroot/lazysite` anywhere else.

# What is not known

Whether any site has been migrated. `lazysite migrate-engine-tree --all` exists
and nothing here records it being run. If none has, this is latent; if one has,
its data tables have been reading as undeclared since.

# Proposed

1. `Data::Tables` and `Data::Connect` resolve through `Lazysite::Paths`.
2. `t/lint/37` grows the question it implies: no `$docroot/lazysite` or
   `$DOCROOT/lazysite` string built by hand outside `Lazysite::Paths` and the
   processor's pinned copy (with the installer's own copy, which must not load
   the lib, named as the exception it already is).
3. A migrated-site fixture that renders a `db:` page and takes a form into a
   table - the two paths that were wrong.

# Related

[[SM293]] (the migration), [[SM842]] (where it was found; the form handler half
is fixed there).
