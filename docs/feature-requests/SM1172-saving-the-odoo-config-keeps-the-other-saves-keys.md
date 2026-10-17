---
id: SM1172
title: "SM1172: saving the Odoo config keeps what another save wrote"
subtitle: "plugin-save reads, changes and writes an extension's own config file under one lock, so two overlapping saves both land."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent, OOM Lab (inbox, L-15)
area: odoo
status-note: "SHIPPED on branch n661. t/unit/odoo/51-saving-the-config-keeps-what-another-save-wrote.t. Open: a client that adds a namespace to odoo_packs by reading the list and saving it whole can still lose a concurrent client's namespace; that needs an add-to-list verb, which is a design question (see the end)."
---

# What happened

OOM Lab, L-15, "parallel installs" (lazysite-sites agent, 2026-10-17): "Saving
`odoo_packs` while another app is installed left the other app's operations
answering 404 "no operation installed" for a few seconds (the list is
rewritten whole)."

# The cause

`plugin-save` writes `lazysite/odoo.conf` through `write_file_checked`, which is
atomic (temp file, rename), so the endpoint never reads a torn file and
`connection()` has no cache of the pack list: `registry()` rebuilds from
`odoo_packs` on every call. What was missing was the lock. The save READ the
file, changed it in memory and wrote it back with nothing held across the
three, while the `lazysite.conf` writer next to it holds one. Two overlapping
saves both read the old file and the second rename won, so the first save's
keys, an app's `odoo_packs` namespace among them, were absent from the file and
every operation of that namespace answered `no operation 'x' is installed`
until something saved the key again.

# What shipped

- `action_plugin_save`'s own-config-file branch takes `Lazysite::Util::store_lock`
  on the file (the lock the submissions store uses; no new scheme) before it
  reads, and holds it through the atomic write. Readers stay lock-free.
- Test first, driven by a hook at the point the first save has read the file,
  not by timing: the lock must be held there, and two overlapping saves of
  different keys both end up in the file. On the base the lock is free at that
  point and the second save's key is gone.

# Not changed

The `lazysite.conf` branch (extensions that declare `config_keys`) reads the
file before `write_conf_content` takes its lock, so it has the same window; the
Odoo extension does not use it, and moving the read inside `_write_conf` is a
change to the shared conf writer, left for a decision.

A client that installs an app by reading `odoo_packs`, appending its namespace
and saving the whole value is still a read-modify-write across two requests, so
two such clients can drop each other's namespace. Closing that needs a verb that
adds a namespace to the list under the lock (for example an `add` form of
`plugin-save` for list-typed keys). That is an API surface and is put to the
release manager rather than built here.
