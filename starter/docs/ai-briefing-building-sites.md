---
title: AI briefing - building sites
subtitle: Best practice for AI agents creating or maintaining sites on the lazysite engine - the separation-of-concerns model and the failure modes to avoid.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

A guide for AI agents (and the people directing them) creating or maintaining
sites on the lazysite engine. It captures the separation-of-concerns model the
engine is built around, and the failure modes that show up when an agent treats
site-building like generating a single web page.

This is the "how to think about a lazysite site" briefing. For the mechanics see
its siblings: [content authoring](/docs/ai-briefing-authoring),
[layouts and themes](/docs/ai-briefing-layouts),
[publishing over WebDAV / the control API](/docs/ai-briefing-publishing), and
[configuration](/docs/ai-briefing-configuration).

## The one principle: three layers that never touch

lazysite is built on a strict separation. Keep it.

| Layer | What it is | Where it lives | Who owns it |
|-------|-----------|----------------|-------------|
| **Content** | The words and structure of a page | Markdown `.md` (or `.url`) files in the docroot | Authors (human or AI), non-technical |
| **Layout** | The HTML chrome: header, nav, footer, page scaffolding, reusable features | `layout.tt` (+ `components/*.tt`) | Site builder |
| **Theme** | Colours, fonts, spacing, assets - expressed as **design tokens** | `theme.json` -> CSS custom properties, `main.css` | Designer |

The engine renders **content through a layout, styled by a theme**, and caches
the result. Three sanity checks tell you whether you have kept them separate:

1. Could a non-technical person edit the page's words without seeing any HTML or CSS?
2. Could you restyle the **entire site** by swapping the theme, changing nothing else?
3. Could you reuse the layout on a completely different page?

If any answer is "no", you have fused layers that should be apart.

## The anti-pattern: the monolithic all-in-one page

The most common mistake an AI makes is to generate **one big HTML file** with the
markup, all the CSS, and the content fused together - a "web page", not a site.

### Case study

`united.explore.lazysite.io/lazysite-assets/summit-of-summits/` - a single page
built by an assistant:

- **51 KB in one HTML file**; **16.8 KB of CSS inlined** in a single `<style>`.
- **108 `<div>`s, 10 `<section>`s** of bespoke structure.
- **47 hardcoded hex colours** (mixed in with 117 `var(--theme-*)` refs - so it
  half-knew about tokens, then hardcoded anyway).
- Fonts loaded directly from Google; nothing shared.
- Served from **`/lazysite-assets/…`** - the static-assets path. It **bypasses
  the rendering engine entirely**: no `layout.tt`, no site nav, no theme system,
  no cache pipeline, not registered in sitemap/llms/feeds.

### Why that is wrong

- **Not reusable.** Nothing in those 16.8 KB helps the next page. Every new page
  restarts from zero.
- **Cannot be restyled.** A theme swap does nothing - the look is welded into the
  page, and the hardcoded colours ignore the tokens.
- **Not maintainable or authorable.** No one can edit the words without wading
  through markup. It is invisible to the manager UI and to AI publishing rules.
- **Heavier and slower.** 16.8 KB of CSS ships on this page alone instead of once,
  cached, in a shared `main.css`.
- **Off the rails.** As a raw asset it gets no nav, no canonical URL, no feed, no
  `llms.txt` entry - it is a dead end in the site.

### What it should have been

That page is a **look** (a distinctive editorial theme) plus **content**. So:

- The distinctive visual style -> a **theme** (`summit`): its palette, fonts and
  spacing as tokens in `theme.json`; shared CSS in `main.css`.
- The page structure/hero/section rhythm -> a **layout** (or features added to an
  existing layout), reusable by any page that picks it.
- The words -> a **Markdown** page served by the engine, registered for
  discovery, restylable by swapping the theme.

Result: the same design, but reusable across a whole site, themeable,
authorable, cached once, and on the rails.

## The root cause: raw mode for ordinary pages

