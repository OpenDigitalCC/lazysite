---
title: SMTP configuration
subtitle: Configure email delivery for lazysite forms.
register:
  - sitemap.xml
---

## Overview

SMTP handlers in `lazysite/forms/handlers.conf` receive form
submissions, format them as email, and hand off to
`plugins/form-smtp.pl`. The connection settings (sendmail path, SMTP
host, TLS, authentication) live in a separate file,
`lazysite/forms/smtp.conf`, so multiple SMTP handlers can share one
connection configuration.

## Per-handler settings

In `lazysite/forms/handlers.conf`, each SMTP handler declares the
email envelope:

```yaml
handlers:
  - id: email-delivery
    type: smtp
    name: Email delivery
    enabled: true
    from: webforms@example.com
    to: admin@example.com
    subject_prefix: "[Contact] "
```

Keys:

`from`
: Envelope sender.

`to`
: Destination address.

`subject_prefix`
: Prefix for the email subject line. Followed by the first available
  short field (subject, name, or email).

`enabled`
: `true` (default) or `false`. Disabled handlers are skipped.

## Connection settings (smtp.conf)

`lazysite/forms/smtp.conf` defines how email is actually sent. The
installer provides `smtp.conf.example` as a starting point.

### sendmail method

Pipes the email to the local sendmail binary. Works on most Linux
servers with a configured MTA (Postfix, Exim, etc.):

```yaml
method: sendmail
sendmail_path: /usr/sbin/sendmail
```

### SMTP method

Connects to an SMTP server with optional TLS and authentication:

```yaml
method: smtp
host: mail.example.com
port: 587
tls: starttls
auth: true
username: webforms@example.com
password: your-smtp-password
```

For a local relay without TLS or auth:

```yaml
method: smtp
host: localhost
port: 25
tls: false
auth: false
```

## TLS options

`tls: true`
: Connect with implicit TLS (port 465 typically).

`tls: starttls`
: Connect plain, then upgrade to TLS via STARTTLS (port 587 typically).

`tls: false`
: Unencrypted connection. Only suitable for localhost relays.

## Authentication

Set `auth: true` to authenticate. The username comes from the
`username:` key. The simplest way to set the password is the
**Password** field on the Plugin Config page (or a `password:` key in
`smtp.conf`) - it is stored in the operator-only `smtp.conf` and never
shown back in the manager.

Alternatively, keep it out of the conf entirely with `password_file:`
(a path relative to the docroot); the file wins only when no
`password:` is set:

```bash
echo "your-smtp-password" > lazysite/forms/.smtp-password
chmod 600 lazysite/forms/.smtp-password
```

Both `smtp.conf` and the password file live under `lazysite/forms/`,
which is operator-only and denied to every publishing surface.

## Validating the connection

After saving, use **Validate SMTP connection** on the Plugin Config
page. It runs a staged check against the saved settings and names the
failing stage rather than a generic error:

- **host** - the name does not resolve (DNS / typo)
- **port** - nothing answers on that port (wrong port or a firewall)
- **TLS** - the port answers but the TLS mode is wrong (STARTTLS vs
  implicit TLS vs none)
- **auth** - the server rejected the username/password (or none is set)

It never sends an email - it connects, negotiates, authenticates, and
quits.

## Email format

The email body lists all form fields:

```
Form submission
----------------------------------------

name:        John Smith
email:       john@example.com
message:     Hello there

----------------------------------------
Submitted: Friday, 18 April 2026 at 14:30:00 BST
IP:        192.168.1.1
```

The subject line uses `subject_prefix` (from the handler config)
followed by the first available short field.

## Testing

Test with curl:

```bash
echo '{"config":{},"form":{"name":"Test","email":"test@test.com","message":"Hello"}}' | \
  DOCUMENT_ROOT=/path/to/public_html \
  perl plugins/form-smtp.pl --pipe
```

## Dependencies

- `Net::SMTP` (Perl core)
- `IO::Socket::SSL` (for TLS - `libio-socket-ssl-perl` on Debian)
