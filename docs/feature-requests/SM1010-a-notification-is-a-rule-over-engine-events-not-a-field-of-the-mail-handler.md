---
id: SM1010
title: "SM1010: A notification is a rule over engine events, not a field of the mail handler"
subtitle: "WORK-PLAN-0154 P18. A brief for one mechanism that tells people things when something happens - a comment on a followed post first - over email, the bell, XMPP or a connector, triggered by a form or the scheduler, with a declarative rule to chain actions. Grounded in the engine at main b5ab1ce4."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-12
raised-by: release manager, from the news site's reports (inbox 2026-10-11, archived), 2026-10-12
area: notifications
status-note: "Ruled 2026-10-12. Phase 0 built (SM1017). Phase 1 built: verified actor (SM1018), notify handler + manage_notifications (SM1019), notify-outbox job, email, per-member bell with F3 (SM1020). Remains: Q7 folding, a member bell surface (SM1034), Q5 handler-row state, one-click unsubscribe, the handler door, phases 2-3. See Built."
---

# Ruled

The release manager, 2026-10-12. Recorded in the words given; where a ruling
overrides a recommendation below, the ruling stands.

- **Phase 0 - "Fix now".** F2 (SECURITY): a submitter address (and every place
  the mail handler puts a caller-influenced address into a header) must be
  exactly one address - no , ; < > or CR/LF - refused otherwise; F1: reproduce
  through the real delivery path (form-handler -> deliver) first; if
  confirmed, a quarantined submission sends no acknowledgement. Tests +
  sabotage. One branch, its own SM, CHANGELOG (PENDING). Built as SM1017.
- **Recipients.** "it isn't the system's job to enforce the policy of
  recipients, that's a business decision, as there may be external
  justifications to send to addresses loaded into the database, don't assume
  this is the only system. allow operator judgement as to if they are
  complying with privacy rules." Then ruled "Yes, engine = mechanism":
  recipients may be addresses stored in a table, owners' accounts, fixed
  addresses, or the submitter; the engine guards only technical safety - one
  address per recipient field with header-injection refused, delivery queued
  and sent once each, a per-recipient rate cap the operator sets, one audit row
  per recipient; documentation states compliance is the operator's
  responsibility.
- **Authoring - "New 'manage_notifications' cap".** A dedicated capability, off
  by default, held by the operator group, plus the capabilities of any handler
  the rule calls.
- **Unsubscribe - "Per rule, default on".** Each rule's messages carry an
  unsubscribe link and a List-Unsubscribe header unless the rule turns it off.
- **Everything else as this brief recommended**, except where the rulings
  above override: Q2 is overridden (addresses held in rows are allowed); Q3
  consent is the operator's judgement, with no engine-enforced opt-in; Q4
  authoring is `manage_notifications`. So Q1 (a form delivery carries the
  verified session account as its actor, context only), Q5 (queue only;
  "waiting for the scheduler" without the daemon), Q6 (the account's address
  as set), Q7 (per event, one message per recipient per hour per rule), Q8 (an
  unsubscribe link and `List-Unsubscribe`) and Q9 (phase 0 first) stand as
  recommended.

# Built (2026-10-12)

| Ref | What | Where |
| --- | --- | --- |
| B1 | Phase 0: F1 reproduced through form-handler.pl and fixed; F2 one address per header, refused otherwise | SM1017, n440 |
| B2 | Q1: a form delivery carries the verified session account as its actor | SM1018, n441 |
| B3 | The `notify` handler type, its recipient grammar (five sources), `manage_notifications`; delivery queues; quarantined queues nothing | SM1019, n442 |
| B4 | The `notify-outbox` job: resolve, leave out the actor, per-recipient cap, ledger (sent once each), audit per recipient, email with RFC 2047 Subject and List-Unsubscribe, TT templates | SM1020, n443 |
| B5 | The per-member bell and F3's reader filter | SM1020, n444 |
| B6 | R2: a member reads the notices addressed to them on `/account` (`me-notices`), never a broadcast | SM1044, n502 |

Not built, in order of need (each a candidate for its own filing):

