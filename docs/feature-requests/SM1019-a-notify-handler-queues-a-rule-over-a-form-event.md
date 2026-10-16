---
id: SM1019
title: "SM1019: a notify handler queues a rule over a form event"
subtitle: "SM1010 phase 1b: the `notify` handler type and the manage_notifications capability. Delivering one writes an outbox entry and returns; the daemon sends (SM1020)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1010 phase 1, ruled 2026-10-12 ("Yes, engine = mechanism"; "New 'manage_notifications' cap"; "Per rule, default on")
area: notifications
status-note: "SHIPPED (0.15.5): handler type notify (recipients JSON: accounts, owners_of, addresses_from, fixed, submitter), checked at save; needs manage_notifications (core, off by default, topped up into the manager groups); delivering it queues one outbox entry; quarantined submissions queue nothing. t/unit/notify/01, 02."
---

# The rulings it is built to

From SM1010 "Ruled" (2026-10-12): recipients may be addresses stored in a
table, owners' accounts, fixed addresses, or the submitter, and the engine
guards technical safety only; authoring needs a new `manage_notifications`
capability, off by default, held by the operator group; each rule's messages
carry an unsubscribe link and List-Unsubscribe header unless the rule turns it
off.

# What was built

- **The capability.** `manage_notifications` joins `@CAP_KEYS`, the
  capability descriptor, the Groups and Users pages and the check tool. No
  role bundle carries it. **There is no explicit operator group on main
  (b5ab1ce4)** - another session (tmp/wt-a) is building one - so it is held by
  today's manager (sysop) groups, which `_ensure_manager_group_caps` tops up
  with every capability a release adds; a site's sysops hold it on upgrade and
  nobody else does. When the operator group lands it should carry this
  capability.
- **The handler type `notify`**, cap `manage_notifications`, schema:
  `recipients` (a JSON list on one line - the grammar is in
  `Lazysite::Outbox`), `channels` (email, bell), `template`, `from`,
  `notify_actor` (default false), `per_recipient_hour` (default 3),
  `unsubscribe` (default true) and `unsubscribe_path`. Checked at save, by
  field: the grammar, every fixed address is exactly one address (SM1017),
  every table is declared, an `owners_of` table records its writer
  (`timestamps: true`), every column exists, the unsubscribe page is a path on
  this site and is required while unsubscribe is on.
- **Delivery queues.** `_to_notify` writes one entry to
  `lazysite/notify/outbox/` - the rule, the event's visible fields (bounded,
  never files), the actor (SM1018) and an event id - and returns. A
  quarantined submission queues nothing and says so in the delivery's audit
  row. `notify` is a new store in `Lazysite::Stores`.

# Not changed, and why

The handler actions' door (`manage_forms`, `manage_data` or
`manage_connectors`) is unchanged, so a group holding `manage_notifications`
alone cannot reach the handler page; the operator groups hold all of them.
Widening the door would have changed what those actions admit; it is left as
an open question.

# Tests and sabotage

- `t/unit/notify/01` - defaults, every source, eleven refusals by field, the
  capability, the table checks.
- `t/unit/notify/02` - through the CGI: a member's comment queues one entry
  with the actor and fields; a quarantined one queues nothing.

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S7 | the quarantine check in `_to_notify` removed | 02 |
| S8 | the type's capability set to manage_forms | 01 |
