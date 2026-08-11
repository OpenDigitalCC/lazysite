---
title: "SM179 - Multilingual sites: language sets over the multi-site plane"
subtitle: "Per-language content roots linked as one site, with engine-supplied switcher data, hreflang, and a file-based translation workflow"
brand: plain
status: shipped
status-note: "SPLIT 2026-08-11: P8 (engine-chrome localisation) moved to [[SM276]], so this filing is complete rather than carrying a deferred half in its note where nobody would find it. P1-P7 shipped in 0.7.27 (2026-07-18). P8 (engine-chrome localisation - login/validation/404) deferred to a later release by design. Builds directly on SM110/SM151; P4 (content-root-relative json:/include resolution) also fixed a live multi-site wart found during the sites/providers migration."
---

::: widebox
A multilingual lazysite is a set of sibling domains - one per language - each
an SM151 content root, declared as members of one **language set**. The engine
knows the siblings, so it can supply every layout with ready-made language-
switcher data, emit correct hreflang alternates in heads and sitemaps, and
report translation coverage over the API and MCP. Translation itself stays
where lazysite keeps everything: in plain files, per root, editable by
automated tools and humans with the same file operations used for any other
content.
:::

# SM179 - Multilingual language sets

## As built (SM263, 2026-08-09)

**This is a SPEC.** It records what was designed, and two things below no longer
match what shipped. The original text is kept deliberately - correcting a spec
after the fact loses the record of what was intended and why it changed, and a
later reader asking "why not `lang_source`?" would have no answer.

For the behaviour that actually exists, read
[AI briefing - configuration](/docs/ai-briefing-configuration).

**P8 (engine-chrome localisation) SHIPPED.** Section 8 and the status-note
describe it as deferred to a later release. It landed - `_layout_strings` loads a
layout's chrome strings for the site language, English overlaid by the site
language, and the layouts briefing documents `[% t %]`.

**`lang_source` was never built.** Section 5 describes a `lang_source: true`
front-matter flag electing a set member as the translation source, and section 12
lists it under unit tests. Neither exists: the term appears nowhere in the engine.
The shipped model derives a host's language from its `lang` key and its
membership from `lang_group`, with no notion of a designated source. Nothing
depends on the flag, so its absence costs nothing except a reader looking for it.

## 1. Goal and motivation

lazysite has no language awareness today: the default template hardcodes
`<html lang="en">`, no header or registry carries language information, and
nothing links a German rendering of a site to its English original. Agents
asked to build multilingual sites will therefore improvise - most likely with
hand-rolled switchers, absent or wrong hreflang, and per-layout copy forks -
the same class of divergence the MCP announcements work is trying to prevent
for monolith pages.

The multi-site plane already solves the hard part. An SM151 content root gives
a language everything that is genuinely per-language: its own home page, nav,
sitemap, llms.txt, boxed search and render cache, on its own domain. What is
missing is small and well-defined: the engine does not know that two roots are
*the same site in different languages*, so nothing can be derived from that
relationship. This FR adds the declaration and the derivations, plus the
conventions that make translation mechanical.

Design constraints, in lazysite order:

- Reuse across languages: one layout, one theme, one structure - only
  language-bearing files differ between roots.
- Automated translation: a tool (AI agent or CAT pipeline) must be able to
  walk the source root, write a sibling root, and re-run incrementally
  without bookkeeping of its own.
- Human tuning: every translated string reachable with standard file
  editing - WebDAV, git, a text editor. No database, no translation UI.
- Discoverable: an agent connecting over MCP or the control API must be able
  to learn that a site is multilingual, which languages exist, and what the
  conventions are, without reading this document.

## 2. Relationship to prior work

```datatable
columns: Feature | What it provides | Role here
widths: 3cm | X | 5cm
bold: 1
tone: medium
---
SM110 (built) | Alias hosts with whitelisted per-host vars (`alias.<host>.<key>`). | Foundation. `lang` and `lang_group` become whitelisted alias vars.
SM151 (built) | Per-domain content roots, registries, search, cache, confinement. | Foundation. A language IS a content root; all confinement, SEO and search behaviour is inherited unchanged.
SM120 (built) | Per-page `layout:`/`theme:` pins. | Unchanged. Translated pages pin the same shared layout.
D035 components | Sections-driven layouts; copy lives in front matter and JSON, not in templates. | The reuse model depends on this authoring style; see section 5.
SM076 (MCP site management) | MCP tool surface for site operations. | Extended: multilingual facts join the announcement and tool descriptions (section 7).
```

Explicitly out of scope: `Accept-Language` redirects (front-end territory, and
a visible switcher is better practice), automatic serving of a fallback
language for missing pages (a silently mixed-language site is worse than an
honest switcher that omits the missing entry), and any machine translation in
the engine (translation is content work, done in files by tools or people).

