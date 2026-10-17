---
id: SM1123
title: "SM1123: the retry audit row names what was retried"
subtitle: "notify-outbox-retry and retry_notify_outbox audit against notify:<rule> or the entry id, with the counts in the detail."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.9 walk (edge.explore.lazysite.io), finding F-4
area: notifications
status-note: "SHIPPED on n625: Outbox retry_audit_target / retry_audit_detail, Manager::AuditTrail, lazysite-mcp.pl; t/integration/260."
---

# What happened

The 0.15.9 walk, finding F-4:

> the retry audit row's target is `/`; it does not record which rule or entry
> was retried.

The retry action carries no file path, so the audit block fell back to the request
path.

# What shipped

- The target is `notify:<rule>` (the form the unsubscribe audit uses, for example
  `notify:zz59-mail`) when the call names a rule, else the entry id.
- The detail on success is the counts: `retried=1 sent=0 already_due=0 held=0 failed=0`.
- The control API and the MCP twin take both from two helpers in Lazysite::Outbox
  (`retry_audit_target`, `retry_audit_detail`), so the two doors cannot word them
  differently. A refusal keeps its reason as the detail.

t/integration/260 reads the audit rows of both doors.
