---
id: SM1093
title: "SM1093: a deleted notify rule takes its queued notifications with it"
subtitle: "Deleting a notify rule removes its unsent entries from the outbox and says how many; entries already stranded are cleared by the outbox job, never sent."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.5 test plan, T4)
area: notify
status-note: "SHIPPED on n604: Lazysite::Outbox purge_rule and the job's orphan sweep, Lazysite::Handlers action_handler_delete; t/unit/notify/06."
---

# What happened

From the 0.15.5 test plan results, "Found outside the rows":

> **Notify outbox outlives its rule.** Deleting a notify rule leaves its
> queued entries in the outbox (three for zz55-mail, three for zz55-bell,
> still listed by notify-outbox-list after the delete), and nothing removes
> them.

The delete only rewrote `handlers.conf`. The entries named a rule that no
longer existed, so the job could never send them; it failed each one with
"no rule" only when it next reached it, and until then they were listed as
queued.

# What shipped

- `handler-delete` (and MCP `delete_handler`) on a notify rule removes that
  rule's unsent entries: queued and retrying outbox entries, and held
  messages (folds). The result carries `outbox_removed`, and the audit row's
  detail reads `outbox_removed=N`.
- Sent history (the ledger) and the failed record are not touched, and
  another rule's queue is not either.
- Residue from earlier deletes: at the start of each run the `notify-outbox`
  job gives up every entry and held message whose rule is no longer in
  `handlers.conf` (audited, kept with the failed ones as SM1071 already did
  for one it reached), sends none of them, even those not yet due, logs `cleared N notification(s)
  queued for rules that no longer exist`, and reports `orphans_cleared` in
  its detail. A rule that exists but is switched off or retyped keeps its
  queue, as before.
