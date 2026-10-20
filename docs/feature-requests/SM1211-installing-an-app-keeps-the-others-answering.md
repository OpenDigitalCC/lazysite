---
id: SM1211
title: "SM1211: installing an app keeps the other apps' operations answering"
subtitle: "plugin-save gains `add`, which puts a namespace into odoo_packs under the lock, so two installs that overlap no longer drop each other's."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: the OOM Lab, oom-pick FINDINGS.md L-4
area: odoo
status-note: "SHIPPED (0.15.15) on n699: plugin-save `add` merges into a list setting under the lock. t/unit/odoo/80. The restart window itself answers in-process, not 404 (verified)."
---

# What was asked

The lab's L-4: "Installing one app rewrites `odoo_packs`; while another app was
installed, this app's operations answered 404 'no operation installed' for a few
seconds."

# The cause

The 404 text is lib/Lazysite/Odoo.pm `operation_class` (the line
`no operation '$name' is installed`), reached when `registry($conn)->class_for`
does not find the operation. `$conn->{packs}` is `odoo_packs` read from
lazysite/odoo.conf by `connection()` on every call, with no cache of the list.
So the operation is missing only when the file's list lacks its namespace.

- The file write is atomic (`write_file_checked`: temp, rename), so a reader never
  sees a torn or empty line. [[SM1172]] also made one save's read, change and write
  one locked step.
- What remained is the client's side. An installer that reads `odoo_packs`, appends
  its namespace and saves the whole value does a read-modify-write across two
  requests. Two overlapping installs each save a list without the other's
  namespace; the second to land drops the first's, and that app answers
  `no operation` until something saves its namespace again. That is the lab's few
  seconds, and it is what SM1172 recorded as open.

Checked and not the cause:

- A change of the list does not make a binding answer 404. The stored declaration
  (Lazysite::Odoo::Decl, stamped with `packs`, Decl.pm `fetch`) misses, and
  `binding_class` reads the registry in-process once, stores the declaration again
  and goes on (`rechecked`). With the list still holding the pack, the call answers.
- oomd's restart (Oomd.pm, `_env_signature` changed, `_stop`, `_start`,
  `_wait_ready`) leaves no socket for a moment. With `odoo_daemon: on` the call
  runs in-process (`_daemon_down`, lib/Lazysite/Odoo.pm); with `required` it is
  refused as `daemon-down`, a 503-kind answer, not "no operation".
- One window is OOM's, and is not an A-app one: until oomd has restarted on the new
  list, a call to the NEW app's operation reaches the old oomd, which started
  with the old `ODOO_OPS_NAMESPACES`. OOM reads packs from its environment at start;
  adding a pack without a restart would need an oomd verb that loads a pack.

# What shipped

- `plugin-save` takes an optional body field `add`, `{ key => item(s) }`, for a
  setting the extension's descriptor declares as a list (`list => ','` on
  `odoo_packs`, `list => ':'` on `odoo_pack_dirs`). Under the lock, the items are
  appended to the list the file holds now, skipping ones already there. An item is
  one plain token: a line break or the separator is refused, and a key that is not a
  list setting is refused. `values` and `add` may be sent together.
- docs/reference/control-api-actions.md names the field.
- t/unit/odoo/80, with the suite's fakes: add keeps the other namespaces, three
  installs in a row all land, bad items are refused with nothing written, and after
  the second app is added (daemon on, no oomd running) the first app's binding still
  answers in-process; a whole-value save of the second alone drops the first, which
  is the 404 the lab saw.

# Not changed

An installer that still saves the whole `odoo_packs` value from its own view keeps the
old behaviour; it should send `add`. Removing a pack stays a whole-value save.
