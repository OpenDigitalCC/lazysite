# lazysite - User guide

For the person **using** a running lazysite site: an operator or author
managing content, and the AI publishing partners that an operator authorises.
For installing lazysite see [IMPLEMENTOR.md](IMPLEMENTOR.md); for running it in
production see [OPERATOR.md](OPERATOR.md).

## What you get

A site where pages are Markdown files in the docroot. Drop `about.md` and
`/about` renders as HTML on first request and is cached as a static file after.
There is no build step, database, or CMS - the filesystem is the content.

## Authoring content

- **Pages** are Markdown with YAML front matter (`title:`, `subtitle:`, …).
  Headings start at `##`; the page title comes from the front matter.
- **Layout + theme** wrap every page; activate one site-wide rather than per
  page (see the layouts guide).
- **Fenced divs** (`::: classname`), oEmbed, content includes, forms, and
  remote `.url` pages are available - see the authoring reference.
- **Navigation** is `lazysite/nav.conf`.

The full authoring/publishing references ship inside every site under
`/docs/` (served pages): *AI briefing - publishing / authoring / layouts /
configuration* and *reference*. They are written for an AI publishing partner
but are the canonical content rules for any author.

## The manager UI

Browse to `/manager` (operator login). From there: edit pages and files,
manage navigation, activate themes/layouts, manage users, clear cache, and
view the audit log. WebDAV publishing and the control API are toggled in
**Config**.

## Publishing as an agent (AI partner)

An operator can issue a partner a credential; the partner then publishes over
**WebDAV** (`/dav`) and the **control API**, scoped to what its grant allows.
Start points for a partner:

- `/.well-known/ai-partner` and the onboarding brief - identify, authenticate,
  locate, and find the docs.
- `whoami` over the control API - the partner's real capabilities, scope, and
  the deny list, from the server.
- The publishing briefing - the write/discovery workflow, the control-API
  actions, ACLs, `.brief` sidecars, and wiring forms.

## Command line

`tools/lazysite-users.pl` manages accounts/credentials from the shell;
`tools/lazysite-server.pl` is a local dev server for previewing a docroot
without Apache.
