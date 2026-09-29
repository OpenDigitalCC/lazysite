---
title: Forms
subtitle: Add contact forms and data collection to any page.
register:
  - sitemap.xml
---

## Overview

lazysite forms are defined inline in page content using `:::form` blocks.
The processor generates an HTML form with built-in anti-spam protection.
Submissions are handled by a CGI script that validates them and hands
each one to the **handlers** its form names. A handler is a named function -
send an email, keep a file, store a row in a data table, send through a
connector - and the schedule calls the same handlers on a timer. Handlers are
configured on the manager's **Handlers** page, over the control API and MCP, or
with `lazysite-handlers.pl`; they are stored in `lazysite/forms/handlers.conf`.

## Architecture

Three config files work together:

`lazysite/forms/FORMNAME.conf`
: Per-form config. Lists the handler IDs that receive submissions - and
  nothing else: a target names a handler, never a destination.

`lazysite/forms/handlers.conf`
: The handlers (email, file, data table, connector). Each has an `id`, a
  `type`, a `name`, and its type's settings.

`lazysite/forms/smtp.conf`
: SMTP connection settings shared by all SMTP-type handlers.

A form targets one or more handlers by ID. Multiple forms can share the
same handler, and a form can dispatch to multiple handlers at once.

## Quick start

1. Add `form: formname` to the page's front matter
2. Add a `:::form` block with field definitions
3. Create the handler it delivers through, on the Handlers page (or with
   `save_handler` / `handler-save`)
4. Bind the form to it - the Forms list on the same page, `bind_form`, or
   `form-targets-save`
5. For email handlers, configure the Form SMTP extension (`lazysite/forms/smtp.conf`)

## Front matter

The `form:` key enables form processing for the page and names the form.
The name must be alphanumeric with hyphens and underscores only:

```yaml
---
title: Contact
form: contact
---
```

Without `form:` in front matter, `:::form` blocks render as an HTML
comment and a warning is logged.

## Field syntax

```
::: form
field_name | Label text | rules
submit | Button label
:::
```

Each line defines a field. Fields are separated by pipe characters:

- **field_name** - the HTML `name` attribute (alphanumeric, hyphens, underscores)
- **Label text** - displayed above the field
- **rules** - space-separated modifiers (see below)

The `submit` keyword as field name renders a submit button with the
label as button text.

## Field rules

`required`
: Field must be filled in. Adds HTML `required` attribute and shows
  an asterisk after the label.

`optional`
: Field is optional. This is the default if no rule is specified.

`email`
: Renders as `type="email"` input with browser validation.

`textarea`
: Renders as a `<textarea>` instead of a single-line input.

`select:opt1,opt2,opt3`
: Renders as a `<select>` dropdown with the given options.

`radio:opt1,opt2,opt3`
: The same choice with every option visible, rather than hidden behind a click.

`checklist:opt1,opt2`
: Checkboxes. The submission carries every ticked value.

`checklist-qty:opt1,opt2`
: Checkboxes with a quantity box beside each; the submission reads
  `opt1=60; opt2=40`. An option ticked with no quantity keeps its bare label.

Option labels containing a **comma** must be quoted - `select:"Smith, John",Jones`.
Spaces and brackets need no quoting. A list rule takes the rest of the line, so
put it last among a field's rules.

`max:N`
: Sets `maxlength` attribute. Default is 1000 if not specified.

`value:"TEXT"`
: A default the field opens with. The visitor can change it; it is an
  ordinary starting value, not a fixed one. To put a double quote **inside**
  the text, write it as `\"` — so `value:"the \"Old Barn\" room"` opens with
  *the "Old Barn" room*. A quote left unescaped ends the value early, and the
  site log says which field and which rule it could not read.

`prefill:PARAM`
: Fills the field from a **query parameter**, so a code the link already
  carries does not have to be typed. The parameter must be declared in the
  page's `query_params:` list - the allowlist is the gate, and a `prefill:`
  naming a parameter the page never declared fills nothing and says so in the
  render log. Where both are given, `value:` is the fallback and the URL wins
  when the parameter is present.

  ```markdown
  ---
  title: Apply
  form: apply
  query_params:
    - c
  ---

  :::form
  code | Your registration code | required max:12 prefill:c
  name | Your name              | required
  :::
  ```

  `/apply?c=ODX-4417` opens with the code already in the field - one tap from a
  QR code or an emailed link.

  **A prefilled value proves nothing.** It arrives from the URL, so a visitor
  can change it exactly as they could change something they typed. Treat it as
  what somebody claims, never as something the site has verified - if the value
  must be trusted, check it after the submission arrives.

