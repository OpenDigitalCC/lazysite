---
title: "SM189 - Prevent raw-mode (api:/raw:) on ordinary content pages"
subtitle: "An agent can replace a Markdown page + theme with a raw HTML document via content_type; the XSS downgrade contains the security risk, but the theme is lost and CDN links slip past the no-CDN guard"
brand: plain
status: shipped
status-note: "IMPLEMENTED on claude/sm188-190-field-fixes (2026-07-21, commit 7f6409c): Common::raw_html_page_refusal refuses api:/raw: + a script-capable content_type via action_save (manager + MCP) and WebDAV PUT (415), plus the building-sites briefing note. Awaiting gate + vcs-review + release. Extends ADR 0006 from editorial-only to a boundary; not an XSS gap (already downgraded)."
---

# SM189 - Prevent raw-mode on ordinary content pages

## Why

ADR 0006 reserves raw mode (`api:` / `raw:` with `content_type:`) for
self-contained artifacts and enforces that EDITORIALLY (the building-sites
briefing). In the field, an agent published a site's `index.md` as a full raw
HTML document:

```
---
title: UNITED
content_type: text/html; charset=utf-8
api: true
---
<!DOCTYPE html>
<html lang="en"> ... <link href="https://fonts.googleapis.com/css2?..."> ...
```

Consequences:

- The page bypasses the layout + theme entirely - the engine's whole value
  (content through a layout, styled by a theme, cached) is gone.
- `peek_content_type` (the 0.8.0 security boundary) correctly downgrades the
  script-capable `content_type` to `text/plain` + `nosniff`, so there is no XSS
  - but the page now serves as broken plaintext source.
- The raw HTML pulled in Google-Fonts CDN links, evading the no-CDN guard
  (`check-no-cdn.sh` only checks themes/layouts, not content bodies).

Editorial-only proved insufficient: an agent found raw mode and used it anyway -
the same reason the XSS boundary was already made mechanical.

## What (not) to do

- KEEP raw mode for genuine artifacts (JSON / CSV / embed fragments) - do not
  remove it.
- Do NOT silently rewrite the author's file - refuse or warn, do not mangle.

## Design

Two complementary levers:

1. Stronger instruction (editorial, ships in the briefing). Add an explicit,
   hard-to-miss rule to `/docs/ai-briefing-building-sites` (and the MCP
   initialize instructions + the WebDAV onboarding brief): content pages are
   Markdown rendered through the layout + theme; NEVER set
   `api:` / `raw:` / `content_type:` on an ordinary page (especially `index.md`)
   to ship your own HTML/CSS - the engine serves it as plain text (ADR 0006), the
   theme is lost, and external font/CSS/CDN links are refused. Raw mode is only
   for self-contained artifacts; fonts must be bundled OFL/Apache, never a CDN.

2. Write-path guard (mechanical). On the write paths a content author reaches -
   WebDAV `PUT`, MCP `write_file` / `create_page`, the manager save - refuse (or
   loudly warn on) an ordinary content page, and especially the site index /
   primary page, that declares `api:` / `raw:` with a script-capable
   `content_type`. A genuine artifact (a deliberate artifact path, or a
   non-script type such as JSON/CSV) is still accepted. This turns the ADR 0006
   doctrine into a boundary rather than a hope - mirroring how the XSS
   type-downgrade was already made mechanical rather than editorial.

## Security note

This is NOT an XSS gap: `peek_content_type` already downgrades `text/html` /
`xhtml` / `svg` on any `api:`/`raw:` page to `text/plain` with `nosniff`, so the
body cannot execute. It is a site-integrity / design-integrity + CDN-policy gap:
an agent can destroy a themed page and smuggle CDN assets past the no-CDN guard.

## Tests

- A content page (e.g. `index.md`) declaring `api: true` + `content_type:
  text/html` is refused (or warned) at the write path; an artifact path, or a
  non-script content type, is accepted.
- The briefing text names raw-mode-on-a-content-page as prohibited (a doc/
  content check, alongside the existing "no content page uses raw mode"
  close-out item).

Related: ADR 0006 (raw-mode-for-artifacts-only), the no-CDN guard
(`check-no-cdn.sh`), SM082 (delegated content authorship), `peek_content_type`.
