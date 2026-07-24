---
title: AI briefing - build a site from a Figma design
subtitle: The dual-MCP method for taking a Figma design into a lazysite site - extract the tokens and structure over the Figma MCP, translate them into a theme and layout, publish through lazysite.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

You are an AI agent in a session with TWO connections live at once: the
**Figma MCP server** (the design source) and a **lazysite** connection
(the destination - MCP, or WebDAV + the control API). The user has said
"build this site from my Figma design" or "restyle the site to match
this frame". This briefing is the method for bridging the two: read the
design over the Figma MCP, translate it into lazysite's separation of
concerns, and publish it.

Read [AI briefing - building sites](/docs/ai-briefing-building-sites)
first - it is the governing method and this doc applies it to one
external source. For the staging mechanics (WebDAV, activation, the
cache mirror) see
[AI briefing - layouts and themes](/docs/ai-briefing-layouts); this doc
links to it rather than repeating it.

## The locked context - read this before you start

- **Ingestion is dual-MCP.** You bridge the Figma MCP (source) and
  lazysite (destination) yourself, in one session. There is no
  lazysite-side Figma fetcher and there are no stored Figma credentials
  anywhere in the engine. Nothing on the lazysite side reaches out to
  Figma - you are the bridge.
- **Token extraction is free on every Figma plan.** The Figma MCP tool
  `get_variable_defs` returns the design's variables and styles (colour,
  spacing, typography) with names AND values on all plans. The Variables
  REST API is Enterprise-gated; the MCP path is not. This is why the
  method is MCP, not REST.
- **You add no code and no credentials.** This is a translation task
  done entirely through tools that already exist on both sides.

## Preconditions

**The Figma remote MCP is link-based.** It works from a Figma file URL,
or a "copy link to selection" URL for a specific frame. It does not work
from a design *named* in prose. If the user has only named a design,
**ask for the link** (the file URL, or a copy-link-to-selection URL for
the frame they mean) before doing anything else.

**Run `whoami` on BOTH connections first.** On the Figma MCP, `whoami`
confirms the design identity you are reading. On lazysite, `whoami`
confirms the capabilities you hold - you will need `manage_themes` to
write theme files, `manage_layouts` to stage a layout, and
`manage_content` to publish pages. If a capability is missing, ask the
operator to grant it now rather than discovering the `403` mid-build.

## Extraction sequence

Work outside-in: orient on the whole, then pull detail only from the
frames that matter. Do not lead with the heavy full-context tool.

### 1. Orient - `get_metadata`

Call `get_metadata` on the file or frame link first. It returns a sparse
XML outline: layer IDs, names, types, positions and sizes - the shape of
the design without its weight. Use it to identify the frames that matter
(the page frames, the hero, the repeated card, the nav) and to get their
IDs for the next steps. **Outline first, drill in.** Avoid running the
full-context tool (below) against a large frame before you know what is
in it.

### 2. Tokens - `get_variable_defs`

Call `get_variable_defs` on each relevant frame. It returns the
variables and styles that frame uses - colour, spacing, typography -
with their names AND their values. **This is the design-token
extraction**, and it is the core of the whole method: these names and
values become the theme's tokens. Call it **per key frame**, not once
against a huge selection - a scoped call returns the tokens that frame
actually uses, which is what you want to map.

### 3. Fidelity reference - `get_screenshot`

Call `get_screenshot` on each page-level frame. The screenshot is the
**visual ground truth** you check the rebuild against: layout
relationships, hierarchy, the visual weight of one element against
another. You reproduce its *relationships*, not its pixels (see the
translation section) - keep one per page frame to compare against your
rendered preview at the end.

### 4. Structure - `get_design_context` (use with care)

`get_design_context` returns generated code for a frame. Two hard rules:

- **It defaults to React + Tailwind.** If you call it, **explicitly
  request plain HTML + CSS**. Never accept React or Tailwind output as
  build input - it does not belong anywhere near a lazysite theme.
- **Treat the output as a STRUCTURAL REFERENCE only** - what wraps what,
  the reading order, which blocks repeat - never as code to transplant.
  Lifting its markup into a page is exactly the **monolithic all-in-one
  page** anti-pattern described in
  [building sites](/docs/ai-briefing-building-sites): one big HTML file
  with structure, style and content fused, off the rails. That failure
  mode applies here with full force. Read the structure, then build it
  the lazysite way.

For most builds **you do not need this tool at all**: metadata (the
shape) plus screenshots (the look) plus tokens (the values) is enough to
rebuild faithfully. Reach for it only when a complex frame's nesting is
genuinely unclear from the outline and screenshot - and even then, only
to *understand* the structure.

### 5. Design system - `search_design_system` / `get_libraries` (optional)