## Example

```markdown
---
title: Contact
form: contact
---

## Get in touch

::: form
name    | Your name       | required max:200
email   | Email address   | required email max:254
phone   | Phone number    | optional max:30
subject | Topic           | required select:General,Support,Sales
message | Your message    | required textarea max:5000
submit  | Send message
:::
```

## Handler configuration

### Per-form config

`lazysite/forms/FORMNAME.conf` lists the handlers that receive
submissions:

```yaml
targets:
  - handler: email-delivery
  - handler: local-storage
```

Each entry references a handler by `id`. All listed handlers are
called on each submission. If one handler fails, the others still
run, and the visitor is thanked when at least one delivered. Every
handler's outcome is its own line in the audit trail - the form, the
handler and whether it delivered, never the fields.

### What the visitor is told

Two sentences, both written by the engine:

| What happened | What the visitor sees |
|---|---|
| The submission reached a store, a table or a mailbox | Thank you - your message has been sent. |
| A connector took it onward to a service | Thank you - your submission has been received and sent for processing. |

The second applies when any target on the form is a connector handler,
because then the submission left the site for a service to act on rather
than arriving for somebody to read - "your message has been sent" would
not be true. A form with both kinds of target gets the second sentence:
both things happened, and the onward one is the one the visitor could not
otherwise know about. It promises neither a reply nor a page to come back
to, because only you know whether your site shows the answer anywhere.

**The wording is not configurable, and that is deliberate.** A submission
without JavaScript is answered by a redirect back to the page, and the
sentence is chosen from the outcome the redirect carries in the query
string. A query string is writable by whoever composes the link, so
anything travelling in it could be put on your page by a crafted URL. What
travels is a short token naming one of the two sentences above; an
attacker choosing between them gains nothing, and a token that is not one
of them is shown as a refusal rather than as text.

The file's other keys (`rate_limit`, `upload_*`, `quarantine` and the rest,
below) are the form's own and survive every binding. A config written over
WebDAV is checked the same way the binding actions check it: a target that
is not `- handler: <id>`, or names a handler that does not exist, is refused
with 422 and the reason.

### Named handlers

`lazysite/forms/handlers.conf` defines the handlers:

```yaml
handlers:
  - id: email-delivery
    type: smtp
    name: Email delivery
    enabled: true
    from: webforms@example.com
    to: admin@example.com
    subject_prefix: "[Contact] "

  - id: local-storage
    type: file
    name: Local file storage
    enabled: true
    path: lazysite/forms/submissions

  - id: slack-notify
    type: connector
    name: Slack notification
    enabled: false
    connector: slack
```

A handler with `enabled: false` delivers nothing; a form whose only handler is
off refuses the visitor rather than thanking them. An absent `enabled` is on,
everywhere.

### Who may configure a handler

**Where a handler sends decides who may create, change or delete it** (SM842):

| Type | Needs |
|---|---|
| `smtp`, `file` | `manage_forms` |
| `table` | `manage_data` |
| `connector` | `manage_connectors` |

Changing a handler's type needs both. **Binding** a form to a handler that
already exists needs `manage_forms` alone - the vetting happened when the
handler was made. A refusal names the capability that would work.

### Handler types

`smtp`
: Sends form data as a formatted email. Requires `from`, `to`, and
  `subject_prefix`. Connection settings come from
  `lazysite/forms/smtp.conf`. See [Forms SMTP](/docs/forms-smtp).

`file`
: Writes each submission to a file under `path`. Useful for logging,
  offline processing, or testing without email infrastructure.

`connector`
: Sends the submission through a named [connector](/docs/connectors) -
  the only way data leaves the site over HTTP. A connector with nothing but
  a URL is the simple case; it may add a credential, a rate cap and a record
  of every call, and `format: slack` sends the Slack message shape. For a
  form, the connector must permit public invocation (`modes.public`, off by
  default) - binding a form to one that does not is refused, because it
  would refuse every submission. Give the form fixed choices rather than
  free text for any field that reaches the remote.

