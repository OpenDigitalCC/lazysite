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
`lazysite/forms/.secret` (chmod 0600).

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
