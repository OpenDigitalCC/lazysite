---
title: AI briefing - layouts and themes
subtitle: Guide for AI assistants helping users author or modify a lazysite layout or theme.
register:
  - sitemap.xml
---

## Who this is for

This briefs an AI assistant working on the visual layer of a
lazysite site - the layout template (`layout.tt`) and its
themes. For content, see
[AI briefing - authoring](/docs/ai-briefing-authoring). For
configuration, see
[AI briefing - configuration](/docs/ai-briefing-configuration). For the
content/layout/theme separation this all rests on, see
[AI briefing - building sites](/docs/ai-briefing-building-sites).

## Terminology (D013)

**Layout**: the Template Toolkit file (`layout.tt`) that wraps
every page. Provides `<head>`, header, navigation, footer.
Installed at `lazysite/layouts/NAME/layout.tt` with optional
`lazysite/layouts/NAME/layout.json` metadata.

**Theme**: colours, fonts, spacing, and assets that sit on top
of one or more layouts. Installed nested at
`lazysite/layouts/LAYOUT/themes/THEME/`. Declares compatibility
in `theme.json`'s `layouts[]` array.

**Manager UI**: has its own internal template at
`lazysite/manager/layout.tt`. Outside the layout+theme system.
Do not modify unless explicitly asked.

On-disk example:

    lazysite/
      layouts/
        default/
          layout.tt
          layout.json
          themes/
            odcc/
              theme.json
              main.css
              assets/
      manager/
        layout.tt
        assets/manager.css
    lazysite-assets/
      default/
        odcc/
          main.css
          assets/

## Front-matter variables arrive ALREADY ESCAPED - never add `| html`

**`page_title`, `page_subtitle`, `page_meta_title`, `page_meta_desc` and
`page_author` are HTML-escaped before your template sees them.** Applying
`| html` escapes them a second time.

This is deliberate and it is a security decision, not a convenience one
(SEC-2026-07 H5): author-controllable front matter is escaped at the single
point it enters the stash, so **every** layout emits it safely - including
third-party layouts nobody here can edit, and including a layout that forgets to
filter. Escaping at the point of construction is the half that fails safe; the
engine knows where a value came from and a template does not.

The cost of that choice is this rule, and the rule was never written down. So:

<!-- lint-48: counter-example follows. The second line shows the WRONG form, so
     the check that keeps every other example correct skips between these
     markers. -->

```
<meta name="description" content="[% page_meta_desc %]">          correct
<meta name="description" content="[% page_meta_desc | html %]">   double-escaped
```

<!-- lint-48: end counter-example -->

An apostrophe in the second form reaches search engines as `&amp;#39;`, which
renders as the literal text `&#39;`. "a client's brief", "what's included",
"we're hiring" - apostrophes are ordinary in English copy, and a meta
description is exactly where marketing copy goes. It is read by search engines,
social cards and AI clients, and by almost nobody during review, so a site can
serve it mangled for months.

`| html` on these five is always wrong. On any value you construct yourself in
the template, it is right.

## The `<head>` contract

**A layout must render `<title>` from `page_meta_title` and its description from
`page_meta_desc`.** Both are always set, so there is no fallback to write.

An author sets `meta_title` or `meta_desc` in a page's front matter to control
what search engines and social cards show, separately from the heading on the
page. The engine resolves them before your layout runs:

```
page_meta_title  =  meta_title  //  title
page_meta_desc   =  meta_desc   //  subtitle
```

So a page that sets neither behaves exactly as it always has, and a page that
sets either gets what it asked for. You do not need to write the `//` yourself,
and you should not: the resolution order is the engine's to own, and a layout
that reimplements it will drift from the registries, which use the same
resolved values for `sitemap.xml`, `llms.txt` and the feeds.

### Why getting this wrong is silent

The engine injects a description tag **only when the rendered HTML has none**.
That is deliberate - a layout that writes its own `<head>` is trusted to mean
it, and the engine will not fight it. The consequence is that a layout doing
this:

<!-- lint-48: counter-example follows. This block shows what NOT to write; the
     check that keeps the other examples correct skips between these markers. -->

```
<title>[% page_title %]</title>
<meta name="description" content="[% page_subtitle | html %]">
```

<!-- lint-48: end counter-example -->

wins, quietly. The page's `meta_desc` is discarded with no warning, and
`meta_title` is never consulted at all. The site's own `llms.txt` will then
advertise the page with one description while the page serves another, and
nothing reports the disagreement.

This is not hypothetical. It is how every layout in the catalogue was written,
because the example in this briefing showed it that way, and it is why
`meta_title` had no observable effect on any real site for a full release after
it was implemented (SM300, SM308). The example below is now correct; if you are
reading an older layout as a model, check its `<head>` before copying it.

### Deprecated in `<head>`

`page_title` and `page_subtitle` remain correct **in the body** - they are the
heading and standfirst, and that is what they are for. In `<head>` they are the
wrong variables. A layout using them there is not broken today, since the two
resolve identically on a page that sets no meta front matter; it simply ignores
the author whenever they ask for something different.

## TT variables in layout.tt

Always available:

- `content` - rendered HTML page body
- `page_title`, `page_subtitle` - front-matter values
- `page_meta_title`, `page_meta_desc` - **what belongs in `<title>` and
  `<meta name="description">`**. Use these, not `page_title` and
  `page_subtitle`, for the two `<head>` tags. See "The `<head>` contract"
  below - getting this wrong is silent.
- `site_name` - from `lazysite.conf`
- `nav` - array parsed from `nav.conf`
- `request_uri` - current URL path

D013 additions:

- `layout_name` - resolved layout name (string)
- `theme_name` - resolved theme name when a compatible theme is
  active (string; unset otherwise)
- `theme` - hash, the parsed `theme.json`. Access config values
  as `[% theme.config.colours.primary %]` etc. Empty hash when
  no theme is active.
- `theme_assets` - URL prefix `/lazysite-assets/LAYOUT/THEME`
  (nested for local themes), or `/lazysite-assets/CACHE_KEY` for
  remote layouts (flat), or unset when no theme
- `theme_css` - pre-rendered `<style>:root { ... }` block of CSS
  custom properties. Empty string when no theme.

Auth variables:

- `authenticated` - truthy if the request has a valid session
- `auth_user`, `auth_name`, `auth_groups` - user identity
- `manager` - "enabled"/"disabled" from conf
- `manager_path` - manager UI URL path

## theme.json schema (D013)

Required fields:

- `name` - matches directory name
- `version` - semver
- `description` - free text
- `author` - free text
- `layouts` - array of layout names this theme is compatible
  with. **The manager rejects an upload without this.** The
  processor ignores a theme if the active layout isn't in this
  array.
- `config` - object grouping design tokens. Common groups:
  `colours`, `fonts`, `spacing`, `icons`. Group names and keys
  are author-chosen; values must be strings.

Optional:

- `files` - list of files shipped. Used for remote-layout auto-
  fetch; not consulted for local themes.

Example:

    {
      "name": "odcc",
      "version": "1.0.0",
      "description": "OpenDigitalCC brand theme",
      "author": "OpenDigitalCC",
      "layouts": ["default"],
      "config": {
        "colours": {
          "primary": "#332b82",
          "text": "#2a2a2a"
        },
        "fonts": {
          "body": "Open Sans"
        }
      },
      "files": ["theme.json", "main.css"]
    }

## Auto-generated CSS variables

The processor walks `theme.config` and emits a `<style>` block
with CSS custom properties at `:root`, exposed as
`[% theme_css %]`:

    <style>
    :root {
      --theme-colours-primary: #332b82;
      --theme-colours-text: #2a2a2a;
      --theme-fonts-body: Open Sans;
    }
    </style>

Naming: `--theme-GROUP-KEY`.