| Ref | What remains | Needs |
| --- | --- | --- |
| R1 | Q7 folding: a recipient over the cap is refused and audited; later comments are not folded into the next message | build |
| R2 | A member surface for the bell | built as SM1044 (B6), under SM1034 |
| R3 | Q5: the handler's row shows no "waiting for the scheduler" or last outcome; the outbox and `notify/failed/` are not shown in the manager | build |
| R4 | One-click unsubscribe (an engine POST endpoint); today the link and header point at the operator's own page | build |
| R5 | The handler actions' door admits manage_forms, manage_data or manage_connectors; a group holding only manage_notifications cannot reach it | a ruling (widens the door) |
| R6 | The operator group (tmp/wt-a) should carry manage_notifications when it lands; today the sysop (manager) groups hold it by top-up | B-side of that branch |
| R7 | Phase 2 (event points, chains.conf) and phase 3 (row events, per-account XMPP, digests, connector channel) | as briefed |

# The ask

The release manager, 2026-10-12:

> "it can send to rows from the database, unless there is a strong security
> reason not to. option to send something to the commenter. this should be a
> generic mechanism, that can be used for notifications on actions. in this
> case its for when someone appends to the author's original post but could be
> used for other things. also it could be using another mechanism, not email.
> so write up a brief for this, considering how it could be generic, use other
> notification mechanisms, be triggered by form submit or scheduler. it is
> possible that a trigger glue is needed, that enables chaining of actions.
> brief it."

The field reports behind it (inbox 2026-10-11, archived): a news site of about
700 members wants a member who follows a post, and the post's author, told of
each new comment. The corrected report measured that members can already own
rows (`write_data`, `row_policy: personal`, engine-written `created_by`); what
is missing is mail to recipients taken from data. Its specification: run once
per accepted (not quarantined) submission; recipients are the owners of
matching rows; the address is the account's own, never a row's or a form's;
no mail to the commenter's own account; a per-recipient limit; one audit line
per delivery.

Grades: **(A)** read in the code at main b5ab1ce4, cited file:line; **(B)**
inferred from code read, or a proposal. Nothing here was run.

# What the engine has today

## Triggers

```datatable
columns: Event | Where it happens | A hook today? | Grade
widths: 3.5cm | 6.5cm | 3cm | X
bold: 1
tone: light
---
A form submission accepted | plugins/form-handler.pl: honeypot :213, token :214-215, rate limit :240-247, field rules :270, spam assessment sets `_quarantined` :274-278, then every bound target is delivered :286-306 | yes - the form's `targets:` list runs handlers in order | (A)
...but quarantined too | the target loop runs for a quarantined submission as well; only the bell notice is skipped (`unless $form{_quarantined}`, :327-328) | the flag reaches a handler as `ctx->{quarantined}` only (:295) | (A)
A quarantined submission confirmed | Manager/Plugins.pm `action_form_submission_confirm` :1322 clears the flags (:1339) and delivers nothing | no | (A)
The scheduler | daemon `Scheduler::tick`, Daemon/Service/Scheduler.pm:313-405; the closed `%JOBS` (:60) includes `schedule-run`, which calls `Handlers::deliver` for each due entry of `lazysite/forms/schedule.conf` with `origin => 'timer'` (Daemon/Jobs.pm:136-179) | yes - a schedule entry names a handler | (A)
A row written | `Data::Tables::insert_row` :681-696, `update_row` :771-792, `delete_row` :794-818; four callers of insert_row (the table handler Handlers.pm:1716, Manager/Data.pm, SitePackage.pm:777, Connectors.pm:904) | no - nothing is emitted | (A)
A page saved | `Manager::Files::action_save` commits through `Lazysite::Git::commit_paths` (Git.pm:344-350), which WebDAV and the other file actions also call | no; there is no separate "publish" step | (A)
An account approved | `action_form_submission_approve` (Plugins.pm:1450) runs the users tool's `account-approve` (`cmd_account_approve`, tools/lazysite-users.pl:2419), which audits `user-account-approve` (:2512) | no | (A)
An account requested | an ordinary submission on a form whose conf declares `account_email:` (Handlers.pm:918-939) | as a form submission | (A)
```

## Recipients and identity

- A form delivery has **no actor**: `actor => ''`, "SM402: no verified actor"
  (form-handler.pl:293). The handler does verify a session cookie, but uses it
  only as a boolean for the rate-limit waiver, "not recorded on the
  submission ... not passed to any handler" (:223-239). (A)
- So a table row written by a form has no owner, and Handlers.pm:1709-1714
  warns that a personal row from a public form "belongs to no account". A row
  written through the data endpoint by a member carries `created_by` from the
  actor (`_stamp`, Data/Tables.pm:652-668). (A)
