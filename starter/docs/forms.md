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
to configurable targets (email, API webhooks, Slack).

## Quick start

1. Add `form: formname` to front matter
2. Add a `:::form` block with field definitions
3. Create `lazysite/forms/formname.conf` with dispatch targets
4. Configure SMTP in `lazysite/forms/smtp.conf` (for email targets; an example file is provided as `smtp.conf.example`)

## Front matter

The `form:` key in front matter enables form processing for the page
and names the form. The name must be alphanumeric with hyphens and
underscores only:

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

Each form needs a config file at `lazysite/forms/FORMNAME.conf`:

```yaml
targets:
  - type: smtp
    url: http://localhost/cgi-bin/lazysite-form-smtp.pl
```

### Target types

`smtp`
: POST form fields as JSON to the SMTP helper URL. See
  [SMTP configuration](/docs/forms-smtp).

`api` with `format: json`
: POST all non-internal fields as JSON to the URL. Works with any
  webhook that accepts JSON POST.

`api` with `format: slack`
: POST as Slack-compatible `{"text": "field: value\n..."}` format.

Multiple targets can be configured - all are dispatched on each
submission:

```yaml
targets:
  - type: smtp
    url: http://localhost/cgi-bin/lazysite-form-smtp.pl
  - type: api
    url: https://hooks.slack.com/services/xxx
    format: slack
```

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

The installer copies `lazysite-form-handler.pl` and
`lazysite-form-smtp.pl` to `cgi-bin/`. Both must be executable.

For manual installation:

```bash
cp lazysite-form-handler.pl /path/to/cgi-bin/
cp lazysite-form-smtp.pl /path/to/cgi-bin/
chmod 755 /path/to/cgi-bin/lazysite-form-*.pl
```

## Further reading

- [SMTP configuration](/docs/forms-smtp) - email delivery setup
- [Form helpers](/docs/forms-helpers) - writing custom dispatch targets