Use in the theme's CSS:

    body {
      color: var(--theme-colours-text);
      font-family: var(--theme-fonts-body);
    }

This is the recommended pattern: layout.tt emits `theme_css`;
the theme's own `main.css` references the variables. A theme
fork that only tweaks colours edits `theme.json` and doesn't
need to duplicate CSS structure.

## Minimum layout.tt

    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>[% page_meta_title %][% IF site_name %] - [% site_name %][% END %]</title>
      [% IF page_meta_desc %]<meta name="description" content="[% page_meta_desc %]">[% END %]
      [% theme_css %]
      [% IF theme_assets %]
      <link rel="stylesheet" href="[% theme_assets %]/main.css">
      [% END %]
    </head>
    <body>
      [% IF nav.size %]
      <nav>
        [% FOREACH item IN nav %]
        <a href="[% item.url %]">[% item.label %]</a>
        [% END %]
      </nav>
      [% END %]
      <main>
        <h1>[% page_title %]</h1>
        [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
        [% content %]
      </main>
    </body>
    </html>

## Components: a layout's reusable pieces (GS9)

A component is a Template Toolkit file at `components/<name>.tt` inside the
layout directory. Once it exists, any Markdown page on the site can use it
with a fenced block, and the author never writes HTML:

    ::: hero eyebrow="Workshop"
    # The barn, restored

    ::: actions
    [Book a visit](/visit)
    :::
    :::

The component receives three variables:

- `attrs` - the `key="value"` pairs on the opening line (`attrs.eyebrow`).
- `content` - the inner Markdown, already rendered to HTML. Print it as-is;
  adding `| html` would double-escape it.
- `slots` - each nested `::: <name>` block whose name is NOT itself a
  component, rendered to HTML (`slots.actions`). A nested block that IS a
  component renders inside `content` instead, so components nest.

A worked `components/hero.tt`:

    <section class="hero">
    [% IF attrs.eyebrow %]<span class="eyebrow">[% attrs.eyebrow | html %]</span>[% END %]
    [% content %]
    [% IF slots.actions %]<div class="cta">[% slots.actions %]</div>[% END %]
    </section>

`attrs` values are raw author text, so escape them; `content` and `slots`
are rendered HTML, so do not. Style `.hero`, `.eyebrow` and `.cta` in the
theme's CSS against the theme tokens (`var(--theme-colours-accent)` and
friends - the variable names mirror YOUR theme.json's own group and key
spellings, `--theme-<group>-<key>`, so check the generated theme-tokens.css
rather than guessing), so the same component restyles with every theme.

Built-in components ship under `lazysite/templates/components/` and work on
every layout (`::: qr` is one). A layout component of the same name wins.

A `:::` block whose name matches no component becomes a plain
`<div class="name">` - that is the fenced-div fallback, and it is silent on
purpose. An OPENING fence with no closing `:::` is different: it is left in
the page as literal text, the build logs a `WARN` naming the component and
the body line, and `validate_page` reports `component-fence-unmatched` at
the line. Close every fence you open; count them when you nest.

The same hero panel has been hand-built twice on two sites because nobody
told either author this existed. If your layout has a visual pattern a page
will want more than once, ship it as a component and name it in the
layout's README.

### `sections:` - a page composed entirely from components

For a page that is all structure and no prose, the front matter can carry a
`sections:` list. The engine parses it (a sequence of single-key maps, with
nested maps, lists and `{inline: maps}`) into a `sections` variable for the
LAYOUT. The layout decides what to do with it; the engine draws nothing.
No shipped layout reads `sections` yet, so a layout that wants this adds
the loop itself:

    [% FOREACH s IN sections %]
    [% type = s.keys.first %]
    [% INCLUDE "components/${type}.tt" data = s.$type %]
    [% END %]
    <main>[% content %]</main>