## 3. Model

A **language set** is a named group of hosts. Each member host declares the
same `lang_group` value and its own `lang`. One member - by convention the
base/primary host, or an explicit flag - is the **source language**, the tree
translators work from.

```
<docroot>/
  lazysite/                    # shared plane, as SM151 - ONE of each
    layouts/studio/            #   shared layout, language-neutral
      strings/en.json          #   chrome strings per language (P5)
      strings/de.json
  sites/
    providers/                 # en - source language root
      index.md  compare.md  data/nav.json  data/pricing.json  assets/
    providers-de/              # de - sibling root, SAME file layout
      index.md  compare.md  data/nav.json  data/pricing.json  assets/
```

The invariant that makes everything below cheap: **sibling roots mirror the
source root's file layout**. `<root>/compare.md` in one language corresponds
to `<root>/compare.md` in every other; a missing file means "not translated
yet". No manifest, no mapping table - the tree is the mapping.

## 4. Configuration reference

Two new whitelisted vars on the SM110 alias plane, plus base-conf defaults:

```
# base (also the source language when it carries the lang_group)
lang: en
lang_group: providers

alias_hosts: providers.example.com, de.providers.example.com
alias.providers.example.com.content_root: sites/providers
alias.providers.example.com.site_url: https://providers.example.com
alias.providers.example.com.lang: en
alias.providers.example.com.lang_group: providers

alias.de.providers.example.com.content_root: sites/providers-de
alias.de.providers.example.com.site_url: https://de.providers.example.com
alias.de.providers.example.com.lang: de
alias.de.providers.example.com.lang_group: providers
```

`lang` is a BCP 47 tag, used verbatim in `<html lang>`, `Content-Language`
and hreflang. `lang_group` is an opaque set name; hosts sharing it are
siblings. The first declared member with a given group is the source language
unless a member sets `lang_source: true`. A host with `lang` but no
`lang_group` is simply a monolingual site that knows its language - P1 works
alone. Zero behaviour change when both are unset.

## 5. Reuse model - what is shared, what is translated

The split falls naturally out of the existing architecture:

```datatable
columns: Layer | Shared or per-language | Notes
widths: 4cm | 3.5cm | X
bold: 1
tone: medium
---
Layout + components | Shared (one copy) | Language-neutral by design; chrome strings externalised via P5.
Theme + assets | Shared (one copy) | Colour and type carry no language.
Page front matter (`sections:`) | Per-language | The translatable strings ARE the front matter values; structure keys stay identical, so a diff shows exactly the strings.
Body Markdown | Per-language | Translated wholesale.
Data JSON (`nav.json`, `pricing.json`...) | Per-language | Same schema every root; values translated, keys and shape untouched.
Images | Shared by default | A root overrides an image only when it carries text; croot-relative resolution (P4) makes the override transparent.
Chrome strings | Shared file per language | `layouts/<layout>/strings/<lang>.json` (P5).
```

This is why P4 matters: with `json:` and `::: include` resolving against the
requesting host's content root first, **page sources are byte-identical in
structure across roots** - `tt_page_var: pagenav: json:/data/nav.json` works
unchanged in every language. Without P4 every translated page must carry
docroot-absolute paths pointing into its own root (the exact wart hit during
the sites/providers migration), which breaks the copy-the-folder translation
model.

## 6. Translation workflow

The unit of translation is the content root. The workflow the design must
support, end to end:

Automated pass
: A translation agent lists the source root (WebDAV PROPFIND or filesystem),
  translates each file's language-bearing values - front-matter strings, JSON
  values, Markdown bodies; never keys, paths, or structure - and PUTs the
  result to the sibling root at the identical path. Because files are small,
  plain and schema-stable, this is prompt-friendly and CAT-tool-friendly
  alike.

Incremental re-runs
: `lang_status` (P6) compares each sibling root against the source root and
  reports, per file: `missing`, `stale` (source modified after the
  translation), or `current`. The comparison is mtime-based by default; a
  page may carry `translated_from: <content-hash>` in front matter for exact
  staleness, written by tools that want it. The agent re-translates exactly
  the reported set - no bookkeeping of its own, safe to re-run.

Human tuning
: A reviewer edits the sibling root's files directly - WebDAV, git checkout,
  or the manager's editor - exactly as they would edit any lazysite content.
  Editing a translated file marks it `current` (its mtime advances); nothing
  needs to be told. The `.brief` convention works per root for briefing
  translators and logging passes.

Coverage visibility
: The same `lang_status` data renders as a read-only manager view per
  language set (translated / stale / missing counts per root), giving the
  operator the health of the set at a glance.

## 7. Deliverables

