---
title: "SM555: listing the engine tree logs once"
subtitle: "Opening the /lazysite folder in the file browser writes one WARN per hidden entry, which reads as an attack in a log review."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): action_list's per-entry sweep asks is_blocked_path and is_blocked_config with LAZYSITE_LOG_LEVEL raised to ERROR for exactly those two calls (the logger's own knob; the blocklist and its decision are untouched), counts what it hid, and writes one INFO 'listing hid blocked entries' line per listing with the folder and the count; a direct touch of a blocked path still warns. Proving test t/unit/manager/99-listing-the-engine-tree-logs-once.t captures the log stream across one listing of /lazysite. FOUND 2026-08-25 by the path-core structural review, PROVEN by probe tmp/pathcore-probe.t (P5, evidence in tmp/pathcore-probe.out); class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. is_blocked_path logs on every hit (Manager/Common.pm 350, 363, 368) and action_list calls it per entry (Manager/Files.pm 209), so one listing of /lazysite writes six blocked-lazysite-tree WARN lines every time the file browser opens the folder that holds layouts and nav.conf. It is the manager doing its job, and in a log review it looks like a traversal attempt. Fix: a quiet variant for the listing filter, or log once per listing."
---

# The finding

`is_blocked_path` logs on every hit (`Manager/Common.pm 350, 363, 368`)
and `action_list` calls it per entry (`Manager/Files.pm 209`): one listing
of `/lazysite` writes six `blocked lazysite tree` WARN lines to the log
stream, every time the file browser opens the folder that holds layouts
and nav.conf. It reads as an attack in a log review and is the manager
doing its job.

# Why it matters

Operability: a WARN line is meant to draw an operator's eye. Six of them
per ordinary folder open bury the real warnings and train the reader to
skip the message that would matter if a genuine traversal attempt appeared.

# The proving test

A new lint or unit assertion counting log lines for one listing.

# Fix shape

A quiet variant of `is_blocked_path` for the listing filter, or one log
line per listing.