- `smtp` handlers take a fixed `from` and `to` (Handlers.pm:80-81). The one
  recipient taken from data is `mail_the_submitter_field`: a second message
  to whatever address a named form field holds (:97-104), bounded by
  `submitter_per_destination_hour` (default 3) and `submitter_per_site_hour`
  (default 60) (:105-115), counted under hashed keys (:1797-1847). (A)
- `Lazysite::Notify` already mails an **account**, not an address: a notice
  with `to => <account>` goes to that account's own `email`, only if the
  account opted in with `notify_email` (`_mail_recipient`, Notify.pm:495-527),
  under a per-site `mail.per_hour` cap (default 60, :457-470). No caller passes
  `to` today (form-handler.pl:943, lazysite-auth.pl:873, lazysite-mcp.pl:3221).
  (A)
- `notify_email` is a self-service boolean; the address it uses is the one the
  account already has, "so no setting of theirs can point the site at an
  address of their choosing" (tools/lazysite-users.pl, comment beside
  `notify_email`, after `email` at :1840). (A)
- **There is no verified-email flag.** `email_verified`, `verified_email`,
  `email_confirmed` and `verify_email` appear nowhere in lib/, the CGIs,
  plugins/ or tools/. An account's address is whatever was set (by the
  operator, or by the approve flow from the request, Plugins.pm:1450-1545). (A,
  searched)

## Channels

```datatable
columns: Channel | Today | Grade
widths: 2.5cm | 12cm | X
bold: 1
tone: light
---
Email | Form SMTP script (plugins/form-smtp.pl): sendmail `-t` (:354) or Net::SMTP (:366-411); body built in Perl, one `key: value` line per field (:289-316); Subject = prefix + first of `subject`/`name`/`email` (:319-325), CR/LF folded (:326); From/To strip CR, LF, `<`, `>` (`sanitise_email` :413-417). No RFC 2047 encoding of Subject. | (A)
Bell | appends to `lazysite/logs/notices.jsonl` (Notify.pm:345-347); always on (`$on{bell} = 1`, :257); read by `Manager::Notices::action_notices`, last 100 lines, for holders of `notifications` - with no filter on `to`, so an addressed notice would show to every holder | (A)
XMPP | one site-wide destination in `lazysite/notify-xmpp.conf` (`jid password to`, Notify.pm:742-775); failures audited (`_audit_delivery_failure` :1143-1157, SM955); no per-account JID | (A)
Connector | "the only way out over HTTP" (Manager/Connectors.pm:11): https to any host, http to localhost only (:165-166), no redirects (:768), per-connector rate cap (:611-617), modes `scheduled authenticated public` (Egress.pm:58); reached from a handler (`_to_connector`, Handlers.pm:1938-1979) | (A)
```

## Configuration, capability and audit

- Handlers live in `lazysite/forms/handlers.conf` (Handlers.pm:260-263);
  `schedule.conf` sits beside it (:585-596). (A)
- Who may write a handler: the type's capability - `manage_forms` for smtp and
  file, `manage_data` for table, `manage_connectors` for connector; changing a
  type needs both (Handlers.pm:29-37, :1004-1007); scheduling a handler needs
  its type's capability (:1336-1339). "Delivery itself checks nothing"
  (:35-37). There is no `manage_handlers`; the capability list is
  `@CAP_KEYS`, Auth/Settings.pm:48-56. (A)
- A scheduled job is engine code: "No site, app, theme or config file can add
  one ... the moment a schedule becomes a configuration surface, 'write a
  schedule' becomes 'execute code on a timer'" (Scheduler.pm:12-17); a schedule
  entry's payload is fixed in configuration, "so nothing a visitor sends ever
  reaches a scheduled call" (Handlers.pm:594-596). (A)
- Every delivery writes one audit row: `audit_log(actor, 'deliver', "$source
  -> $id", ip, ok|failed, origin, note|why)` (Handlers.pm:1464-1466; writer
  `Lazysite::Audit::audit_log`, Audit.pm:86-104, fields folded of `|`, CR, LF
  at :92). (A)
