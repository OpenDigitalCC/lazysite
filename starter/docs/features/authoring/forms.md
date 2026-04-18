---
title: Forms
subtitle: Add contact forms with built-in anti-spam and configurable dispatch.
tags:
  - authoring
  - api
---

## Forms

The `:::form` block defines an inline form with honeypot, HMAC
timestamp, and rate limiting built in. Submissions are dispatched
to configured targets (email, API, Slack) via a CGI handler.

### Front matter

Enable forms on a page with the `form:` key:

    ---
    title: Contact
    form: contact
    ---

The name must be alphanumeric with hyphens and underscores. Without
`form:` in front matter, `:::form` blocks are not rendered.

### Field syntax

    ::: form
    field_name | Label text | rules
    submit | Button label
    :::

### Field rules

- `required` - field must be filled in, adds `required` attribute
- `optional` - field is optional (default)
- `email` - renders as `type="email"` input
- `textarea` - renders as a textarea
- `select:opt1,opt2,opt3` - renders as a dropdown
- `max:N` - sets maxlength (default 1000)

### Handler configuration

Create `lazysite/forms/FORMNAME.conf`:

    targets:
      - type: smtp
        url: http://localhost/cgi-bin/lazysite-form-smtp.pl

Target types: `smtp` (email via helper), `api` with `format: json`
(webhook), `api` with `format: slack` (Slack notification).

### Example

    ---
    title: Contact
    form: contact
    ---
    ::: form
    name    | Your name     | required max:200
    email   | Email address | required email
    message | Your message  | required textarea max:5000
    submit  | Send message
    :::

### Notes

- Security is automatic: honeypot, HMAC timestamp (3s-2h window),
  rate limiting (5/hour/IP), header injection prevention
- Forms submit via fetch (AJAX) - no page reload
- HMAC secret auto-generated at `lazysite/forms/.secret`
- [Forms guide](/docs/forms) - full setup and configuration
- [SMTP configuration](/docs/forms-smtp) - email delivery
- [Form helpers](/docs/forms-helpers) - custom dispatch targets