and a page then reads:

    ---
    title: Home
    sections:
      - hero:
          heading: The barn, restored
          actions:
            - { label: Book a visit, href: /visit, style: primary }
      - features:
          items:
            - { title: Workshops, body: Hands-on, small groups. }
            - { title: Stays, body: Two rooms above the forge. }
    ---
    Any Markdown body still renders below, in [% content %].

Under `sections:` a component gets its values as `data` (`data.heading`,
`data.actions`), whereas under a `:::` fence it gets `attrs`/`content`/
`slots`. A component meant for both reads whichever is set.

## Activating layout + theme

A site has ONE active layout + theme, set in `lazysite.conf`:

    layout: default
    theme: odcc

Both values are sanitised to `[A-Za-z0-9_-]` at resolve time. **Activate the
theme globally and keep pages layout-agnostic** - do not put `layout:` in page
front matter as the way to apply a design. Every page then inherits the active
layout, so the whole site re-themes in one step. A per-page `layout:` is only
for previewing a staged candidate (below) or a deliberate one-off page - and
you remove preview overrides once you activate.

Agents set these **themselves** through the control API (`layout-activate` /
`theme-activate`), which also clears the cache - it is a self-serve action with
`manage_layouts` / `manage_themes`, not an operator hand-off.

## A reveal animation must start from a VISIBLE state

A scroll-reveal pattern usually looks like this:

```css
.rv    { opacity: 0; transform: translateY(22px); }
.rv.in { opacity: 1; transform: none; }
```

with a script adding `.in` as sections enter the viewport. **Content is invisible
by default and visible only once JavaScript has run** - so a visitor with
JavaScript blocked, most crawlers, and anything extracting text see an empty
page. The site looks complete to its author and is empty to a meaningful fraction
of what reads it.

**A rule inside `prefers-reduced-motion` is NOT a safety net:**

```css
@media (prefers-reduced-motion: reduce) { .rv { opacity: 1; } }
```

That applies only to visitors who asked for reduced motion. It reads like the
animation has already been made safe, and it has not. A careful reader took it
that way, removed the page script while moving chrome into the layout, and left
every section of a live site permanently invisible. The hero sat outside the
pattern, so four successive visual checks looked fine.

Either start visible and animate from there, or give a `<noscript>` fallback that
restores visibility. `create_theme` warns when a theme's CSS hides content by
default, and `audit_site` reports it on an installed theme.

## The active theme is read-only. Where a theme lives.

Two facts to have BEFORE you plan a theme change, rather than after your first
`403`:

**A theme lives at `lazysite/layouts/<layout>/themes/<theme>/`.** Not
`lazysite/themes/` - a theme always belongs to a layout, so it is stored under
that layout. Looking in the wrong place is a `403`, not a `404`, because the
whole `lazysite/` tree is denied to writes by default.

**The theme a site is currently using cannot be edited in place.** The server
refuses writes to it, deliberately: a live theme being rewritten mid-request
would serve a half-updated site to whoever was reading at that moment. It is
design, not obstruction.

So a theme change is always: install under a NEW name, check it, then activate.
The old theme stays where it is until you remove it, which is also your rollback.

## Staging a layout over WebDAV

If you publish over WebDAV you do NOT edit the live look in place - you
stage a new layout beside the active one, preview it, and **activate it
yourself** over the control API.

1. **Capabilities come from your account, not your token.** Editing layout
   structure (including `layout.tt`) needs `manage_layouts`; theme files
   need `manage_themes` (separate capabilities). The token does not encode
   capabilities - they are read from your account on every request - so an
   operator's grant takes effect immediately and you do NOT need a new
   token. If a layout write still `403`s right after a grant, you are
   almost certainly writing the **active** layout (next point), which is
   denied regardless of capability. (Ruled that out and a fresh grant still
   seems not to apply? Rotating your token is a reliable belt-and-braces.)
