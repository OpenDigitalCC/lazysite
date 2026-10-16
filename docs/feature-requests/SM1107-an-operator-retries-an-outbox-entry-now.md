---
id: SM1107
title: "SM1107: an operator retries an outbox entry now"
subtitle: "notify-outbox-retry and retry_notify_outbox end the backoff of a rule's waiting entries, and the outbox card has a Retry now button."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.7 test plan (edge.explore.lazysite.io), "Found while getting mail to send"
area: notifications
status-note: "SHIPPED on n614: Lazysite::Outbox outbox_retry, notify-outbox-retry, retry_notify_outbox, handlers.md; t/unit/notify/08, t/integration/260, t/unit/manager/348."
---

# What happened

From "Found while getting mail to send" in the 0.15.7 results:

> No way to retry an outbox entry now. After a transport fix, entries sit in
> backoff for minutes. notify-outbox-list is the only outbox action. A "retry
> now" for the operator would make a mail fix testable without posting fresh
> events.

# What shipped

- `notify-outbox-retry` on the control API (body: `rule` or `id`) and
  `retry_notify_outbox` over MCP, gated `manage_notifications` like the list
  beside them. A domain-confined caller reaches its own domains' rules only;
  another's event is not found.
- It makes the waiting (retrying) entries due now and sends nothing: the
  outbox job sends them on its next run, under everything it always applies.
  The per-recipient cap and a held message are not bypassed (a held message is
  counted in the answer and left), an entry already sent is not made due
  again, a given-up entry stays given up, and the attempts are kept.
- While the job is running it answers busy rather than race it.
- The action is audited, as every mutating action is.
- The Notification outbox card on the Handlers page puts a Retry now button on
  an entry that is retrying.

t/unit/notify/08, t/integration/260, t/unit/manager/348.
