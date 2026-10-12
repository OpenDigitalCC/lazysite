---
id: SM1020
title: "SM1020: the notify-outbox job sends each recipient once"
subtitle: "SM1010 phase 1c/1d: the daemon job that resolves a notify rule's recipients, caps, renders, sends by email and the per-member bell, and audits one row per recipient; with SM1010 F3 (an addressed bell notice shows only to its addressee)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1010 phase 1, ruled 2026-10-12
area: notifications
status-note: "SHIPPED (PENDING): engine job notify-outbox (needs manage_notifications) resolves the five sources, leaves out the actor unless notify_actor, caps per recipient, sends once each under a hashed ledger, one audit row per recipient; email via form-smtp's message mode (RFC 2047 Subject, List-Unsubscribe); per-member bell with F3's reader filter. t/unit/notify/03-05."
---

# What was built

## The job (n443)

`notify-outbox`, a new entry in the scheduler's closed `%JOBS`, every 60 s,
`needs => 'manage_notifications'` - the capability that gated writing the
rule. Its body is `Lazysite::Outbox::run`:

1. One run at a time (`notify/.run.lock`).
2. The ledger (`notify/ledger.jsonl`) is read first; **one that exists and
   will not open stops the run** - "could not tell what was sent" must not read
   as "nothing was", or a retry sends twice. Lines older than eight days are
   pruned.
3. For each due entry (at most 50 a tick): the rule must still exist, be a
   notify rule and be on, or the entry is failed and audited.
4. **Recipients** from the five sources. A `where` whose field the event lacks
   matches nobody. Rows are read 500 at a time; more than 5,000 recipients for
   one event fails the entry and sends nothing.
5. **The actor is left out** - the account, and its own address where an
   address source holds it - unless `notify_actor: true`.
6. Per recipient and channel: skip if the ledger has the key (a hash of rule,
   event, channel, recipient - never the address); refuse past
   `per_recipient_hour`; render; send; audit.
7. A transport failure keeps the entry with a back-off (2, 4, 8, 16 minutes)
   and the ledger stops the retry re-sending to anyone already reached; after
   five attempts the entry moves to `notify/failed/`.

**Audit**: `audit_log(<job account>, 'notify', 'notify:<rule> -> <channel>',
'', ok|failed, 'daemon', 'account <name>' | 'address <addr>' [- reason])` - one
row per recipient per channel, as ruled. Refusals (no address, the cap, an
address that is not exactly one) are failed rows with the reason.

**Email** goes through the Form SMTP extension's `--pipe` in a new message
mode: the rule's composed subject and body, and a `List-Unsubscribe` header.
The extension accepts a header only from a closed list and only in its own
shape (`<http(s)://...>`), encodes a non-ASCII Subject (RFC 2047,
`Lazysite::Mail::encode_header`: 45-byte words split between characters) and
refuses a To/From that is not one address (SM1017). The **unsubscribe line is
added by the engine**, not the template, so a template cannot drop it while the
rule has it on; with no absolute site address (`base_url` in notify.conf, or
`site_url`) the entry fails with that reason rather than sending a header that
is not a URL.

**Templates** are TT files, `notify-templates/<name>.email.tt` (first line
`Subject: ...`) and `<name>.bell.tt`, with `ABSOLUTE => 0, RELATIVE => 0,
EVAL_PERL => 0` and the templates directory as the only include path. Fields
are data: each at most 400 characters, control characters removed.

## The per-member bell (n444, SM1010 F3)

`Lazysite::Notify::bell_for` writes a notice with `to` set straight to the
bell store - not through `notify()`, whose type routing could have copied one
member's notice to the site's XMPP room. `Lazysite::Manager::Notices` now shows
a notice addressed to an account to that account only, on both doors (the
manager API and MCP's read_notices), and counts and marks only what the
reader can see. Before, an addressed notice would have shown to every holder
of `notifications` (F3).

# Tests and sabotage

- `t/unit/notify/03` - the worked case end to end; where-field absent; the
  cap; notify_actor; retry after a transport failure; unreadable ledger;
  no absolute address.
- `t/unit/notify/04` - addresses from a table, the submitter's field, a row
  naming two recipients refused; RFC 2047; the header shape guard.
- `t/unit/notify/05` - the bell: addressed notices reach their account only.

| Ref | Sabotage | Caught by |
| --- | --- | --- |
| S9 | a where field the event lacks is dropped from the filter | 03 |
| S10 | the ledger check removed | 03 (the retry re-sends) |
| S11 | the actor exclusion removed | 03 |
| S12 | encode_header returns the raw value | 03, 04 |
| S13 | the per-recipient cap off | 03 |
| S14 | the bell reader shows addressed notices to everyone | 05 |
