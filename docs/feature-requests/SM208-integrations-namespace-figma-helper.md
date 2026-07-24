---
title: "SM208 - Integrations docs namespace + Figma design-source helper"
subtitle: "A /docs/integrations/ namespace (index + per-tool helper) documenting how an agent brings an EXTERNAL source into lazysite through the sanctioned channels. First entry: figma.md - the dual-MCP (Figma MCP source + lazysite MCP destination) extraction-and-translation method. Docs + registration only; no new transport, no credentials, no new MCP tools."
brand: plain
status: candidate
status-note: "PROPOSED 2026-07-24 from the integrations briefing (lazysite/inbox/integrations-briefing.md). Audited: nested docs ship + register correctly (the /docs/features/ subdirectory precedent), describe_capabilities recipes are cheap to extend, validate_page/preview_page work on nested paths. SUPERSEDES SM207 (absorbs its design-transfer content). Two audit corrections noted below. Completes the Figma-ingestion tool line (SM203/204/205)."
---

# SM208 - Integrations docs namespace + Figma design-source helper

## Why

lazysite proves that an AI translating a design SEMANTICALLY into themes/layouts
(identity as tokens, rhythm rebuilt in CSS) beats pixel-export. The engine side of
that is now built (SM204 `theme_tokens`, SM205 `create_theme`, SM203 declared
`tokens`); what is missing is the *method* an agent follows to get an external
design IN. This ships that as documentation.

**Locked decision (do not revisit): dual-MCP, not REST.** The agent connects the
**Figma MCP server** (source) and the **lazysite** connection (destination) in one
session and bridges them. `get_variable_defs` returns the design's variables +
styles free on all Figma plans, where the Variables REST API is Enterprise-gated.
So there is **no lazysite-side Figma fetcher, no stored Figma credentials, no new
transport** - the deliverable is documentation that makes the bridge reliable and
discoverable.

## What

### 1. `/docs/integrations/` namespace + index

`starter/docs/integrations/index.md` - a short router: what an integration briefing
is (taking an external source - a design tool, editor, CMS export - into lazysite
through sanctioned channels), the list of available integrations with one-liners,
and a pointer to `ai-briefing-building-sites` as the governing method.

A directory (not more flat `ai-briefing-*` files) because integrations are
per-external-tool and will grow (hedgedoc, wordpress-import anticipated), and it
gives each a predictable slug `/docs/integrations/<name>`.

### 2. `starter/docs/integrations/figma.md`

The helper doc, for an agent in a session with BOTH the Figma MCP and a lazysite
connection. Content per the briefing, citing the Figma tool names verbatim
(`get_metadata`, `get_variable_defs`, `get_screenshot`, `get_design_context`,
`search_design_system`, `get_libraries`, `whoami`):

- Preconditions (link-based Figma MCP; run both `whoami`s first).
- Extraction sequence: ORIENT (`get_metadata`, outline first) -> TOKENS
  (`get_variable_defs`, names + values, per key frame) -> FIDELITY
  (`get_screenshot` per page frame) -> STRUCTURE (`get_design_context` used with
  care: demand plain HTML/CSS, treat as structural reference only - the monolith
  anti-pattern applies; skippable for most builds) -> DESIGN SYSTEM (optional).
- Translation to lazysite: identity -> tokens (map onto the layout vocabulary via
  `theme_tokens`, or a `theme.json` + `var(--theme-` grep); role-named maps
  mechanically, value-named needs role assignment from the screenshots); fonts ->
  bundled (never a CDN); spacing/type-scale -> authored CSS (no theme slots by
  design); structure -> adapt the nearest layout (copy-and-stage); content -> pages.
- Deployment: a pointer each to the MCP path (`create_theme`/`write_file`/
  `activate_theme`/`activate_layout`) and the WebDAV + control-API staging
  sequence - do NOT duplicate the staging mechanics; link `ai-briefing-layouts`.
- A "done" checklist in building-sites style.

Absorbs SM207's design-transfer principle (see supersession below). Target
8-12 KB, matching the `ai-briefing-*` register.

### 3. Discoverability wiring

- `register: [sitemap.xml, llms.txt]` front matter on both new pages (llms.txt is
  the primary agent-discovery surface).
- Cross-links: `ai-briefing-building-sites` ("Who this is for" -> importing an
  external design); `ai-briefing-layouts` (Related -> integrations index);
  `onboard-ai-agent` step 4 (a "Build from a design" bullet); the docs nav.
- describe_capabilities recipe: add a `build-from-figma` task pointing at the doc.

## Feasibility (audited) - two corrections to the briefing

1. **Nested docs ship + register - confirmed.** `dist/config/classification.json`
   maps `^starter/docs/(.+)$` -> `{DOCROOT}/docs/$1` (code bucket), path-agnostic;
   `starter/docs/features/{authoring,configuration,development}/` already ship as
   nested dirs. The registry generators build each page URL from its path
   (`.md` stripped) and the `llms.txt.tt`/`sitemap.xml.tt` templates iterate the
   registered set, so `/docs/integrations/figma` registers with no special
   handling.
2. **describe_capabilities recipes are cheap.** They are a declarative `@TASKS`
   array in `lib/Lazysite/Capabilities.pm` (~179-235); a `build-from-figma` entry
   (`id`/`title`/`requires`/`steps`) is a ~10-line addition, no logic change. So
   INCLUDE it (the briefing left it conditional).
3. **CORRECTION - `onboard-ai-agent.md` is already registered.** The briefing's
   "fix in passing" (item 3.3: empty `register:`) is stale - the page already
   carries `register: [sitemap.xml, llms.txt]`. No fix needed; just add the Figma
   bullet. Verify at implementation.
4. **Nav:** `starter/nav.conf.example` has a `Discover` group (Authoring / All
   features / API); add `Integrations | /docs/integrations` there (read_nav first
   on a live site and follow its actual shape).
5. **Verification tools confirmed:** `validate_page` and `preview_page` (MCP) both
   accept an arbitrary nested path.

## Supersedes SM207

SM207 proposed a single flat `ai-briefing-design-transfer.md` covering the same
design-transfer method. This namespaced approach is more scalable and is the
briefing's explicit direction. SM207 is retired; its content (identity-as-tokens,
role-based naming, the rebuild-don't-copy principle, the what-NOT-to-ask list)
becomes the translation section of `figma.md` and the principle paragraph of the
integrations index. SM207's status-note is updated to point here.

## Scope control (from the briefing)

Do NOT: build a Figma REST client / credential storage / a sources registry; add
MCP tools (the only code touch is the trivial recipe entry); duplicate staging
mechanics into figma.md (link `ai-briefing-layouts`); write integration docs for
unverified tools (the index gains entries as integrations exist).

## House style

Author both docs via the pandoc-markdown skill, matching the `ai-briefing-*`
register (direct, imperative, failure-modes named). The Figma tool facts are
verified as of 2026-07-24; cite tool names exactly and invent no parameters.

## Verification

- `validate_page` clean on both docs; `preview_page` renders them.
- The generated `llms.txt` and `sitemap.xml` both contain `/docs/integrations/index`
  and `/docs/integrations/figma`.
- The `build-from-figma` recipe appears in `describe_capabilities`.
- Existing suite green.
