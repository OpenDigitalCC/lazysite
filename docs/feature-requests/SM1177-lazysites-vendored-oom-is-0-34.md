---
id: SM1177
title: "SM1177: lazysite's vendored OOM is 0.34"
subtitle: "The pinned OOM snapshot moves from 0.33 to 0.34, which adds file parameters; lazysite uses the file parameters (SM1162) and not the data cache or fast JSON."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: "OOM agent, inbox 2026-10-19-oom-0.34-file-cache-json.md; release manager, 2026-10-19 (wave 2)"
area: odoo
status-note: "SHIPPED on n656 (first commit): t/vendor/oom is OOM 03b703e (Package 0.34) by tools/vendor-oom.sh with both 0.34 debs. SM747's provenance is re-filed (the specification text is unchanged, so its hash is too). Nothing in t/unit/odoo/ or t/unit/daemon/ needed a fix."
---

# What happened

OOM 0.34 is built. Its note (2026-10-19) lists three things: file parameters
(`{ name, bytes, mimetype }` for `core.attach`, `crm.attach`, `discuss.post`,
`core.make` and `core.set`, with `Odoo::Ops::File->check`), an opt-in data
cache (`data_cache = 1`, `max_age` on `core.read` and `core.get`) and fast JSON
(`Cpanel::JSON::XS` when installed).

# What shipped

- **`t/vendor/oom` is OOM 03b703e, "Package 0.34"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.34_all.deb --deb
  odoo-oom-tools_0.34_all.deb 03b703e`; the library, the spec, `Odoo/Accounts.pm`,
  `Odoo/Tools/` and `bin/oomd` were checked against the debs. New files in the
  snapshot: `Odoo/Ops/File.pm`, `Odoo/JSON.pm`, `Odoo/Cache/`.
- **SM747's filed spec** needs no new text: MAPPER-SPEC.md is byte-identical
  to 0.33's (same sha256). Its provenance row and adoption list say 0.34.
- **Used by lazysite in this branch: file parameters only**, by SM1162 (a
  binding takes a file). **The data cache is not used** (lazysite passes no
  `max_age`, so every read stays live, and `data_cache` is not set) and **fast
  JSON is not used** (lazysite neither installs nor requires
  `Cpanel::JSON::XS`; OOM falls back to `JSON::PP`).
- **Nothing in lazysite broke**: `t/unit/odoo/` and `t/unit/daemon/` pass whole
  on 0.34 with no change; lints 207, 261, 262 and `t/tools/154`, `155` pass.