If the user references a shared library ("use our design system", "the
components from the brand library"), call `search_design_system` and
`get_libraries` to pull the component naming and token conventions. This
gives you the canonical names the design system uses, so your theme
tokens line up with the source's vocabulary rather than being invented.
Skip it when no shared library is in play.

## Translation to lazysite - the design-transfer principle

This is the half of the job that matters, and it has one governing
principle: **identity transfers as tokens; rhythm and scale are rebuilt
in CSS.** You are not exporting a design - you are re-expressing it in
lazysite's separation of concerns. **Pixel-reproduction is an explicit
anti-goal.** Chasing it produces the fused monolith described in
[building sites](/docs/ai-briefing-building-sites) - the single-file
page with dozens of hardcoded colours that a theme swap cannot touch.
Transfer the identity; rebuild the rhythm.

### Colours -> theme tokens

Map the extracted colour variables onto the **target layout's token
vocabulary**. Discover that vocabulary first:

- If the lazysite side offers the `theme_tokens` MCP tool, call it to
  read the layout's declared token names.
- Otherwise read the layout's default theme `theme.json` for its
  `config` groups, and `grep var(--theme-` in its `main.css` to see
  which tokens the CSS actually consumes.

Then map:

- **Role-named source variables** (`text/muted`, `brand/primary`,
  `surface/raised`) map near-mechanically onto the layout's role tokens.
- **Value-named source variables** (`grey-600`, `blue-500`) carry no
  role, so you must infer the role from the screenshots - which element
  is that grey actually *on*? Assign the role, and **note the assumption
  you made** so the user can correct it. Do not guess silently.

The output is `theme.json` tokens (`config.colours.*` etc.), consumed as
`var(--theme-colours-*)` in the theme CSS - never a hardcoded hex in a
page.

### Fonts -> the fonts group, BUNDLED

Fonts map to the theme's fonts group (`body` / `heading` / `code`) and
**must be bundled** under the theme's `assets/` directory. **Never a CDN
link** - the same rule as everywhere else in lazysite (the write path
refuses external font links; see
[building sites](/docs/ai-briefing-building-sites)). If the design uses
a Google font, **fetch the font files and bundle them** (OFL/Apache
licensed) and reference them from the theme CSS with an `@font-face`
pointing at the bundled asset. A design that names `Inter` does not
become a `fonts.googleapis.com` link - it becomes bundled files.

### Spacing, type scale, line-heights -> authored CSS

**Do not look for theme slots for these - there are none, by design.**
lazysite's tokens cover colours and font families; spacing rhythm, the
type scale and line-heights are **authored CSS** in the theme's
`main.css`, informed by the screenshots. Read the proportions off the
screenshot and write CSS that reproduces the *relationships* (this
heading is roughly twice the body, sections breathe at about this
rhythm) - **do not copy Figma's pixel values numerically**. The
screenshot is the reference; the CSS is a rebuild, not a transcription.

### Structure -> adapt the nearest layout

Do not author a layout from scratch. Call `list_layout_catalogue` to see
what exists, pick the nearest match, and **copy-and-stage** it per
[layouts and themes](/docs/ai-briefing-layouts). The Figma frames tell
you WHICH structural features that layout needs - a hero, a card grid, a
sidebar - so you adapt the copy to add them. **Repeated blocks** in the
design (a row of cards, a gallery, a listing) become a **JSON data file
+ a `FOREACH` loop**, not copy-pasted markup - rule 4 in
[building sites](/docs/ai-briefing-building-sites).

### Content -> Markdown pages

The text strings on the design's page frames become **Markdown pages** -
title/subtitle front matter and a prose body, one page per page frame.
Where the design carries lorem or placeholder text, **flag it to the
user** and leave it out of the published page; do not ship lorem as real
content.

## Deployment

Once the theme, layout and pages are ready, publish through whichever
lazysite channel you are on. **The staging mechanics live in
[layouts and themes](/docs/ai-briefing-layouts) - that is the single
source of truth; this is only a pointer to the right sequence.**

- **MCP:** `create_theme` to scaffold the theme, `write_file` for its
  files and the layout copy and the pages, then `activate_theme` and
  `activate_layout`. See the
  [AI connector tools reference](/docs/ai-connector-tools) for the tool
  surface and the staging rules in
  [layouts and themes](/docs/ai-briefing-layouts).
- **WebDAV + control API:** follow the staging sequence in
  [layouts and themes](/docs/ai-briefing-layouts) - `MKCOL` the new
  layout dir and its theme dir, `PUT` the files, preview a page via a
  per-page `layout:` override, then `layout-activate` and
  `theme-activate` over the control API (which also clears the cache).
  Remove the preview overrides once activated.

Either way, **you activate it yourself** - a self-serve action under
your capabilities, not an operator hand-off.

## Checklist before you call it done

- [ ] Every colour is a `var(--theme-*)` token mapped from the design -
      no hardcoded hex in any page.
- [ ] Fonts are bundled under the theme's `assets/` - no CDN / Google
      font link anywhere.
- [ ] Each page-frame screenshot has been compared against the rendered
      `preview_page` output - the relationships match.
- [ ] No React or Tailwind residue anywhere - the theme is plain
      HTML + CSS.
- [ ] Repeated blocks are data-driven (JSON + `FOREACH`), not
      copy-pasted markup.
- [ ] Spacing / type scale live as authored CSS in `main.css`, not
      pixel-copied and not sought as theme slots.
- [ ] Any inferred role assignments (value-named colours, placeholder
      content) are noted to the user.
- [ ] The cache is cleared (re-activate) and the render verified.
- [ ] QA hits used the `lazysite-agent/<partner-id>` User-Agent so they
      stay out of the audience numbers.

## Related

- [AI briefing - building sites](/docs/ai-briefing-building-sites) - the
  governing method and the monolith anti-pattern.
- [AI briefing - layouts and themes](/docs/ai-briefing-layouts) - the
  staging, activation and theme-asset mechanics.
- [AI connector tools reference](/docs/ai-connector-tools) - the
  lazysite MCP tool surface.
- [Integrations index](/docs/integrations) - the other sanctioned
  external-source integrations.
