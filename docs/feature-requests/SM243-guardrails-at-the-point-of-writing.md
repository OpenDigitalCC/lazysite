---
title: "SM243 - Warn at the moment of writing, not only in the briefing"
subtitle: "An agent reads the briefings once, then works through a tool surface that cheerfully accepts the thing the briefing warned against. Put the warning where the mistake is made."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-08 as the pattern behind several repairs on MCP-built sites. Extends the SM228 approach (detect at write time, not at serve time) to the cases that are not refusals but warnings. Warn-only throughout - none of these should reject a write."
---

# SM243 - guardrails at the point of writing

## Why

The reporting agent's diagnosis of its own repair work:

> The briefings are good - the problem is that an agent reads them once and then
> works through a tool surface that cheerfully accepts the thing the briefing
> warned against.

`write_file` and `create_page` already warn about unbound forms, which proves the
mechanism and the appetite. Three more patterns cost real repair time and are all
detectable at the moment of writing.

## The patterns

### Raw-mode monoliths instead of content + layout + theme

united.explore's `/index`, `/vision` and `/apply` were `.md` files carrying
`api: true` + `content_type: text/html` and a whole hand-written HTML document
with inline CSS. edge.explore has the same shape. theunited.fund's homepage is
310 lines of raw HTML sections inside a `.md`.

The layout is bypassed, the processor mangles the block tags, and the page cannot
be maintained as content. SM228 already refuses the specific case that would be
downgraded at serve time; this is the broader shape that is merely *wrong* rather
than broken.

**Warn when** a page body contains `<!DOCTYPE`, `<html`, `<head`, or a `<style>`
block - and when `api: true` is set on a page whose body is clearly a document
rather than a data artifact. Name the alternative, as SM228's refusal now does:
content in Markdown, styling in the theme, structure in the layout, and a
self-contained HTML file as a static file if that is genuinely what is wanted.

### Page-baked chrome, plus a theme that hides the layout's

theunited.fund carried its own `<nav>` and `<footer>` in page content, and its
theme carried `display:none!important` on `.site-header` / `.site-footer` to stop
them doubling. The consequence was worse than cosmetic: **the site navigation
became unreachable** - the operator set nav items that never appeared anywhere.

Two halves, each detectable:

- `validate_page` flags `<nav>` or `<footer>` in page content.
- `create_theme` flags a theme hiding the layout's own chrome selectors.

Either alone is a smell; together they are the failure that hid the navigation.

### Retired URLs left to 404

Twenty legacy `.shtml` URLs were dropped by a conversion on cloudient.net and
recovered by hand. This is now a standing operator rule, which means it is a rule
being enforced by a person on every conversion.

**`rename_page` / `move_file` should offer to write the `aliases:` entry** on the
successor page - the rule says every old URL gets one at conversion time, and the
tool is standing exactly where that knowledge exists.

## What this is not

**Not refusals.** Every item here is warn-only. A hand-written HTML page is
sometimes the right answer and the platform should not pretend otherwise; the
complaint is silence, not permissiveness. SM228's refusal is different in kind -
it catches a page that would be served as plain text, which is always broken.

**Not a linter for taste.** Each warning names a concrete consequence that was
actually paid for: mangled tags, unreachable navigation, dead URLs.

## Verification

- Writing a page whose body contains a full HTML document warns, names the
  consequence, and still writes.
- `api: true` on a document-shaped body warns.
- `validate_page` reports `<nav>` / `<footer>` in content.
- `create_theme` reports a theme hiding layout chrome selectors.
- A rename offers the alias, and declining it is possible and silent.
- No existing write becomes a refusal.

## Not in scope

- Refusing any of these.
- Detecting hand-written form HTML, which is already warned about.
- The static-file route for genuine single-file applications, which SM228
  documents and which these warnings must name rather than discourage.