- Message templates: Notify renders its built-ins by a single-pass
  substitution that does not re-scan inserted values (Notify.pm:210-216), and a
  site's `lazysite/notify-templates/<type>.<endpoint>.tt` with Template Toolkit,
  `ABSOLUTE => 0, RELATIVE => 0` (:149-168, :197-203); submitted fields are data
  (`fields`, `fields_text`, :377-390), never template source. The page-render
  protections (SM964-SM968) do not apply to handlers or notices; neither needs
  them while it renders no page. (A)

## Findings made while reading

- **F1. A quarantined submission is probably acknowledged.** The form handler
  strips every `_` key before delivery (`_visible_fields`, form-handler.pl:288,
  :1642) and passes the flag as context (`quarantined => ...`, :295), but
  `_acknowledge_submitter` asks the fields: `if $fields->{_quarantined}`
  (Handlers.pm:1881), which is never set on that path. The only test calls the
  sub directly with the key in the fields. The read is (A); that a message is
  sent is (B), not run. This is the "send something to the submitter" path the
  brief builds on, so it is fixed first (phase 0).
- **F2. A submitter address may name two recipients.** `_submitter_address`
  accepts `/\A[^\s@]+@[^\s@]+\z/` (Handlers.pm:1793), which admits a comma;
  the address becomes the `To:` header read by `sendmail -t` (form-smtp.pl:354,
  :357). `Notify::_mail_recipient` already refuses `, ; < >` (Notify.pm:525).
  (A for the patterns; B that sendmail splits it.)
- **F3. The bell has no reader for an addressed notice.** Any per-member bell
  needs a `to` filter first (A for the absence; no leak today, as no caller
  addresses one).

# The design

One shape for every case: **an event** (something happened, with its fields)
is matched by **a rule**, whose **steps** are handlers; a **notify** step
resolves **recipients** and sends through a **channel** with a **template**.
Everything is configuration over engine-defined parts: the events, the
condition operators, the recipient sources and the channels are code; a site
picks and combines them. That is the scheduler's rule (Scheduler.pm:12-17)
applied to chaining. (B)

## 1. Triggers

- **Phase 1 needs no new trigger.** A form's `targets:` already runs handlers
  in order per submission (form-handler.pl:286), and a schedule entry already
  runs a handler (Jobs.pm:177). A notify handler bound as the comment form's
  second target is the first user. (A for the hooks; B for the use.)
- **A notify step skips a quarantined submission** by reading
  `ctx->{quarantined}` - the context, not the fields (the F1 lesson). (B)
- **Phase 2 adds named event points**, each a single `emit($event, \%fields,
  %ctx)` at the place listed above: `form.accepted` (after the spam
  assessment, not quarantined), `form.confirmed` (Plugins.pm:1322),
  `schedule.<id>` (existing), and in phase 3 `row.inserted` / `row.updated` /
  `row.deleted` (after the successful `$dbh->do` in Tables.pm), `content.saved`
  (in `Git::commit_paths`, the one point every surface reaches) and
  `account.approved` (after `cmd_account_approve` succeeds). Each event carries
  the actor, origin, a stable event id and its own fields, and no more. (B)

## 2. Recipients

Recipient sources, all engine code:

```datatable
columns: Source | Resolves to | Phase
widths: 4cm | 9cm | X
bold: 1
tone: light
---
`accounts: [a, b]` | named accounts | 1
`owners_of: {table, where: {column: field}}` | the distinct `created_by` of the matching rows (accounts) | 1
`submitter: account` | the verified signed-in actor, if any (Q1) | 1
`group: name` | the accounts in a group | 2
`addresses_from: {table, column, where}` | raw addresses held in rows | only if Q2 allows; not recommended
`submitter: field` | the address in a form field - today's `mail_the_submitter_field`, unchanged | exists
```

**Addresses come from the user store, never from a row or a form**, in the
recommended form: a row names an account (its engine-written `created_by`),
and the address is that account's `email`, read through `_mail_recipient`
(Notify.pm:495-527), which already enforces the opt-in, the store's
readability and the address shape. (B)

### Security analysis: "send to rows from the database"

The release manager's words allow it "unless there is a strong security reason
not to". There is one for **addresses** held in rows; there is none for
**accounts** named by rows.

