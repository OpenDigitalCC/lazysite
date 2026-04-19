---
title: AI briefing - configuration
subtitle: Guide for AI assistants helping users configure a lazysite installation.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an AI assistant helping a user configure a lazysite
installation. For content authoring, see
[AI briefing - authoring](/docs/ai-briefing-authoring). For view/theme
work, see [AI briefing - views](/docs/ai-briefing-views).

## Layout

A lazysite docroot typically looks like this:

```
DOCROOT/
  lazysite/
    lazysite.conf         # site config
    nav.conf              # navigation
    themes/               # installed themes
    auth/
      users               # user credentials
      groups              # group memberships
    forms/
      contact.conf        # per-form config
      handlers.conf       # named dispatch handlers
      smtp.conf           # SMTP connection settings
    cache/                # HTML cache, plugin cache
    logs/
    templates/
      registries/         # registry templates (.tt)
  manager/                # manager UI pages (if enabled)
  index.md
  [content pages]
```

## lazysite.conf

The main configuration file. Plain text, one key-value pair per line.

### Minimum

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
```

`site_url` uses Apache CGI environment variables so the same config
works on any domain.

### Full example

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
theme: default
nav_file: lazysite/nav.conf
search_default: true
log_level: INFO
log_format: text
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
auth_default: none
plugins:
  - cgi-bin/lazysite-auth.pl
  - cgi-bin/lazysite-form-handler.pl
  - tools/lazysite-audit.pl
```

### Value types

- Literal: `key: value`
- Environment variable: `key: ${REQUEST_SCHEME}://${SERVER_NAME}`
- Remote URL fetch: `key: url:https://example.com/VERSION`
- Directory scan: `key: scan:/blog/*.md sort=date desc`

All keys that are not reserved become TT variables in views and page
content.

## Navigation (nav.conf)

Define the site navigation as YAML:

```yaml
- label: Home
  url: /
- label: About
  url: /about
- label: Docs
  children:
    - label: Install
      url: /docs/install
    - label: Authoring
      url: /docs/authoring
- label: Resources
  children:
    - label: GitHub
      url: https://github.com/example
```

Items without `url` render as non-clickable group headings.
One level of nesting is supported.

Override the path in `lazysite.conf`:

    nav_file: lazysite/docs-nav.conf

## Authentication

### Users and groups

Users in `lazysite/auth/users`:

    alice:SHA256HASHHERE
    bob:SHA256HASHHERE

Groups in `lazysite/auth/groups`:

    admins: alice
    lazysite-admins: alice
    editors: alice, bob

Manage with the CLI:

    perl tools/lazysite-users.pl --docroot DOCROOT add alice password
    perl tools/lazysite-users.pl --docroot DOCROOT group-add alice admins

Or use the manager Users page.

### Page protection

Per-page:

```yaml
auth: required
auth_groups:
  - members
```

Site-wide default:

    auth_default: required

Custom HTTP header names (for external proxy):

    auth_header_user: Remote-User
    auth_header_groups: Remote-Groups

## Forms

Three config files work together:

`lazysite/forms/FORMNAME.conf` - per-form dispatch list:

```yaml
targets:
  - handler: email-delivery
  - handler: local-storage
```

`lazysite/forms/handlers.conf` - named handlers:

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
```

`lazysite/forms/smtp.conf` - SMTP connection:

```yaml
method: sendmail
sendmail_path: /usr/sbin/sendmail
```

Or for SMTP:

```yaml
method: smtp
host: mail.example.com
port: 587
tls: starttls
auth: true
username: webforms@example.com
password_file: lazysite/forms/.smtp-password
```

## Plugins

Plugins are CGI scripts and tools that register themselves with the
manager through a `--describe` JSON protocol. Auto-discovery scans
`cgi-bin/` and `tools/` for scripts supporting `--describe`.

Enable or disable from the manager Plugins page, or pre-enable in
`lazysite.conf`:

```yaml
plugins:
  - cgi-bin/lazysite-auth.pl
  - cgi-bin/lazysite-form-handler.pl
  - tools/lazysite-audit.pl
```

## Logging

```yaml
log_level: INFO        # ERROR, WARN, INFO, DEBUG
log_format: text       # text or json
```

Override at runtime with environment variables:

    LAZYSITE_LOG_LEVEL=DEBUG
    LAZYSITE_LOG_FORMAT=json

Logs go to `lazysite/logs/` (when writable) or stderr.

## Theme activation

Install a theme under `lazysite/themes/THEMENAME/`, then set in
`lazysite.conf`:

    theme: THEMENAME

After changing the theme, clear the HTML cache so pages regenerate:

    find DOCROOT -name "*.html" -delete

Or use Manager > Cache > Clear all.

## Tasks

### Setting up authentication

1. Decide the auth mode: built-in or external proxy.
2. For built-in: create users with `tools/lazysite-users.pl`, create
   groups in `lazysite/auth/groups`, enable the auth wrapper as the
   Apache `FallbackResource`.
3. Add `auth: required` to any page that needs protection, or set
   `auth_default: required` site-wide.
4. If the manager is enabled, set `manager_groups:` in `lazysite.conf`
   to the group(s) allowed to administer the site.

### Configuring a contact form

1. Write the page with `form: contact` in front matter and a `:::form`
   block.
2. Create `lazysite/forms/contact.conf`:

```yaml
targets:
  - handler: email-delivery
```

3. Add the handler to `lazysite/forms/handlers.conf` (see Forms above).
4. If using SMTP, set up `lazysite/forms/smtp.conf`.

### Setting up SMTP email delivery

1. Copy `lazysite/forms/smtp.conf.example` to `smtp.conf`.
2. For local delivery: keep `method: sendmail` and verify the local MTA
   accepts mail.
3. For remote SMTP: set `method: smtp`, `host`, `port`, TLS, and
   authentication. Store the password in `lazysite/forms/.smtp-password`
   with `chmod 600`.

### Enabling the manager

1. In `lazysite.conf`:

```yaml
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
```

2. Create the `lazysite-admins` group with at least one user:

```bash
perl tools/lazysite-users.pl --docroot DOCROOT group-add alice lazysite-admins
```

3. Visit `/manager` and sign in.
