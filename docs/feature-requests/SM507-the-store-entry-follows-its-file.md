---
title: "SM507: the store entry follows its file"
subtitle: "SM245 recorded a moved file's brief staying under its old key as a tolerable interim until a reconcile adopts it. The field found the interim's cost first."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24 field-testing SM245 on edge: rename_page left the brief at the OLD path (the next agent asking for the renamed page's brief is told there isn't one - a page silently split from its own record of intent), and delete_page left the entry orphaned where nothing can list it. Both were the SM245 filing's own recorded interim (deviation 3). SHIPPED 0.10.30: store_entry_move / store_entry_remove in Manager::Briefs, called by action_move, action_delete, DAV MOVE and DAV DELETE - deliberately UNGATED (filesystem consistency, not an agent surface) with the docroot as a PARAMETER (the SM504 lesson: DAV never sets the package var). A COPY starts unbriefed, exactly as it starts with a fresh ACL. MCP delete_page's dead sidecar-removal line is gone; read_page's has_brief consults the store first, then the legacy sidecar. t/integration/72 drives move-carries / delete-removes on both the manager and DAV surfaces."
---

# The interim, closed

SM245 moved briefs into an engine-owned store and taught the engine to
forget sidecars - deliberately, with one recorded interim: "a moved file's
entry staying under its old key is the filing's own accepted interim rather
than a defect (a reconcile pass can adopt it)."

The site agent's field test found the cost before the reconcile arrived:

- `rename_page` reported `ok:true` and left the brief at the old path. The
  page and its record of intent silently parted company.
- `delete_page` reported `ok:true` and left the entry in the store, where
  no action can list it and none can remove it (SM508).

# The fix

Two ungated helpers in `Manager::Briefs`, called by every surface that
moves or deletes content:

- **`store_entry_move`** - carries the entry (file or subtree) to the new
  key on `action_move` and DAV `MOVE`.
- **`store_entry_remove`** - removes it on `action_delete` and DAV
  `DELETE`.

Ungated on purpose: carrying a store entry is filesystem consistency, not
an agent surface - a site with the plugin disabled but entries on disk
still deserves them kept consistent. The docroot rides as a parameter,
never the package variable, because the DAV process does not set it.

A `COPY` starts unbriefed, exactly as it starts with a fresh ACL.