```datatable
columns: Risk | Addresses taken from rows | Accounts named by rows (recommended)
widths: 3cm | 6.5cm | X
bold: 1
tone: light
---
Open relay / spam | Whoever can write the row chooses where the site writes. A table filled by a form (table handler, Handlers.pm:132-179) or by any `write_data` holder in `writable_by` (Manager/Data.pm:445-500) becomes a send-to-anyone list, with the site's reputation and SPF behind it. The submitter path admits this risk for one address and bounds it with two caps (Handlers.pm:97-115); a table multiplies it by the row count. | The site only writes to addresses that accounts already hold, set by the operator or the approve flow. A member can only add themselves (a personal row is theirs, Tables.pm:698-769).
Subscription bombing | One writer adds a victim's address to many rows (the reports' own example: "one member could subscribe another to many posts"). | A row's owner is the writer, engine-stamped; nobody can subscribe another account.
Header injection | Row text reaches `To:`; the only guard strips CR, LF, `<`, `>` (form-smtp.pl:413-417), and a comma passes (F2). | The address is validated at the account, and again by `_mail_recipient`'s shape check, which refuses `, ; < >` (Notify.pm:525).
Harvesting | A message that lists or reveals other recipients, or a rule author who points a table of addresses at themselves, leaks the list. | One message per recipient, never To/Cc lists; a template sees the event's fields and the recipient's own name, never other rows.
Consent / unsubscribe | No record that the address's owner asked. | Two consents already exist: the account's `notify_email` opt-in (default off) and the member's own subscription row; deleting that row is the unsubscribe, and the member may (`row_policy: personal`).
Rate | Per-row sends scale with what writers add. | Per-recipient and per-rule caps, counted like the submitter caps (hashed keys), plus the site's `mail.per_hour`.
Who configures | Anyone who can write a handler of the type. | As for a table handler: `manage_data` for a rule that reads a table, plus `manage_forms` to bind it (Q4).
```

**Recommendation: phase 1 resolves accounts only.** Raw addresses from rows
(a newsletter list) wait for a ruling (Q2) and, if allowed, come with a
double opt-in: a confirmation sent once, a `confirmed` column the engine
writes, and a table only operators may write. (B)

**The commenter** ("option to send something to the commenter"): when the
form was submitted with a verified session, the commenter is an account and is
mailed as any other recipient (subject to the opt-in); otherwise the existing
`mail_the_submitter_field` path, with its caps and the F1/F2 fixes, is the
only way, and stays as it is. The commenter is excluded from the followers'
mail when the actor is known. Both need Q1. (B)

## 3. Channels

A channel is engine code with one contract (B):

    send( $conf, $recipient, $message ) -> { ok => 1 } | { ok => 0, why => '...' }

where `$recipient` is an account (email, bell, per-account XMPP) or the
channel's own fixed destination (site XMPP, connector), and `$message` is
`{ subject, text, url, event, fields }`. Notify's routes (`route.<type>`,
Notify.pm:221-259) already pick channels per notice type; the notify step
names them per rule instead.

```datatable
columns: Channel | Recipient | Phase | Note
widths: 2.5cm | 4cm | 1.5cm | X
bold: 1
tone: light
---
email | account (`_mail_recipient`) | 1 | through the Form SMTP script, as `_mail_send` does (Notify.pm:593-613)
bell (site) | the `notifications` holders | 1 | as today; a broadcast
bell (member) | account | 3 | needs a reader filtered on `to` (F3) and a member surface
XMPP (site) | the configured destination | 2 | as today
XMPP (account) | an account's JID | 3 | needs a per-account setting, opted in like `notify_email`
connector | the connector | 2 | a webhook; the payload is flat (Connectors.pm:672-704) and the connector's own mode and rate rules apply
```

## 4. The trigger glue: a chain rule

Phase 2. A rule, stored in `lazysite/forms/chains.conf` beside
`handlers.conf` and `schedule.conf`, read and written by the same family of
functions (Handlers.pm:454-465, :598-619):

    chains:
      - id: follow-comments
        enabled: true
        on: form.accepted
        form: comment
        if:
          - field: post
            present: true
        do:
          - handler: comments-table
          - handler: followers-mail
        on_fail: stop
        per_hour: 200

- **Conditions** are a closed set of operators over the event's fields
  (`present`, `equals`, `in`, `not`), no expressions and no templates: a
  condition language is code, and code is what the scheduler rule keeps out of
  configuration. (B)
- **Steps** are handler ids, run in order. A step's result (`ok`, `stored`,
  `type`, as `deliver` returns now, form-handler.pl:299-305) is in the context
  of the next, so a notice can link to the row the table step wrote, as the
  bell's submission notice already does with `$stored` (:299). (A for
  `stored`; B for the chain.)
