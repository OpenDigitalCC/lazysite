---
title: "SM249 - [% theme_assets %] silently becomes empty in a page body"
subtitle: "It resolves in layout.tt and not in content, so an image path built from it points at the domain root and 404s. Nothing says the scope differs, and the failure is silent."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-08; it cost another agent an entire handover. Verified: the page-body TT stash is built from site_vars, page_vars and the auth/payment/preview contexts, and theme_assets is set separately for the LAYOUT render - so in a page body it is simply undefined, and Template Toolkit substitutes an undefined variable with the empty string."
---

# SM249 - theme_assets does not resolve in page content

## Why

In `layout.tt` this works:

```html
<link rel="stylesheet" href="[% theme_assets %]/main.css">
```

In a page body it does not, and it does not say so:

```markdown
<img src="[% theme_assets %]/hero.jpg">
```

renders as `src="/hero.jpg"`, resolves against the domain root, and 404s.

Template Toolkit substitutes an undefined variable with the empty string, so
there is no error, no warning and no log line - just a broken path that looks
like a typo in the filename rather than a scope problem.

An agent used that pattern in all seven of its replacement image blocks. Entirely
reasonably: it is the pattern the site's own `layout.tt` uses, and nothing
anywhere says the variable is unavailable one level down. Recovering it cost a
whole handover.

## What is true today

The page-body render builds its stash from `%site_vars`, `%page_vars`,
`%AUTH_CONTEXT`, `%PAYMENT_CONTEXT` and `%PREVIEW_CONTEXT`, plus the page's own
title/subtitle/author/modified fields.

`theme_assets` is not among them. It is assigned later, into the variable hash
used for the **layout** render, alongside `theme_name`, `theme` and `theme_css`.
So the whole theme-variable family is layout-scope, and a page body sees none of
it.

That split is defensible - a page is content and the theme is presentation - but
it is undocumented, and the failure mode is silent, which is what makes it
expensive.

## What to change

**Expose `theme_assets` to page-body rendering.** It is a read-only path string
with no author-controlled content and no escaping concern, and there is no
obvious reason to withhold it. An agent will keep reaching for the token because
it is the one they have seen in the layout; meeting that expectation is cheaper
than correcting it forever.

Consider whether `theme_name` should come with it. `theme` (the whole parsed
`theme.json`) and `theme_css` (a rendered `<style>` block) should **not** - a
page body has no business emitting a second style block, and that is a
distinction worth stating rather than leaving to taste.

**Document the scope either way.** The authoring briefing should say which
variables a page body may use, and give the literal
`/lazysite-assets/<layout>/<theme>/` form as the alternative for anyone who needs
it before this lands. Even with `theme_assets` exposed, "which variables exist in
which scope" is a question the docs currently do not answer anywhere.

**Consider making the silence louder.** A page body containing `[% ... %]` for a
variable that resolves to nothing is almost always a mistake. `validate_page`
could report it - it already parses page bodies, and this is the same class of
detection as SM243's guardrails.

## Verification

- `[% theme_assets %]` in a page body resolves to the same path it resolves to in
  the layout.
- A page referencing a theme asset that way renders a working URL.
- `theme_css` remains layout-only.
- The authoring briefing states which variables are available in a page body.

## Not in scope

- Exposing the full `theme` hash to content.
- Changing how the layout render works.
