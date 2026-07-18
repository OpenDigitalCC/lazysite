# 0006 - Raw mode is for self-contained artifacts, never content pages

Status: Accepted
Date: 2026-07-02 (retrospective; doctrine since the building-sites briefing,
0.5.23)
Tags: rendering, content-model, raw-mode, ai-partners

## Context

Pages carrying `api: true` or `raw: true` front matter are served verbatim -
no layout, no theme, no shared CSS. AI partners building sites discovered this
as an easy way to ship designed pages and produced "monoliths": 50 KB
single-file pages with inlined CSS, invisible to theming, unmaintainable, and
duplicated per page. The engine's whole value - content through a layout,
styled by a theme, cached - was bypassed.

## Decision

Raw mode (`api: true` / `raw: true`, with `content_type:`) is reserved for
**genuinely self-contained artifacts**: JSON/API endpoints, embed fragments,
one-off interactive widgets. Ordinary pages are Markdown rendered through the
active layout + theme, with structure in `layout.tt`/components and visual
identity in theme tokens. The *doctrine* (raw mode is for artifacts, not
pages) is enforced editorially: the agent pack's building-sites briefing
(`/docs/ai-briefing-building-sites`, also delivered via the MCP initialize
instructions and the WebDAV onboarding brief) names raw-mode misuse as the
root cause of monoliths, and the close-out checklist includes "no content
page uses raw mode".

The *security boundary* within raw mode is, since 0.8.0, enforced
mechanically: a raw/api page is served verbatim and unescaped, so a
script-capable `content_type` (`text/html`, `application/xhtml+xml`,
`image/svg+xml`) would be a stored-XSS vector reachable by a
`manage_content`-only delegate. Such a declared type is downgraded to
`text/plain` at serve time (`peek_content_type`) and logged; with the
response's `nosniff` header the body cannot execute. Editorial-only proved
insufficient here precisely because content authorship is delegated
separately from layout authorship (SM082) - a content author must not be able
to smuggle an HTML content type. HTML/SVG output belongs in a layout (escaped)
or a static file. See `docs/SECURITY.md` (2026-07-18) and
`t/integration/27-raw-content-type.t`.

## Rationale

The three-layer separation (content / layout / theme) is what makes a site
restylable in one swap, authorable by non-technical users, and cheap per page
(the design is O(1), pages are a few KB). Raw mode exists because some
artifacts genuinely need verbatim bytes; scoping it narrowly keeps the
exception from swallowing the rule.

## Consequences

- Agents get the doctrine on connect (MCP instructions + briefing pack), so
  new sites stop manufacturing monoliths.
- Inherited monoliths are refactored by the documented recipe (tokenise the
  look, lift structure to the layout, re-home the words as Markdown).
- The script-capable-content_type refusal (0.8.0) mechanically closes the
  stored-XSS path within raw mode; the anti-monolith doctrine remains
  editorial (a large HTML body under a permitted data content type is a design
  smell caught at close-out, not a security bug).