- **Who may author**: the union of the capabilities of the handlers it calls,
  as `action_schedule_save` already demands for one (Handlers.pm:1336-1339),
  and `manage_forms` to bind a rule to a form event. No new capability in
  phases 1-2 (Q4). (B)
- **Loops**: an event raised by a step carries the chain ids above it; a rule
  never runs on an event it caused, depth is capped at 3, and each rule has a
  per-hour cap. In phase 1 no step raises an event, so no loop can exist. (B)
- **Idempotency**: every event has an id (a submission's is already one:
  `submission_row_id`, the SHA-256 prefix of the stored line, Handlers.pm:
  1481-1487; a schedule run's is entry + run time). A ledger keyed by
  (rule, event id, step, recipient) means a retried step never sends twice.
  (B)
- **Delivery is queued, not inline.** Mailing a thread's followers inside the
  form request would make the commenter wait on N sends (P4's 43 s timeout was
  the same shape). A notify step writes one outbox entry per event; an engine
  job, `notify-outbox`, added to `%JOBS` (Scheduler.pm:60), resolves the
  recipients and sends, as the daemon's job account (`run_jobs`,
  Scheduler.pm:131-191). Retries with backoff; after the last, the entry is
  marked failed. (B)
- **Failure**: `on_fail: stop` (default) or `continue` per rule. A failed step
  is audited and shown on the rule's row, as SM955 does for XMPP. (B)
- **Audit**: one row per recipient per delivery, reusing the delivery shape:
  `audit_log(actor, 'deliver', "chain:<id> -> <handler>", ip, ok|failed,
  origin, '<channel> -> <account>')` - the account, never the address. A
  refused recipient (no opt-in, no address, capped) is a `failed` row with the
  reason, so "why did I get nothing" has an answer. (B)

## 5. The worked case: a comment on a followed post

Tables (B, using parts measured in the corrected report):

- `posts` - the original post, `timestamps: true`, its `created_by` the
  author.
- `subscriptions` - `post`, `row_policy: true`, `timestamps: true`; a member
  writes `{post, row_policy: personal}` through the data endpoint and owns the
  row (measured on 0.15.3, the corrected report).
- `comments` - written by the comment form through a table handler.

Handlers:

    - id: comments-table
      type: table
      table: comments
      fields: post, comment
    - id: followers-mail
      type: notify
      channels: email
      recipients:
        - owners_of: { table: subscriptions, where: { post: post } }
        - owners_of: { table: posts, where: { id: post } }
      exclude: actor
      per_recipient_hour: 1
      template: comment-followers
      unfollow: /account/following

The comment form's conf: `targets: [comments-table, followers-mail]`.

The run, end to end:

1. A signed-in member posts a comment. The form handler accepts it (token,
   rate limit waived for the member, spam assessment clean) and, under Q1,
   carries the verified account as the actor.
2. `comments-table` writes the row, owned by the commenter (Q1).
3. `followers-mail` sees `quarantined` false, writes one outbox entry
   `{event: <row id>, handler: followers-mail, fields: {post, comment},
   actor}` and returns; the visitor gets their page.
4. Within a tick (60 s, Scheduler.pm:412-414) the job resolves the owners of
   `subscriptions` rows with `post` = the comment's `post`, plus the post's
   owner; drops the actor; drops anyone mailed about this post within the hour
   (the next comment is folded into the next message, Q7); and for each
   remaining account asks `_mail_recipient`, which drops anyone not opted in or
   without a valid address.
5. Each recipient gets one message from the `comment-followers` template: the
   post's title and link, the commenter's display name, the comment's first
   400 characters (the cap form notices already use, form-handler.pl:153), and
   the unfollow link.
6. One audit row per recipient; the outbox entry is closed; the ledger stops a
   retry from sending again.
7. The member reads their follow list with `db:subscriptions(mine)`, which the
   P17 ruling ("Allow own rows") makes possible without opening the table to
   every member.

The same handler with `recipients: [submitter: account]` and a
`comment-received` template is the "send something to the commenter" option.

## 6. Templates and escaping

- Templates are files under `lazysite/notify-templates/`, rendered as Notify
  renders site templates now: Template Toolkit with `ABSOLUTE => 0,
  RELATIVE => 0` (Notify.pm:197-203), the event's fields as data, never as
  template source (:377-390). Authoring one needs the capability of the rule
  that uses it. (A for the mechanism; B for its reuse.)
