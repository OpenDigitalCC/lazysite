---
title: Forms
subtitle: Add contact forms and data collection to any page.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

lazysite forms are defined inline in page content using `:::form` blocks.
The processor generates an HTML form with built-in anti-spam protection.
Submissions are handled by a CGI script that validates and dispatches
to named handlers defined in `lazysite/forms/handlers.conf`.

## Architecture

Three config files work together:

`lazysite/forms/FORMNAME.conf`
: Per-form config. Lists the handler IDs that receive submissions.

`lazysite/forms/handlers.conf`
: Named dispatch handlers (email, file storage, webhooks). Each handler
  has an `id`, `type`, and type-specific settings.

`lazysite/forms/smtp.conf`
: SMTP connection settings shared by all SMTP-type handlers.

A form targets one or more handlers by ID. Multiple forms can share the
same handler, and a form can dispatch to multiple handlers at once.

## Quick start

1. Add `form: formname` to the page's front matter
2. Add a `:::form` block with field definitions
3. Create `lazysite/forms/formname.conf` pointing at a handler ID
4. Define the handler in `lazysite/forms/handlers.conf`
5. For SMTP handlers, configure `lazysite/forms/smtp.conf`

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

`max:N`
: Sets `maxlength` attribute. Default is 1000 if not specified.

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
dispatched on each submission. If one handler fails, the others still
run.

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
    type: webhook
    name: Slack notification
    enabled: false
    url: https://hooks.slack.com/services/XXX
    format: slack
```

Handlers with `enabled: false` are skipped.

### Handler types

`smtp`
: Sends form data as a formatted email. Requires `from`, `to`, and
  `subject_prefix`. Connection settings come from
  `lazysite/forms/smtp.conf`. See [Forms SMTP](/docs/forms-smtp).

`file`
: Writes each submission to a file under `path`. Useful for logging,
  offline processing, or testing without email infrastructure.

`webhook`
: POSTs form data to an HTTP URL. Set `format: json` for a plain JSON
  body, or `format: slack` for Slack-compatible `{"text": "..."}`.

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
record. Where the `notify-xmpp` plugin is configured, the same notice is also
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

### Configuring chat delivery

Chat delivery needs the `notify-xmpp` plugin enabled (the manager's Plugins page,
or the `plugins:` list in `lazysite.conf`) and a client config at
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

**Header injection prevention** - CR/LF characters stripped from
all fields.

The HMAC secret is auto-generated and stored at
`lazysite/forms/.secret` (chmod 0660 - owner + group, never world,
so both the site user's tools and the web-server CGI can use it
whichever minted it first).

## Installation

The installer places both plugins under `{docroot}/../plugins/`
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
