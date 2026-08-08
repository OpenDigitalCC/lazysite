---
title: "SM228 - The raw-page content-type downgrade is silent, and 'raw' points the wrong way"
subtitle: "A raw or api page declaring text/html is downgraded to text/plain at serve time. The security reasoning is right; the author is told nothing, and the key's name invites exactly the design that fails."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit e2bbe18). Raised 2026-08-06 from the Golden Link partner review, which proposed raw: true to serve a single-file HTML application - a design that would have been accepted at write time and silently downgraded at serve time. Implementation targeted for the next release. Does NOT propose weakening ADR 0006."
---

# SM228 - the raw-page downgrade is silent

## Why

`peek_content_type` in `lazysite-processor.pl` carries a deliberate control
(ADR 0006): a page marked `raw: true` or `api: true` that declares
`text/html`, `application/xhtml+xml` or `image/svg+xml` has its content type
downgraded to `text/plain`.

The reasoning is sound and should not change. A raw page bypasses the layout and
all escaping, so a partner holding only `manage_content` could otherwise store
script that runs in every visitor's browser. Combined with the
`X-Content-Type-Options: nosniff` header the response already carries, the
browser cannot execute it.

Two problems sit on top of a correct control.

**The author is told nothing.** The downgrade happens at serve time and writes a
`WARN` to the site log. The write that created the page succeeded. `audit_site`
does not flag it. `validate_page` does not flag it. The author discovers it by
loading the page and seeing their markup as text, at which point the cause is
not obvious - the page is present, the front matter is as written, and nothing
refused anything.

**The key's name invites the mistake.** `raw: true` reads as "serve this
verbatim". A partner needing verbatim HTML reaches for it, which is precisely
the design the control blocks. In August 2026 one did:

> Both apps are one HTML file, roughly 125 KB, with inline CSS and JS. They must
> be served byte-for-byte with `Content-Type: text/html`, never run through the
> Markdown or layout pipeline, and never wrapped in a theme.

The correct answer - publish it as a static file, which lazysite serves
byte-for-byte today and which accepts `.html` and `.js` through every authoring
channel - is a different mechanism entirely, and nothing connects the two.

## What to build

### 1. Refuse at write time rather than downgrade at serve time

A page that will be downgraded is a page whose author has misunderstood
something. Catching it at the write is cheaper for everyone than catching it on
first load.

`Lazysite::Manager::Common::raw_html_page_refusal` already exists and already
encodes this check. Confirm it is applied on every write path - manager API,
MCP, WebDAV - and that the refusal message names the alternative rather than
only the prohibition: *"a raw page cannot declare an HTML content type; serve
HTML through a layout, or publish it as a static file, which is served
byte-for-byte."*

The serve-time downgrade stays as the backstop for pages written before the
refusal existed, or by any path that bypasses it.

### 2. Surface it in `validate_page` and `audit_site`

An existing page in this state should be reported, with the same remedy text. A
site upgrading into the refusal needs a way to find its affected pages that does
not involve loading each one.

### 3. Document the three modes together

`/docs/frontmatter` should carry one short section stating what `raw:`, `api:`
and a static file each do, side by side, with the HTML case called out
explicitly. The distinction is not currently drawn anywhere a reader looking for
"serve this file unchanged" would find it.

### 4. Consider the name

`raw:` means "the Markdown pipeline runs, no layout" - which is not raw. Renaming
a shipped front-matter key is a compatibility event and should not be undertaken
lightly; the options are to leave it and rely on documentation, or to introduce
a clearer alias and treat `raw:` as the deprecated spelling. Recommend
documentation first and revisit only if the confusion recurs after SM225 lands.

## Verification

- A write that would produce a downgraded page is refused, on every authoring
  channel, with a message that names the static-file alternative.
- `validate_page` reports an existing page in this state.
- The serve-time downgrade continues to fire for anything that reaches it, and
  its test coverage is unchanged.

## Not in scope

- Any weakening of ADR 0006. The downgrade is a mechanical enforcement of a
  stated architectural decision and this request strengthens it by moving the
  detection earlier.
- Permitting HTML from a `manage_content`-only account by any route.