- Escaping is per channel, applied by the channel on output, never by the
  template author:
  - email text: no HTML; a header value (Subject) folded of CR/LF as today and
    RFC 2047-encoded when not ASCII (absent today, A); recipients never taken
    from template output;
  - HTML email: not in phases 1-2;
  - bell: JSON-encoded on write, HTML-escaped by the reader;
  - XMPP: plain text, control characters stripped;
  - connector: a flat JSON payload of named fields, no rendered text (the
    connector's existing rule, Connectors.pm:672-704).
- Field values are capped (400 characters, as above) and a link is built by
  the engine from the site's `base_url` (Notify.pm:224, :360) and a path, never
  from a field. (B)

## 7. Phases and sizes

```datatable
columns: Phase | What | Delivers | Size
widths: 1.5cm | 8cm | 4cm | X
bold: 1
tone: light
---
0 | F1: the acknowledgement reads `ctx->{quarantined}`; F2: the submitter address refuses `, ; < >`; tests through `deliver`, not the sub | a safe base | XS
1a | Q1: a form delivery carries the verified session account as `actor` (context only), so a table row is owned and the actor can be excluded | the commenter is known | S
1b | the `notify` handler type: recipient sources `accounts`, `owners_of`, `submitter: account`; channels email and site bell; `exclude: actor`; per-recipient cap; skip when quarantined | the follow-a-post case | M
1c | the outbox and the `notify-outbox` engine job; the ledger; one audit row per recipient; the row's last outcome shown in the manager | delivery off the request | S
1d | templates for notify steps; the unfollow link; docs | the message | S
2 | event points `form.accepted`, `form.confirmed`, `schedule.<id>`; `chains.conf` with conditions, ordered steps, `on_fail`, caps, loop guards; manager and MCP tools | generic chaining | M
3 | `row.*`, `content.saved`, `account.approved`; per-member bell; per-account XMPP; digests; connector channel | other uses | L
```

Phase 1 whole: M. All phases: L. (B)

# Open questions for the release manager

1. **May a form delivery carry the verified signed-in account as its actor?**
   SM402 keeps form deliveries actor-less because a typed name could not be
   trusted; a verified session cookie is not typed. Recommendation: yes, as
   context only (never a field), the same verification the rate-limit waiver
   already does (form-handler.pl:231-239); it also gives form rows a real
   `created_by`, the reports' first ask.
2. **Addresses held in rows: allowed?** Recommendation: not in phases 1-2;
   accounts only. If a newsletter list is wanted, a later phase with a table
   only operators may write, a double opt-in confirmation the engine records,
   and the same caps.
3. **Consent.** Recommendation: both the account's `notify_email` (exists,
   default off) and the member's own subscription row are required; no rule
   can mail an account that has not opted in.
4. **Who may write a notify handler or a chain?** Recommendation: no new
   capability now - `manage_forms` for fixed recipients, plus `manage_data`
   for any recipient drawn from a table, and the union of the step handlers'
   capabilities for a chain (the schedule's rule). Revisit a
   `manage_automation` capability at phase 2 if the union proves awkward.
5. **Queued delivery needs the daemon.** Recommendation: queue only; a site
   without the daemon running shows "waiting for the scheduler" on the
   handler's row rather than sending inline.
6. **No verified-email flag exists.** Recommendation: accept the account's
   address as the operator or the approve flow set it for phase 1 (that is
   what Notify's mail already trusts); add a confirmed-address flag only with
   Q2.
7. **Per event or digest?** Recommendation: per event, with one message per
   recipient per post per hour; later comments within the hour are folded
   into the next message. A daily digest is phase 3.
8. **Unsubscribe.** Recommendation: a link to the member's own follow page
   (deleting the row is the unfollow) and a `List-Unsubscribe` header pointing
   at it; one-click POST unsubscribe later.
9. **F1 and F2: fix now, ahead of this brief?** Recommendation: yes, as a
   phase 0 branch; F1 makes the site answer an address a spammer chose, which
   SM877's caps were built to bound.

# Done when

A comment on a post mails, once, each opted-in account that follows the post
and the post's author, never the commenter, never for a quarantined
submission, with one audit row per recipient and no wait in the form request;
and the same notify handler, bound to a schedule entry or (phase 2) a chain
rule, serves another event without new code.
