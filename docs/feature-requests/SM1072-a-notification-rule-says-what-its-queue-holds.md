---
id: SM1072
title: "SM1072: a notification rule says what its queue holds, and the outbox is shown in the manager"
subtitle: "SM1010 R3. Q5 was ruled as recommended - queue only, and \"waiting for the scheduler\" on the rule's row when the daemon is not running. The row showed nothing, and the outbox and notify/failed/ were seen only on the filesystem."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: SM1010 R3, ruled 2026-10-12 (Q5 "as this brief recommended")
area: notifications
status-note: "SHIPPED (PENDING): handler-list gives a notify rule its queue in counts, its last run and `waiting` when the scheduler is not taking it; notify-outbox-list / read_notify_outbox (manage_notifications alone; a confined caller sees its own domains' rules) list queued, held and failed events and, by id, who one resolves to. t/unit/manager/340, t/integration/247."
---

# The ruling

The release manager, 2026-10-12 (SM1010 "Ruled"): "Everything else as this
brief recommended ... Q5 (queue only; 'waiting for the scheduler' without the
daemon) ... stand[s] as recommended." The recommendation (SM1010 Q5): "queue
only; a site without the daemon running shows 'waiting for the scheduler' on
the handler's row rather than sending inline." Phase 1c (SM1010 "Phases"):
"the row's last outcome shown in the manager".

The coordinating session, 2026-10-13, for this build: "The outbox view shows
recipients, so it is behind manage_notifications, and a confined caller sees
only its own domains."

# What was wrong

SM1010 R3: "the handler's row shows no 'waiting for the scheduler' or last
outcome; the outbox and `notify/failed/` are not shown in the manager". A rule
whose daemon was not running queued events that nobody would ever send, and
the Handlers page said "on".

# What was built

- **The rule's row.** `handler-list` gives each notify handler an `outbox`
  object - counts only: `queued`, `retrying`, `held` (messages held by the cap,
  SM1071) and `failed` - and `last`: what the rule's last run did (`sent`,
  `held`, `failed`) and the last failure with its time, kept until another
  replaces it. The job writes these to `notify/status.json` under its lock;
  the audit trail stays the record.
- **"Waiting for the scheduler"** (Q5): an event due more than three minutes
  ago (three ticks of the job) is waiting when the scheduler's run record says
  the `notify-outbox` job was refused (with the refusal's reason), has never
  run ("is the daemon running?"), or last ran more than three minutes ago
  (and how long). The row shows the tag and the reason.
- **The outbox** - `notify-outbox-list` on the control API, its twin
  `read_notify_outbox` over MCP: queued and retrying events (with the last
  error), held messages (rule, channel, recipient, how many events) and failed
  ones from `notify/failed/` (with the reason); `rule` narrows it, at most 200
  are listed and the rest counted. With `id`, one event, its fields and who it
  resolves to under the rule as it stands, each with what the ledger says was
  decided per channel: sent, refused, held or pending. The Handlers page shows
  it as a card, hidden from an account without the capability.
- **Who sees it.** It shows recipients, so it is `manage_notifications`' alone
  on both doors (a holder of `manage_forms`, `manage_data` or
  `manage_connectors` is refused, unlike `handler-list`). A domain-confined
  caller sees only the events of rules bound to a domain it reaches - SM1051's
  rule through `Manager::Common::handler_reach_refusal`: an instance rule is
  the operator's - and an event it may not see answers "not found", never
  "forbidden", so ids cannot be probed. The row's counts carry no recipient.

The control API's token-reachable count is 119 (t/lint/98); the action is a
reviewed read in t/lint/14.

# Tests and sabotage

- `t/unit/manager/340` - the row's counts, waiting in each of its three causes
  and not for a fresh event or a running job; the last run and the kept
  failure; held and failed counted; the outbox's states, the recipient view
  with the actor left out; may_see.
- `t/integration/247` - through the real CGIs: a holder of
  manage_notifications sees every rule's events and, by id, their recipients;
  manage_forms and a member are refused 403; a token and an MCP grant confined
  to one domain see that domain's rule only and get "not found" for another
  domain's or the instance's event; the row carries counts and no recipient.

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S1 | the cookie door also opens for manage_forms | 247 |
| S2 | the control API shows a confined caller every rule | 247 |
| S3 | the MCP twin shows a confined grant every rule | 247 |
| S4 | a stuck queue is never called waiting | 340 |
| S5 | handler-list carries no outbox state | 247, 340 |
| S6 | the job records no last outcome | 340 |
| S7 | the recipient view forgets that the actor is left out | 340 |

# Not done

Acting on the outbox - retrying or discarding a failed event, sending a held
message early - is not built: R3 asks for it to be shown. A failed event stays
in `notify/failed/` until someone removes it on the filesystem.