The monolith almost always traces back to one front-matter switch: `api: true`
(equivalently `raw: true`). That is **raw mode** - the engine serves the file's
body verbatim and skips the layout and the theme. A page built that way has to
carry its own header, nav, footer and every line of CSS, because the shared
chrome and the design tokens are never applied to it. Put ordinary pages in raw
mode and you are hand-manufacturing monoliths, one per page.

Raw mode exists for a genuinely self-contained artifact - a single bespoke
interactive widget or an embed fragment with its own content type. It is not for
content. For a normal page, write plain Markdown (title/subtitle front matter, a
prose body) and let the engine wrap it in the shared layout + theme.

Most of the "mechanical" busywork that raw-mode publishing seems to demand is a
symptom that disappears the moment a page is Markdown:

- **Rehoming embedded images** into `img/` paths - unnecessary. In Markdown you
  write `![alt](img/x.png)` and upload the image once; images are only ever
  "embedded" because something authored a self-contained HTML blob.
- **Reading the file back in ~200-line ranges so it doesn't truncate** -
  unnecessary. A Markdown page is a screen or two. And do not read the source
  back to check your work at all: **render** it - `preview_page` (server-side
  render) or a plain GET of the page URL. Chunked source re-reads are a
  workaround for a problem the approach created.
- **A page taking longer than a single upload** - it gets faster, because you
  stop rebuilding the whole design on every page.

## Build the design once; pages are then trivial

- **Once per site:** define the look as a **theme** (colour/font/spacing tokens)
  plus a **layout**, and activate them. That is where all the CSS and structure
  live - shipped once, cached once.
- **Per page:** a small `.md` - front matter, words, and `![](img/…)`. Upload the
  page (and any new image), clear the cache, verify with a rendered GET. Seconds,
  not surgery.
- **Repeated blocks** (cards, listings, galleries): a JSON data file + a loop,
  not copy-pasted HTML - so reordering can't break the markup and the data stays
  editable by anyone.

The scaling maths is the punchline. **Monolith pattern:** every page re-ships its
own copy of the design (tens of KB), every edit is big-file surgery, and a restyle
means touching every page - cost grows with the page count. **Theme + layout
pattern:** the design is defined once (O(1)), each page is a few KB of content, and
restyling the whole site is a single theme swap. As a site - or an estate of sites
- scales, those two curves diverge hard: one gets slower and heavier per page, the
other stays flat.

## Rules of thumb

1. **Content is Markdown - never raw mode.** The body of a page is prose in
   `.md`, wrapped by the engine in the shared layout + theme. Do **not** set
   `api: true` / `raw: true` on a content page: that is raw mode, which serves the
   body verbatim with no layout and no theme, and is the usual source of monolith
   pages. Reserve raw mode for a genuinely self-contained artifact. If you are
   writing paragraphs of HTML in a page, stop - it belongs in the layout.
2. **Structure is the layout.** Header, nav, footer, hero, section scaffolding
   live in `layout.tt`. Build them once; every page inherits them.
3. **Style is the theme, as tokens.** Use `var(--theme-*)`; never hardcode a
   colour or font in a page. A theme swap must be able to restyle everything.
4. **Repeated blocks are data-driven, not copy-pasted HTML.** Cards, feature
   grids, comparison tables, listings -> a JSON data file rendered with a
   `FOREACH` loop (or a `components/*.tt` component), so reordering can't break
   the markup and non-technical people can edit the data. Hand-written repeated
   `<div>`s are a smell.
5. **A new capability is a reusable layout feature, not a one-off page hack.**
   Needed a video hero? Add it to the layout, driven by a front-matter key
   (`tt_page_var`), so any page can opt in - don't bolt bespoke markup into a
   single page.
6. **Serve through the engine.** Never drop hand-authored HTML into
   `/lazysite-assets/` (or any static path) as a "page". Assets are for images,
   video, fonts, `main.css` - not documents.
7. **Minimal page-level inline HTML/CSS.** A small one-off touch is fine; the
   bulk of styling and structure belongs in theme/layout. If a page's `<style>`
   is growing past a few lines, it wants to be in the theme.
