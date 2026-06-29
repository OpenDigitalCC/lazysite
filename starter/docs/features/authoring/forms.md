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
- `tel` - telephone input; gets a default validation pattern (override with `pattern:`)
- `date` / `time` - date / time picker (`type="date"` / `type="time"`)
- `number` - numeric input; `min:N` / `max:N` set the value bounds
- `url` - URL input (`type="url"`)
- `password` - masked input
- `textarea` - renders as a textarea
- `select:opt1,opt2,opt3` - renders as a dropdown
- `pattern:REGEX` - HTML5 validation pattern. Example: `phone | Phone | tel pattern:[0-9+()-]{7,20}`
- `placeholder:TEXT` - greyed-out hint text inside the field
- `max:N` - maxlength for text inputs (default 1000); the max **value** for `number`
- `min:N` - the min **value** for `number`
- `file` - renders a file picker (`<input type="file">`) for **binary uploads**
  (images, PDFs, ...). Add `multiple` to allow several files in one field, and
  `accept:LIST` to hint the browser's picker (`accept:image/*` or
  `accept:.png,.pdf`). The form automatically switches to
  `enctype="multipart/form-data"` when it contains a file field.

Rules are whitespace-separated. A value that needs **spaces** (a placeholder, or a
pattern with a literal space) is quoted: `placeholder:"Your full name"` or
`pattern:"[0-9 +()-]{7,20}"`.

Validation is enforced in the browser (HTML5 attributes); the handler accepts the
submitted fields.

### Handler configuration

Create `lazysite/forms/FORMNAME.conf`:

    targets:
      - type: smtp
        url: http://localhost/plugins/form-smtp.pl

Target types: `smtp` (email via helper), `api` with `format: json`
(webhook), `api` with `format: slack` (Slack notification).

### File uploads

A form accepts binary uploads only when its `.conf` declares upload limits (so a
form never accepts files by accident). Add any of these keys to
`lazysite/forms/FORMNAME.conf`:

    targets:
      - handler: jsonl          # a "file" target is required to STORE the files
    upload_max_files: 3         # max files per submission (default 5)
    upload_max_kb: 5120         # max size of EACH file, KiB (default 5120 = 5 MiB)
    upload_accept: png, jpg, pdf  # allowed extensions (default: any)

A submission that breaks a limit is rejected before any handler runs, with a
specific message to the visitor ("File 'x.png' is too large...", "File type not
allowed...", "Too many files...").

Uploaded files are stored by the **file** (`jsonl`) target, in a per-submission
subdirectory **next to** the `FORMNAME.jsonl`:

    lazysite/forms/submissions/FORMNAME.jsonl
    lazysite/forms/submissions/FORMNAME.files/<submission-id>/photo.png

The submission record names the files (it never stores the bytes inline):

    { "name": "Ada", "_files": ["photo.png"],
      "_files_dir": "FORMNAME.files/20260629T101500-1a2b", ... }

Filenames are sanitised to a safe basename (any path component is stripped, so a
crafted `../../etc/passwd` cannot escape the submission directory). A form with a
file field but no `file` target validates uploads but does not keep them - add a
`file` target to store them.

**Emailing uploads.** The SMTP (email) handler has an **Attach uploaded files**
option (`attach_files`, off by default). When on, the uploaded files are attached
to the notification email and listed (name + size) below the message. Leave it off
to keep emails small and just store the files; mind your mail server's attachment
size limits when enabling it.

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
