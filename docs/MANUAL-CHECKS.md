---
title: "lazysite - What the test suite cannot check"
subtitle: "The areas where a green gate proves nothing, why each one is out of reach, and the manual pass that covers it"
brand: plain
---

# Why this document exists

The gate is thorough about the things it can reach: 6,000-odd tests, a
performance baseline and per-file coverage floors. It is silent about several
areas where lazysite's behaviour actually lives, and that silence reads exactly
like success.

The risk is not that these areas are untested. It is that **"all tests passed"
gets reported as "it works"** when the suite never touched the thing in question.
Every entry below is a case where a change can be complete, green and wrong.

Each section says what cannot be checked, **why** it is out of reach, and the
smallest manual pass that covers it. Where a lint pins the *structure* of
something whose *behaviour* is unreachable, that is called out - a passing lint
there means "the shape is still right", never "it works".

# Manager UI JavaScript

## Why it is out of reach

The manager pages are shipped Markdown with inline JavaScript, rendered into the
browser. The repository has **no browser harness** - no headless Chrome in the
gate, no DOM, no event loop. Nothing executes that code during a test run.

`t/lint/24-no-control-chars-in-manager-pages.t` and
`t/lint/29-domains-one-form.t` read the page SOURCE. They can tell you a function
exists, an id is not duplicated and a retired form has not come back. They cannot
tell you a button works.

## The pass

Sign in to the manager and work each page you changed. For the Domains page
specifically (SM259 consolidated two forms into one, so both modes need
exercising):

1. **Add domain** &rarr; a content folder, a title, an appearance, seed ticked.
   Confirm it registers, appears in the list, and the seeded home page exists.
2. **Add domain** again &rarr; fill in only the host. Confirm it registers and
   every other value shows as inherited.
3. **Add domain** &rarr; use *Copy settings from* against an existing domain.
   Confirm the content folder, title, appearance and language copy across, and
   that the **site address does not** - the new host gets its own.
4. Type a host into a fresh Add form and watch the **site address fill itself
   in**; then edit the address by hand and keep typing in the host. The address
   must stop following once you have touched it.
5. **Configure** the domain you just made. Confirm the sheet shows what you set,
   and that the two modes agree about which fields a domain has.
6. Confirm **Preview**, **Check**, **Export site** and **Delete** still work from
   the sheet, and that Delete is the only destructive control in the danger zone.

For any other manager page: exercise the control you changed, then reload and
confirm the change persisted - a control that updates the DOM without saving
looks identical to one that works.

# Web-server behaviour (vhost templates)

## Why it is out of reach

The vhost templates are configuration for Apache and nginx. The suite has
neither. `t/lint/28-registries-routed-to-engine.t` asserts the routing lines are
PRESENT in all four templates and explains why; it cannot start a web server and
issue a request.

This gap has already cost a release: SM248's per-domain handler was correct in
the processor and unreachable in production, because `FallbackResource` only
routes paths that do not exist. It worked on the dev server, which is where it
was tested, and nowhere else.

## The pass

On a real Apache or nginx front, with at least two domains where the secondary
has its own `content_root` **and the primary has registries of its own** (a
primary with no `sitemap.xml` proves nothing - there is nothing to fall through
to):

```bash
curl -sS https://secondary.example/sitemap.xml | head
curl -sS https://secondary.example/llms.txt   | head
```

Both must reflect the secondary domain, not the primary. Repeat for
`robots.txt`, `feed.rss` and `feed.atom`.

**A deployed site does not get this from an upgrade.** The templates apply at
install time, so an existing vhost keeps its old routing until it is regenerated
or the lines are added by hand. Check the vhost actually in force, not the
template in the tree.

# Multi-domain serving

## Why it is out of reach

Per-Host behaviour needs a real `Host` header reaching a real front end. The
integration suite drives the processor directly with a synthesised environment,
which exercises the engine's logic and not the routing in front of it.

## The pass