`table`
: Inserts each accepted submission as a row in a declared data table, under
  a `fields:` mapping (`form_field=column,...`) that decides which field goes
  in which column - a field nobody mapped is dropped. With `keep_copy: true`
  (the default) the JSONL submissions store is written alongside, so the
  Submissions page, exports and bulk delete keep working; a submission the
  table's types refuse leaves no row, the visitor is told it failed, and the
  stored copy is marked `_row_refused`. `keep_copy: false` stores the row
  only. `row_policy: personal` makes each row belong to the account that
  submitted it, so one person maintains their own row and nobody else's - it
  needs the table to declare `row_policy: true`, and it needs the submitter to
  be signed in, because a public form records no account and the row would
  belong to nobody. Leave it out and rows are shared, as before.
  `files_column:` names a column of the same table to receive the
  submission's uploaded files, as site-relative paths, comma separated - so
  the row somebody works from reaches the photograph instead of only the
  submissions store. It needs the copy, which is what stores the files, and
  the column is checked against the table when the handler is saved.
  See [Data tables](/docs/data-tables).

There are no `webhook`, `api` or `db` handlers any more: a webhook is a
connector, and `db` is `table` with `keep_copy: false`. The upgrade to
0.13.13 converts them, and converts inline form targets into named
handlers; `lazysite-check` reports anything it could not.

### Handlers on a timer

The schedule calls handlers too: an entry names a handler, how often (in
seconds, at least 300) and the fixed fields it is called with. It lives in
`lazysite/forms/schedule.conf`, and is edited on the Handlers page,
`save_schedule` / `schedule-save`, or `lazysite-handlers.pl schedule-save`.
Nothing a visitor sends reaches a scheduled call.

```yaml
schedule:
  - id: nightly-export
    handler: crm
    every: 86400
    enabled: true
    payload: {"source":"timer"}
```

The daemon runs each entry as its job account, which must hold the
capability of the handler's destination - the same rule as above. An entry
it may not run is refused by name in the run record and retried on the
next tick once granted; a delivery that fails waits its interval.

## Where a submission is POSTed

Only `/cgi-bin/form-handler.pl` accepts a submission. The generated form carries
it in its `action` attribute, so a visitor's browser does the right thing without
anyone thinking about it.

It matters when you are testing a form by hand, or driving it from a script.
POSTing the fields to the **page** URL instead - `/contact`, say - returns
**HTTP 200 and the rendered page**, and stores nothing. A 200 with a page body is
indistinguishable from success to anything checking status codes, so a test can
report a form working when nothing was ever stored.

Confirm a submission by what the store holds, not by the status code: `form_list`
shows the row count, and `read_form_submissions` reads the rows back.

## What happens when a submission arrives

Once a submission is stored, the site raises a notification. You do not need to
poll for one, and nothing is required to make this happen - it is automatic.

The notification appears in the manager's notification bell, which is the
record. Where the `notify-xmpp` extension is configured, the same notice is also
delivered as a chat message, so you hear about it without being logged in.

The message names the form and when it arrived. It deliberately carries **none
of the submitted content**, so it is safe to receive on a phone in a public
place. To see what was submitted, follow it up with the actions in the next
section.

Delivery is best-effort by design: the chat send is time-boxed so a slow or
unreachable server can never delay the visitor's submission, and if it fails the
stored notice is still there. The bell is authoritative; chat is a convenience.

Quarantined submissions do not notify. A submission held back by the spam
controls is recorded but does not raise a notice, so a spam run cannot flood you.