2. **Stage a NEW layout dir - never the active one.** A `PUT` into the
   active layout returns `403`: the live layout is immutable in place, by
   design (a deliberate guard, not a grant failure). A path under a new
   layout returns `409` until you create its collections, then it is
   writable - so `MKCOL` `lazysite/layouts/<new>` and
   `…/themes/<theme>` first, then `PUT` the files.
3. **Preview by per-page override.** Set `layout: <new>` in a single page's
   front matter to render that page through the staged layout before any
   global switch - this is the preview mechanism. The theme's SOURCE css is
   web-served at `/lazysite/layouts/<new>/themes/<theme>/main.css`, so
   reference that for preview; the canonical mirror
   `/lazysite-assets/<new>/<theme>/main.css` is `404` until activation.
4. **Activate it yourself.** `POST` `action=layout-activate&path=<new>` then
   `action=theme-activate&path=<theme>` to the control API (needs
   `manage_layouts` / `manage_themes`); each sets the pointer in
   `lazysite.conf` AND clears the cache atomically - no operator step. Then
   **remove the per-page `layout:` preview overrides**: they are a preview
   tool, not the deploy mechanism, and left in place they quietly defeat the
   next site-wide theme switch. Once active, the canonical `/lazysite-assets/`
   mirror serves the theme CSS.

## Theme assets and the activation mirror

`main.css` and other theme assets must live under the theme's **`assets/`**
directory: `lazysite/layouts/<layout>/themes/<theme>/assets/main.css`. On
activation the server builds a flattened mirror served at
`/lazysite-assets/<layout>/<theme>/main.css`, and `layout.tt` links that mirror.

- A `main.css` at the theme ROOT (not under `assets/`) is **not** mirrored, so
  the page links a `404`. Put assets under `assets/`.
