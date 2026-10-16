---
id: SM989
title: "SM989: a restored site package wrote its rows as nobody"
subtitle: "Lint 137 read only the top-level scripts; widened to the modules the row writers moved into, it found Manager::SitePackage inserting every restored row with no actor."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the developer agent, widening lint 137 for WORK-PLAN-0154 P21
area: data
status-note: "SHIPPED (0.15.5): lint 137 also holds every insert_row/update_row/import_rows call in lib/, tools/ and plugins/ to `actor =>`; package_apply restores rows as the account applying it, as data-import does."
---

# What was wrong

Lint 137 (SM860) checks that a surface calling the row writers sets the actor
it writes rows as. It read only the top-level `*.pl` files, by design, because
that is where a verified identity lives. Since SM944 split the scripts, rows
are also written from modules that call `Lazysite::Data::Tables` directly:
Manager::Connectors (an answer table), Handlers (a form's table target),
Manager::Data (save, import) and Manager::SitePackage (restore). The lint saw
none of them.

Widened, it found one: `package_apply` (lib/Lazysite/Manager/SitePackage.pm)
inserted every restored row with no `actor`, so on a table with timestamps
`created_by` and `updated_by` were stamped empty - "written anonymously" -
whoever applied the package, although every surface that applies one sets
`$Lazysite::Manager::SitePackage::auth_user`.

# The fix

- `package_apply` passes `actor => $auth_user`: restored rows record the
  account that applied the package, as Manager::Data's import records the
  importer.
- Lint 137 gains a second check: every call to a stamping writer -
  `insert_row`, `update_row`, `import_rows` - in any `.pl` at the root, in
  tools/ or plugins/, or any `.pm` under lib/ (the writers' own module aside)
  passes `actor =>`, even when the value may be empty (a form submitted by
  nobody signed in). `delete_row` stamps nothing and is not asked. Paths are
  judged below the root, so a checkout under tmp/ reads the same files; it
  must find at least six call sites, so it cannot pass with nothing to check.

# Open

Whether a restore should keep the authorship the rows had at export instead
is a ruling; the export does not carry it today, so the restorer is the only
identity there is.

# Tests

t/lint/137. Sabotage: SitePackage.pm put back fails it; the actor removed
from Manager::Connectors' call fails it, naming the file and line.