P1 - `lang` awareness (trivial)
: Whitelist `lang` on the alias plane; expose `[% site_lang %]` and
  `[% page_lang %]` (front-matter override, joining title/subtitle/author);
  default template emits `<html lang>` from it; add `Content-Language`
  response header. Useful standalone for every monolingual non-English site.

P2 - the language set + `languages` TT var (the substantive feature)
: Whitelist `lang_group`; resolve siblings from the conf. For each rendered
  page expose `[% languages %]`: an ordered list of
  `{ lang, url, current, exists }` where `url` is the sibling's `site_url`
  plus the same croot-relative path and `exists` is a file-stat on the
  counterpart. Any layout renders a switcher from it in three lines of TT;
  the default template gains a minimal one. Also emit
  `<link rel="alternate" hreflang>` pairs (plus `x-default` on the source
  language) in the default template head from the same data.

P3 - sitemap alternates
: Per-domain sitemaps (SM151 P3) gain `xhtml:link` hreflang alternates for
  entries whose counterparts exist. This is the piece hand-rolled multilingual
  sites essentially never get right.

P4 - content-root-relative `json:` and `::: include`
: `resolve_json` and the include converter try `<croot>/<path>` before
  `<docroot>/<path>`. Confinement unchanged (both are inside the docroot;
  croot is already confined by SM151 S1/S2). Independently valuable as a
  multi-site fix.

P5 - layout strings autoload
: If `layouts/<layout>/strings/<site_lang>.json` exists, load it into
  `[% t %]`, overlaying `strings/en.json` (or the source language) so missing
  keys fall back rather than vanish. Layouts localise chrome as
  `[% t.footer_credit %]`. Path is layout-dir-confined; absence of the
  directory changes nothing.

P6 - `lang_status` API + manager view
: Read-only control-API action: for a language set, per sibling root, the
  file-level `missing`/`stale`/`current` report of section 6, plus totals.
  Manager gains the per-set coverage view. Optional exact staleness via
  `translated_from:` hashes.

P7 - MCP/API discoverability
: See section 8 - the agent-facing surface is a deliverable, not an
  afterthought.

P8 - engine chrome localisation (later, separate release)
: `/login`, form validation messages and the 404 page currently render
  engine-emitted English. A small per-lang string table keyed off
  `site_lang`. Deliberately last: a translated site with an English login
  page is an acceptable v1, and this touches security-sensitive surfaces
  that deserve their own review.

## 8. What the site agent needs, to build multilingual sites

Written from the implementing agent's chair: the following must be learnable
at connection time, or the conventions above will drift agent by agent.

whoami / token introspection
: The partner `whoami` response gains `lang`, `lang_group`, and a `siblings`
  list (`host`, `lang`, `content_root`, `source: true|false`) when the bound
  site is a language-set member. An agent then knows immediately that a
  translation counterpart exists and where its files live.

MCP announcement (initialize instructions)
: One paragraph in the connector's instructions when the instance has a
  language set: the invariant (sibling roots mirror the source layout), the
  rule (translate values, never keys/paths/structure), the pointer
  (`lang_status` tells you what needs doing), and the prohibition (do not
  hand-build switchers or hreflang - the layout gets `languages` from the
  engine). This mirrors the standing MCP-announcement guidance: state the
  standard practice before the agent invents one.

Tool/API surface
: `lang_status` callable with the partner token (read-only). Content tools
  (WebDAV, `bind_*`) work per root already - no change needed beyond the
  descriptions noting that a language-set site's paths are croot-relative
  and that P4 makes data references portable across roots.

Partner brief template
: The operator-issued partner brief gains an optional language-set block
  (group name, member hosts and langs, source language) so a delivery agent
  is briefed on the set even before first connection.

## 9. Security and confinement

No new write surface. `lang`/`lang_group` ride the existing SM110 whitelist
(operator-only conf, already deny-listed for tokens). `languages` and
hreflang derive from conf plus file-stats inside already-confined roots.
`lang_status` is read-only and reveals only file paths a WebDAV-capable
partner can already list. Strings autoload reads only inside the layout
directory. P4 narrows resolution towards the more-confined root first -
strictly no wider than today.

## 10. Acceptance gates

- Unit: conf parsing (`lang`, `lang_group`, `lang_source`, malformed tags
  rejected), sibling resolution order, `languages` var construction with
  missing counterparts, strings overlay fallback.
- Integration: two-root language set end to end - `<html lang>`,
  `Content-Language`, switcher URLs, hreflang head links, sitemap
  alternates present for translated pages and absent for untranslated;
  P4 croot-first resolution with a docroot-level decoy file (adversarial,
  in the style of t/integration/17-multisite-content-root.t).
- API: `lang_status` report against a fixture set with one missing and one
  stale file; token capability check.
- Regression: all behaviour identical when `lang`/`lang_group` unset.
