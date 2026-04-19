---
title: SMTP configuration
subtitle: Configure email delivery for lazysite forms.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

`lazysite-form-smtp.pl` receives form data as JSON POST from the
form handler and sends it as a formatted email. It supports three
delivery methods.

## Configuration

Edit `lazysite/forms/smtp.conf` (the installer creates this from `smtp.conf.example`):

```yaml
method: sendmail
sendmail_path: /usr/sbin/sendmail
from: webforms@example.com
to: hello@example.com
subject_prefix: "[Contact] "
```

## Methods

### sendmail

Pipes the email to the local sendmail binary. Works on most Linux
servers with a configured MTA (Postfix, Exim, etc.):

```yaml
method: sendmail
sendmail_path: /usr/sbin/sendmail
from: webforms@example.com
to: hello@example.com
subject_prefix: "[Contact] "
```

### localhost

Connects to a local SMTP server via `Net::SMTP`. No authentication,
no TLS:

```yaml
method: localhost
host: localhost
port: 25
from: webforms@example.com
to: hello@example.com
subject_prefix: "[Contact] "
```

### remote

Connects to a remote SMTP server with optional TLS and authentication:

```yaml
method: remote
host: mail.example.com
port: 587
tls: starttls
auth: true
username: webforms@example.com
password_file: lazysite/forms/.smtp-password
from: webforms@example.com
to: hello@example.com
subject_prefix: "[Contact] "
```

## TLS options

`tls: true`
: Connect with implicit TLS (port 465 typically).

`tls: starttls`
: Connect plain, then upgrade to TLS via STARTTLS (port 587 typically).

Omit `tls` for unencrypted connections (port 25, localhost only).

## Authentication

Set `auth: true` to authenticate. The username comes from the
`username:` key. The password is read from a separate file specified
by `password_file:` (path relative to docroot):

```bash
echo "your-smtp-password" > lazysite/forms/.smtp-password
chmod 600 lazysite/forms/.smtp-password
```

The password is never stored in the conf file.

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

The subject line uses `subject_prefix` followed by the first available
short field (subject, name, or email).

## Testing

Test with curl:

```bash
echo '{"name":"Test","email":"test@test.com","message":"Hello"}' | \
  DOCUMENT_ROOT=/path/to/public_html \
  perl cgi-bin/lazysite-form-smtp.pl
```

## Dependencies

- `Net::SMTP` (Perl core)
- `IO::Socket::SSL` (for TLS - `libio-socket-ssl-perl` on Debian)
