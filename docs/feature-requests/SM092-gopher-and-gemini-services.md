---
title: "SM092 - Gopher and Gemini services"
subtitle: "Serve the same content tree over the small-internet protocols, as additional thin transports"
brand: plain
---

::: widebox
Browsing a lazysite tree as a plain index of links is reminiscent of Gopher - so
serve it as one. Two optional protocol front-ends over the *same* content tree the
HTTP processor already renders: **Gopher** (RFC 1436) and its modern successor
**Gemini** (`gemini://`, gemtext, TLS-required). Same "one core, many transports"
shape as the WebDAV and MCP front-ends - the protocol servers translate, the
content and its front matter stay the single source of truth.
:::

## Why this fits lazysite

The content is already plain Markdown with front matter, served by a processor that
is one of several thin transports over a shared core. Gopher and Gemini are small,
text-first protocols whose menu/page model maps cleanly onto a tree of Markdown:

- a **directory** becomes a menu/index of links (exactly what the dev server's
  `--auto-index` already generates for HTTP - see [[SM091]]);
- a **page** becomes a Gopher text item / a gemtext document, rendered from the
  same `.md` source (a Markdown -> gemtext reduction, not the HTML pipeline);
- front-matter `title` gives the link label, as it does in the auto-index.

## Shape (sketch, not committed)

Gopher (RFC 1436)
: a tiny TCP server on port 70. A selector maps to a path in the docroot; a
  directory returns a Gopher menu (type `1`) of its sub-folders and pages; a page
  returns a text item (type `0`) - the Markdown flattened to plain text (strip
  front matter, render links as menu entries). No TLS, no auth - public content
  only, and the deny-list still applies (never serve `lazysite/`, `.brief`,
  protected pages).

Gemini
: a TCP server on port 1965, **TLS mandatory** (self-signed is normal for Gemini;
  trust is TOFU). Requests are a single `gemini://host/path` line; responses are a
  status line + gemtext body. A directory returns a gemtext index (`=>` link
  lines); a page returns gemtext converted from Markdown (headings `#`, links
  `=>`, lists, quotes - a lossy but faithful reduction). Auth-required and
  payment-required pages are not served (or return the appropriate Gemini status);
  the same ACL/deny rules as every other transport.

Both are **read-only, public-content** transports - no manager, no WebDAV, no
write path. Enforcement stays in the shared core; these add no authority.

## Open questions

- Markdown -> gemtext / Gopher-text conversion: reuse a reduced pass of the
  processor, or a dedicated small converter? gemtext has no inline links, so links
  must be lifted to trailing `=>` lines - a real transform, worth its own helper.
- Packaging + run model: standalone daemons (like the dev server is a standalone
  HTTP server), enabled per site, off by default. Not CGI.
- Directory index: share the auto-index tree-walk from SM091 (front-matter titles,
  sub-folder + page links) behind a format-agnostic lister, emitting HTML / Gopher
  menu / gemtext from one walk.
- TLS for Gemini: self-signed cert generation + TOFU; certificate lifecycle.
- Scope: which front matter maps across (title, nav, register); what is dropped
  (forms, payment, TT, fenced constructs) in a text-only medium.

## Status

Queued - candidate. Raised 2026-06-26 (prompted by the SM091 auto-index browse
resembling a Gopher menu). A natural companion to the "one enforced core, many thin
transports" architecture; lowest-friction first step is the directory lister shared
with SM091.
