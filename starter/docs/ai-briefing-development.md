---
title: AI briefing - development
subtitle: Guide for AI assistants working on the lazysite processor, scripts, and tools.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an AI assistant working on the lazysite codebase itself -
the processor, CGI scripts, and tools. For content, view, and
configuration work, see the other briefings:

- [AI briefing - authoring](/docs/ai-briefing-authoring)
- [AI briefing - views](/docs/ai-briefing-views)
- [AI briefing - configuration](/docs/ai-briefing-configuration)

## Repository structure

```
lazysite/
  lazysite-processor.pl        # main processor (CGI)
  lazysite-auth.pl             # built-in auth wrapper
  plugins/form-handler.pl     # form submission dispatch
  plugins/form-smtp.pl        # SMTP helper
  lazysite-manager-api.pl      # manager JSON API
  plugins/payment-demo.pl     # x402 payment demo helper
  plugins/log.pl              # shared log helper (optional)
  install.sh                   # system installer (HestiaCP + Apache)
  uninstall.sh                 # removes installer files
  tools/
    lazysite-server.pl         # dev server
    lazysite-users.pl          # user management CLI
    lazysite-audit.pl          # link audit
    build-static.sh            # static site build
  starter/                     # template files copied to docroot
    lazysite.conf.example
    lazysite/
      manager/                 # manager UI template + CSS (D013; internal)
      layouts/                 # operator-installed layouts + themes (D013)
      forms/                   # form config examples
    manager/                   # manager UI pages
    docs/                      # documentation (this site)
    registries/                # registry templates
    [demo pages]
  test-site/                   # scratch docroot for manual testing
```

## Design principles

**CGI architecture**
: Each request starts a fresh Perl process. No persistent state between
  requests. Cache files on disk are the state.

**Plain ASCII throughout**
: No em dashes, no smart quotes, no Unicode tricks in source files or
  documentation. Code assumes ASCII input.

**No shared Perl modules**
: Each script is self-contained (within reason). Avoids install complexity.

**Spec-driven development**
: Features are specified before implementation. Specs live in the
  session briefings; the implementation follows them.

**HTML tags in markdown source must be single-line**
: Inline HTML elements in `.md` files must keep their entire tag
  definition (opening `<` through closing `>`) on one line. The
  markdown parser treats line breaks inside a tag as block
  boundaries and can strip attributes, break nesting, or produce
  HTML whose `id`/`name` attributes never reach the DOM. Same
  rule for `<div>`, `<input>`, `<form>`, etc. TT template files
  (`.tt`) are not affected - multi-line tags there pass through
  untouched.

## Scripts and responsibilities

`lazysite-processor.pl`
: The core. Reads the request, locates the source `.md` or `.url` file,
  parses front matter, resolves TT variables, renders the view,
  caches the HTML, and returns it.

`lazysite-auth.pl`
: Wraps requests when built-in auth is enabled. Reads the session cookie,
  populates `X-Remote-*` headers, and hands off to the processor.

`plugins/form-handler.pl`
: Receives form POSTs, validates (honeypot, HMAC timestamp, rate limit),
  and dispatches to named handlers from `handlers.conf`.

`plugins/form-smtp.pl`
: SMTP helper. Called via pipe from the form handler. Sends email using
  sendmail or Net::SMTP.

`lazysite-manager-api.pl`
: JSON API backing the manager UI pages. Handles file CRUD, plugin
  enable/disable, theme install, user management.

`plugins/payment-demo.pl`
: x402 payment flow helper.

`tools/lazysite-server.pl`
: Dev server. Fakes Apache's CGI environment and dispatches to the
  processor, auth wrapper, or other scripts based on URL.

`tools/lazysite-users.pl`
: CLI for user and group management.

`plugins/audit.pl`
: Link audit - finds orphaned pages and broken internal links.

## Plugin --describe protocol

CGI scripts and tools that want to appear in the manager Plugins page
must support `--describe`. When invoked with that flag, they print a
JSON object to stdout and exit 0.