8. **Reuse before you build.** Check the theme gallery and existing layouts
   first. A new look is a new *theme*, usually on an existing layout - rarely a
   new page type.
9. **Register for discovery.** Put pages in `sitemap.xml` / `llms.txt`, emit
   feeds where relevant. Server-rendered semantic HTML is what makes lazysite
   sites findable by search and AI.
10. **Verify without polluting.** When you screenshot/QA a live site, set your
    User-Agent to the opt-out marker `lazysite-agent/<your-partner-id>` (e.g.
    `--user-agent "lazysite-agent/claude-dhcf"`). The visitor-stats classifier
    treats that token - and the legacy `claude-code-agent` - as tooling, not a
    human visitor, so your QA hits stay out of the audience numbers.

## Decision guide: page, component, layout, or theme?

- **Just words / a one-off article** -> a **Markdown page**.
- **A block that repeats with the same shape** (cards, rows, listings) -> a
  **data file + loop/component**.
- **Chrome or a feature many pages share** (nav, hero, footer, pager) -> the
  **layout**.
- **A distinctive visual identity** (palette, type, spacing) -> a **theme**
  (tokens), on top of a layout.
- **"It's basically a whole custom design"** -> still a **theme + layout**, never
  a monolithic page. If it feels too custom for that, the layout is the right
  home for the structure and the theme for the look.
- **A single self-contained interactive widget / embed fragment** -> the only
  case for **raw mode** (`api: true` / `raw: true`, with its own `content_type`) -
  never an ordinary content page.

## Refactoring an inherited monolith

When you meet a page like summit-of-summits:

1. **Separate the three strands.** Pull the prose out into Markdown; note the
   repeated structural blocks (candidates for components/data); collect the
   visual decisions (colours, fonts, spacing).
2. **Tokenise the look.** Turn colours/fonts/spacing into `theme.json` tokens;
   move shared rules into the theme's `main.css`. Replace every hardcoded hex
   with a `var(--theme-*)`.
3. **Lift structure into the layout.** Turn the hero and section scaffolding into
   layout markup / a component, driven by front-matter where it varies per page.
4. **Re-home the content.** The page becomes a short `.md` that selects the
   layout+theme and carries the words; register it for sitemap/llms/feeds.
5. **Verify and cache-clear**, then delete the raw asset page.

Done once, the design is now reusable, themeable and authorable - and the next
page in that style costs almost nothing.

## Publishing hygiene (hard-won)

- **Keep `json:` data ASCII** - the data loader drops non-ASCII (use `-` not em
  dashes, straight quotes, `->` not arrows).
- **Page `<style>` must be a single line** - a leading `#` on its own line is
  parsed as a Markdown heading and mangles the CSS.
- **Markdown is not processed inside raw block HTML** - use `<strong>` inside a
  `<div>`, not `**bold**`.
- **Clear the cache by re-activating the active layout** after edits; a nav save
  alone does not drop already-cached HTML.
- **Edit the active layout by copy-then-activate** (stage a new layout dir,
  activate it, retire the old) - the live one is write-locked.
- **One editor per file.** If a page is open in the manager it is locked;
  don't fight the lock - edit the underlying data file instead.
- **Screenshots use the `lazysite-agent/<partner-id>` UA** (see rule 10) so QA
  traffic stays out of the human analytics.

## Checklist before you call a site "done"

- [ ] No hand-authored HTML documents under `/lazysite-assets/` or other static paths.
- [ ] No content page uses raw mode (`api: true` / `raw: true`) - only true self-contained artifacts do.
- [ ] Page bodies are Markdown; structural HTML lives in the layout.
- [ ] No hardcoded colours/fonts in pages - all `var(--theme-*)`.
- [ ] Repeated blocks come from data, not copy-pasted markup.
- [ ] Shared features (hero, nav, footer) are layout features, not per-page hacks.
- [ ] The whole site restyles by swapping the theme.
- [ ] Pages are registered (sitemap/llms/feeds) and reachable from the nav.
- [ ] Verified live (with a non-human UA) and cache cleared.
