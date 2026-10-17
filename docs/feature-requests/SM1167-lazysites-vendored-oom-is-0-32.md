---
id: SM1167
title: "SM1167: lazysite's vendored OOM is 0.32"
subtitle: "The pinned OOM snapshot moves from 0.27 to 0.32; no lazysite code needed to change, and nothing in lazysite uses what 0.31 and 0.32 added yet."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: "OOM agent, inbox 2026-10-18-L7-oom-0.31-shipped-answers-and-differences.md and 2026-10-18-oom-0.32-rows-inline-reports-repeat-safe.md"
area: odoo
status-note: "SHIPPED on n648: t/vendor/oom (OOM bd9610e, Package 0.32), SM747 re-filed spec, tools/vendor-oom.sh takes a second --deb. No Odoo test failed on 0.32 before adaptation, so no lazysite code changed."
---

# What happened

OOM 0.31 (oomd, the resident daemon, and its client) and 0.32 (rows
parameters, inline reports, repeat-safe requests, blobs) are built and the
0.32 debs are installed on this host. The slices that will use them are named
and not started: SM1164 (the extension uses oomd), SM1166 (a binding takes a
list of rows), SM1162. lazysite's tests run on a pinned snapshot (SM1081), so
the first step is to adopt 0.32 as that snapshot, as SM1156 did for 0.27, and
to find what changed that lazysite reads.

# What changed in OOM that lazysite sees

- **Rows (0.32).** An operation may declare a `rows` parameter
  (`type: rows`, `max`, `row` as a hash of `str`/`int`/`bool` fields, a
  trailing `?` optional); `Odoo::Ops::Operation->check_rows` checks a value.
  `core.make` makes a record with its one2many lines (`lines.<field>`).
- **Inline reports (0.32).** `core.report inline=1` returns
  `content_base64`, `name`, `mimetype`, `bytes`, `sha1`, `pages`, capped by
  `max_inline_bytes`.
- **Repeat-safe requests (0.32).** `idem => KEY` / `--idem KEY` on `run`,
  `approve`, `apply`: a repeat answers the first result with `repeat: 1` and
  sends nothing to Odoo; a different request under the key is
  `refused/idem-mismatch`.
- **Blobs (0.32).** Attachment bytes and values over `blob_min` are held once
  in the run folder, checked by digest at apply.
- **The oomd client (0.31).** `Odoo::Ops::Client::Daemon` (explicit `socket`,
  `fallback => 0` gives `transport`/`daemon-down`), `Odoo::Ops::Version` and
  `/usr/share/odoo-oom/VERSION` for the installed version; every answer
  carries `via` (`daemon` or `in-process`).

# What shipped

- `t/vendor/oom` is OOM commit bd9610e ("Package 0.32") by
  `tools/vendor-oom.sh` (242 files; t/lint/261's MANIFEST).
- `tools/vendor-oom.sh` accepts a second `--deb`. OOM split
  `odoo-oom-tools` (`Odoo/Accounts.pm`, `Odoo/Tools/`) out of
  `libodoo-oom-perl`, so the check "the deb's library is the commit's" failed
  against the library deb alone; given both debs it compares all of
  `lib/Odoo`. A single `--deb` behaves as before.
- SM747's filed copy of the mapper specification is re-filed from the
  snapshot (sections 7 to 10, the Open list, the sha256, provenance;
  t/lint/207). Sections 1 to 6 are unchanged.
- The plugin's dependency floor is unchanged (`libodoo-oom-perl >= 0.03`;
  the sign-in message still says 0.27 for the two-factor step). The daemon
  slices will state their own minimum.

# Evidence

No Odoo test failed on 0.32 before any adaptation: `t/unit/odoo/` (40 files),
`t/integration/170-172` and `174`, and t/lint/207, 261, 262 and
t/tools/154-155 pass; `tools/ext-compat.sh` passes on the installed 0.32 deb
and on OOM's tree. No lazysite code changed. Nothing in lazysite uses rows,
inline reports, idem, blobs or the oomd client yet.