Required fields: `id`, `name`, `description`, `version`.

Optional fields: `config_file`, `config_keys`, `config_schema`,
`handler_types`, `actions`.

Schema example:

```json
{
  "id": "form-smtp",
  "name": "Form SMTP",
  "description": "SMTP connection settings for form email delivery",
  "version": "1.1",
  "config_file": "lazysite/forms/smtp.conf",
  "config_schema": [
    { "key": "method", "label": "Send method", "type": "select",
      "options": ["sendmail", "smtp"], "default": "sendmail" },
    { "key": "host", "label": "SMTP host", "type": "text",
      "show_when": { "key": "method", "value": ["smtp"] } }
  ],
  "actions": []
}
```

Types: `text`, `email`, `number`, `select`, `boolean`, `path`. Use
`show_when` to conditionally display a field based on another field's
value.

## log_event()

Every script declares:

```perl
my $LOG_COMPONENT = 'audit';  # or 'form-smtp', 'auth', etc.
```

And calls log_event:

```perl
log_event( $level, $context, $message, %extra );
```

- `$level`: `DEBUG`, `INFO`, `WARN`, `ERROR`
- `$context`: request URI or other stable identifier, or `-`
- `$message`: short human-readable description
- `%extra`: key-value pairs for structured logging

Log level is read from `LAZYSITE_LOG_LEVEL` (env) or `log_level` in
`lazysite.conf`. Format is `LAZYSITE_LOG_FORMAT` (text or json) or
`log_format`. Output goes to `lazysite/logs/LOG_COMPONENT.log` when
writable, otherwise stderr.

## Cache mechanism

Pages are cached as `.html` files alongside their source `.md` files.

- A request for `/about` serves `about.html` if newer than `about.md`.
- If the `.html` is missing or stale, the processor regenerates it.
- `index.md` compiles to `index.html` and is served directly by Apache
  via `DirectoryIndex`.
- Force regeneration by deleting the `.html` file.

Pages with `auth:` or `payment:` are never cached to disk and always
set `Cache-Control: no-store, private`.

## Dev server

Start the dev server for local testing:

    perl tools/lazysite-server.pl --docroot /path/to/docroot --port 8080

Flags:

- `--docroot PATH` - site docroot
- `--port N` - listen port
- `--log-level LEVEL` - override log level

The dev server auto-detects built-in auth when `lazysite/auth/users`
exists.

## Rsync deployment

Standard rsync command for local dev to a deployed site, preserving
runtime state on the destination:

```bash
rsync -av --delete \
    --exclude='.git' \
    --exclude='test-site' \
    --exclude='starter/lazysite/auth/' \
    --exclude='starter/lazysite/forms/contact.conf' \
    --exclude='starter/lazysite/forms/handlers.conf' \
    --exclude='starter/lazysite/forms/smtp.conf' \
    --exclude='starter/lazysite/lazysite.conf' \
    --exclude='starter/lazysite/nav.conf' \
    --exclude='starter/lazysite/cache/' \
    --exclude='starter/lazysite/logs/' \
    /home/user/lazysite/ /srv/projects/lazysite/
```

## Test site

`test-site/` is a scratch docroot for manual testing. It is git-ignored
and can be rebuilt freely:

    cp -r starter/* test-site/
    perl tools/lazysite-server.pl --docroot $(pwd)/test-site --port 8080

## Key design decisions

**No persistent process**
: Every feature must work correctly in a cold-start CGI environment.
  No in-memory state, no background workers.

**Idempotent cache**
: Cache writes are atomic (write to a temp file, rename). Concurrent
  regeneration is safe.

**Plain ASCII**
: Source files and generated output are ASCII unless the page body
  legitimately contains non-ASCII content. No smart quotes, em dashes,
  or non-ASCII whitespace in code or docs.

**Spec-driven sessions**
: Features land via briefings that name files, tasks, and validation
  tests. Flag ambiguities rather than guessing.