- **The mirror is rebuilt on every activation** (`theme-activate` /
  `layout-activate`), so after activating, `GET`
  `/lazysite-assets/<layout>/<theme>/main.css` returns `200` - a
  copied-then-activated layout is drop-in, with no CSS-path edits needed. If it
  ever `404`s **on a single-site instance**, re-activate to rebuild it. On an
  instance serving more than one domain, do NOT re-activate - see
  [Multi-domain instances](#multi-domain-instances) below, where re-activating
  changes a different site.
- As a fallback you can write the mirror files directly over WebDAV, to
  `/lazysite-assets/<layout>/<theme>/`. That path is writable and this works -
  but it is a **copy that will not track later edits to the theme source**, so
  treat a hand-written mirror as a repair to be replaced, not a state to leave a
  site in.
- Before activation, the theme SOURCE css is web-served at
  `/lazysite/layouts/<layout>/themes/<theme>/main.css` - use that for preview;
  switch links to the `/lazysite-assets/` mirror once active.

`theme.json` must be **strict JSON, ASCII, and quote-free in values** - a
non-ASCII character (e.g. an em-dash in `description`) or embedded quotes in a
`config` value fails validation. The check runs **at activation** (and is
cached), so after fixing `theme.json` you must **re-activate**, not just
re-PUT it; a rejection now names the failing reason.

Author `.html` files in the content tree (include partials with no matching
`.md`/`.url` source) are **content, not cache** - the activation cache-clear
leaves them alone. Generated cache (`<page>.html` beside `<page>.md`) is what
gets cleared.

## Multi-domain instances

Everything above describes one site. An instance can serve **several first-class
domains**, each with its own content root, and each carrying its own layout,
theme, nav and presentation settings. If you have been given a task about "a
domain" rather than "the site", read this section first - the instructions above
are not wrong, but they operate instance-wide and will change a site you were not
asked to touch.

A domain's own layout and theme are set with `domain_set` (MCP) or `domain-set`
(control API) against that host. `list_domains` / `domains-list` shows what is
registered, each with its `content_root`, `layout` and `theme` - **call it first**
on any task that mentions a domain, so you know whether this instance serves one
site or several.

`preview_domain` renders a domain exactly as an anonymous visitor would see it,
under its own Host, and works before DNS or TLS point at it - so you can check
what you configured instead of guessing.

### Do not use `theme-activate` to fix a secondary domain

`theme-activate` and `layout-activate` are **instance-wide**. They rewrite the
`theme:` and `layout:` keys in `lazysite/lazysite.conf`, which is the *primary*
site's presentation. Re-activating to repair a secondary domain's stylesheet
switches the primary site's theme - on a real instance that moved a live site
from its own theme to a client's.

They also only see the active layout: `theme-activate` looks for the theme under
`lazysite/layouts/<active-layout>/themes/`, so a theme belonging to a secondary
domain's *different* layout is simply not found, and the activation refuses. The
remedy fails in both directions.

### The right way to publish a secondary domain's assets

Binding the layout and theme publishes the theme's assets to
`/lazysite-assets/<layout>/<theme>/` as part of the binding, under **that
domain's** layout. Bind it and the mirror is there.

Two equivalent ways to bind, and the second is usually what you want:

- `domain_set` with `key: theme` (or `layout`) - explicit, one key at a time.
- `activate_theme` / `activate_layout` **with a `host`** - the same tools you
  would reach for anyway, scoped to that one domain. Without a `host` they are
  instance-wide and change every site on the instance, so on a multi-domain
  instance always pass one.

`site_apply` (applying a site package to a target `host`) also mirrors on apply,
and is the right tool when you are moving a whole site rather than changing its
presentation.

### If a domain renders unstyled

The usual cause is a missing mirror, and the symptom is misleading: the layout
*is* applied and renders its header, nav and footer correctly, but with no CSS
the chrome is invisible, so it reads as "no layout".

1. `GET /lazysite-assets/<layout>/<theme>/main.css` for that domain's pair. A
   `404` confirms it.
2. Check the source is where it belongs:
   `lazysite/layouts/<layout>/themes/<theme>/assets/main.css`.
3. Re-bind with `domain-set` to publish it. Do not re-activate.

### Cache

How long browsers keep `/lazysite-assets/` files depends on WHICH front end
serves the site, and a layout author cannot assume - so here is how to tell,
and what to do in each case:

- On the **stock front end** (no ACL store; the header says nothing, or
  `X-Lazysite-Front` is absent), assets carry a ten-year cache. A layout
  linking `main.css?v=1` must **bump `v` on every CSS change** or browsers
  keep serving the old file - including yours while you are checking your work.
- On the **lazysite proxy template** (`X-Lazysite-Front: hestia-proxy/acl` or
  a one-rule front end), the engine serves assets itself. By default they
  revalidate on every use - your changes appear immediately and `?v=` bumping
  is unnecessary (though harmless). If the operator has set the site's
  **Asset cache lifetime** (`asset_max_age`), changes can take up to that many
  seconds to reach returning visitors, and `?v=` bumping makes them immediate
  again.

## Theme incompatibility

If `theme.json.layouts` does NOT contain the active layout:

- The processor logs a WARN: `theme not declared for layout`
- `theme_css` is empty
- `theme_assets` is unset
- `theme` is an empty hash
- The page still renders through layout.tt

## What NOT to do

- Do not modify `lazysite/manager/layout.tt` - that's the
  manager UI's internal chrome.
- Do not place themes at the pre-D013 path
  `lazysite/themes/NAME/` - the processor doesn't look there
  any more.
- Do not write `view.tt` - that file name is gone; it's
  `layout.tt` now.
- Do not omit `layouts[]` from `theme.json` - the manager
  rejects the upload and the processor can't activate it.
- Do not emit CSS expressions in `theme.config` values; `;{}<>`
  are stripped to prevent declaration escape.

## Related

- [Integrations](/docs/integrations) - bring an external design into a site
- [Layouts reference](/docs/features/configuration/layouts)
- [Themes reference](/docs/features/configuration/themes)
- [theme.json reference](/docs/features/configuration/theme-json)
- [Remote layouts](/docs/features/configuration/remote-layouts)