**What the spam controls look at.** Quarantine is **on unless you turn it off**
(`quarantine: off` in the form's conf) and is content-based - no puzzle for the
visitor, no tracker, nothing sent anywhere. It holds a submission back when:

- it carries **`spam_url_threshold` links or more** (two by default). A link is
  counted whether or not it was written with `https://`: a `www.` host and a
  host with a path count too, one host counts once however many ways it is
  written, and an email address is not a link.
- it contains a **link written to dodge a filter** - `example .com/offer`, with a
  space inside the host. One is enough; nobody types that by accident.
- **every field holds the same value**, or one run of five or more digits appears
  in every field, on a form with three or more filled in. That is a bot checking
  whether the form delivers, not a message.
- it matches one of your own `spam_keywords` (a comma-separated list, empty by
  default).

The reason is stored with the submission and shown on the quarantine filter, so
you can see which control held it and tune the threshold rather than guess.

### Configuring chat delivery

Chat delivery needs the `notify-xmpp` extension enabled (the Extension Manager
page, or the `extensions:` list in `lazysite.conf`) and a client config at
`lazysite/notify-xmpp.conf`:

```yaml
jid: site-bot@example.com      # required - the account the site sends AS
password: secret               # required
to: you@example.com            # required - an individual JID, or a room
host: xmpp.example.com         # optional - defaults to the jid's domain
port: 5222                     # optional - defaults to 5222
tls: 1                         # optional - defaults to on
muc: 0                         # set 1 when `to` is a group chat room
nick: My-Site                  # optional - defaults to the site name
```

All three of `jid`, `password` and `to` must be present or delivery is skipped
silently. One client and one recipient per site; use a room (`muc: 1`) when
several people should see the notices.

The connector needs `Net::XMPP` - on Debian, the `libnet-xmpp-perl` package.

## Reading what a form collected

A form with a `file` handler writes each submission to a store under
`lazysite/forms/submissions/<name>.jsonl`. Two actions read it, and both need
the `read_submissions` capability - a deliberate least-privilege grant that
permits reading submissions **without** permitting any edit to forms or
handlers.

`form_list` (MCP) / `form-list` (control API)
: Which forms exist, which handler types they use, whether a store exists, and
  `row_count` - the number of submissions. Counts only; it never returns
  content. A form that reports a count is a form whose content you can read with
  the action below, given the grant.

`read_form_submissions` (MCP) / `form-submissions` (control API)
: The submitted rows themselves - columns, rows, a stable `_id` per row, most
  recent 500. Values are the raw submitted data and should be treated as
  untrusted.

If those actions are not offered to your account, the capability has not been
granted rather than the feature being absent. Ask the operator.

## Forms as an intake mechanism

A form is the supported way for an anonymous browser to send something to a
lazysite site. It needs no sign-in, no credential and no software, and it works
on a phone.

That extends further than a contact form. A field declared `textarea` accepts a
long passage of typed or pasted text, with the maximum set per field
(`max:20000`), so a transcript, a questionnaire answer or a pasted document
arrives intact. Where a file is easier than a paste, a handler may accept
uploads with per-file and per-submission limits - see
[Form helpers](/docs/forms-helpers) for `upload_max_kb` and `upload_max_files`.

Submissions are append-only and each field is validated on its own terms, which
suits capture and does not suit a large document being edited repeatedly. Treat
the store as a capture surface: material that matters should be read out and kept
wherever your records are managed.

## Client-side behaviour

Forms submit via `fetch()` (AJAX). On success, the form is replaced
with a success message. On error, an error message appears below the
submit button. The page does not reload.

The form status area uses `aria-live="polite"` for screen reader
accessibility.

## Security

All security measures are automatic - no configuration needed:

**Honeypot field** - a hidden field (`_hp`) that must be empty.
Bots that fill all fields are rejected.

**HMAC timestamp token** - submissions must arrive between 3 seconds
and 2 hours after the form was rendered. Prevents replay attacks.

**Rate limiting** - maximum 5 submissions per IP per hour. Uses
`DB_File` for persistence.

The ceiling is per form: `rate_limit: 200` in the form's config raises it, and `rate_limit: off` removes it. Five an hour is right for a public contact form and wrong for an authenticated team working through a set of data-entry pages from one office address. Set it only on a form whose access is already controlled another way - the limit is what protects an open form from being used as a relay.

**Submission validity window** - a form's page carries a timestamp signed at
render, and a submission arriving more than two hours later is refused.

The window is per form: `timestamp_window: 86400` in the form's config widens
it, and `timestamp_window: off` removes the age ceiling. Two hours is right for
a contact form and wrong for a long, careful one - crossing it is the ordinary
case there, and the refusal lands after the typing rather than before it. `off`
disables the age check ONLY: the signature must still match, so a timestamp
cannot be forged or lifted from another form, and a submission arriving within
three seconds of render is still refused as automated.

**Header injection prevention** - CR/LF characters stripped from
all fields.

The HMAC secret is auto-generated and stored at
`lazysite/forms/.secret` (chmod 0660 - owner + group, never world,
so both the site user's tools and the web-server CGI can use it
whichever minted it first).

## Installation

The installer places both extensions under `{docroot}/../plugins/`
and symlinks `form-handler.pl` into `cgi-bin/` so Apache can route
`/cgi-bin/form-handler.pl` at it. `form-smtp.pl` does not need
`cgi-bin/` presence - it is invoked as a subprocess by
`form-handler.pl`.

For manual installation:

```bash
mkdir -p /path/to/plugins
cp plugins/form-handler.pl plugins/form-smtp.pl /path/to/plugins/
chmod 755 /path/to/plugins/form-handler.pl /path/to/plugins/form-smtp.pl
ln -s /path/to/plugins/form-handler.pl /path/to/cgi-bin/form-handler.pl
```

## Further reading

- [SMTP configuration](/docs/forms-smtp) - email delivery setup
- [Form helpers](/docs/forms-helpers) - writing custom dispatch targets