For each registered domain: its own home page, its own 404 (mistype a URL and
confirm the branding is that domain's), its own theme assets loading rather than
404ing, and - if it is part of a language set - the switcher offering its
siblings.

Confirm a **chrome-only alias** (no `content_root`) still inherits the primary's
content. Breaking that trades one defect for another and the suite will not
notice.

# WebDAV clients

## Why it is out of reach

`t/integration/dav-publish.t` speaks the protocol directly. Real clients -
Finder, Windows Explorer, `rclone`, `cadaver` - differ in how they lock, how they
probe, and what they do with a `507`. A response that satisfies the RFC can still
confuse a specific client.

## The pass

Mount the endpoint with at least one GUI client and one command-line client.
Create, edit, rename and delete a file; confirm each lands. Then write to a
directory the site user cannot write and confirm the error names the condition
(SM235) rather than surfacing as a generic failure.

# The MCP connector

## Why it is out of reach

The unit tests drive the JSON-RPC endpoint as a subprocess, which covers the
protocol and the tool logic. They do not cover a real assistant connecting: the
OAuth exchange, the tool list as the client renders it, or how a model reads a
tool description.

A description that misleads an agent is a real defect and no test will find it -
SM261 exists because five tools returned five differently-named list keys and an
agent reported working code as broken.

## The pass

Connect a real client. Confirm `whoami` and `describe_capabilities` answer, that
the tool list matches what the account should hold, and that a refusal reads
clearly enough to act on. When a tool description changes, have the agent attempt
the task from the description alone.

# Delivery: email, chat, notifications

## Why it is out of reach

SMTP and XMPP delivery need a server on the other end. The suite checks that a
handler is invoked and what it is handed; it stops at the socket.

## The pass

Submit a real form on a site with an SMTP handler and confirm the mail arrives,
including from a queue rather than only in the happy path. With `notify-xmpp`
configured, confirm the chat notice arrives and carries **no submitted content** -
that is the design, and a regression would leak content to a phone on a lock
screen.

# Installer and permissions

## Why it is out of reach

`install.pl` runs as root against a real filesystem, sets ownership and modes,
and behaves differently under `sudo`. The suite exercises its logic in a
temporary tree as an unprivileged user, which is the wrong user on the wrong
filesystem.

This has already caused a live incident: a stable deploy dropped group write on
every root folder, which is what SM246 exists to prevent recurring.

## The pass

On a scratch host, install fresh and then upgrade in place. After each, confirm
group write survives on the docroot and every directory the engine writes to,
that a site user can still publish, and that `lazysite-check --fix` reports
nothing left to repair. Do the same run under `sudo` - the ownership path differs.

# FastCGI pool

## Why it is out of reach

`t/lib/MiniFcgi.pm` pins state isolation across consecutive pool requests over
the real protocol, which is the part most likely to break. It does not cover the
systemd unit, socket permissions, or what happens when the pool is not running.

## The pass

Under the pool: confirm anonymous traffic is served, a logged-in operator still
gets the admin bar (session traffic must stay on the CGI path), and stopping the
pool degrades visibly rather than serving stale or empty pages.

# Security headers as actually served

## Why it is out of reach

The processor's headers are asserted in the suite. What a browser receives is the
processor's set **plus whatever the front end adds, strips or overrides** - and
CSP and HSTS are deliberately vhost concerns, so they are absent from the engine
by design.

## The pass

```bash
curl -sSI https://example.test/ | sort
curl -sSI https://example.test/no-such-page | sort
```

The 404 must carry the same baseline set as the 200 (SM253). Confirm CSP and
HSTS are present if the vhost is meant to emit them - the engine will not.

# How to use this document

Read the section matching what you changed, not the whole file. If a change
touches an area listed here, **say so when reporting it**: "tests pass" is true
and incomplete, and the difference between the two is what this document exists
to keep visible.

When a manual pass finds something, the fix is usually a test one level down -
the routing lint (SM248) and the one-form lint (SM259) both exist because a
manual pass found what the suite could not.
