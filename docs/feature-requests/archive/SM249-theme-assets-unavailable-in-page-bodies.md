---
title: "SM249 - [% theme_assets %] silently becomes empty in a page body"
subtitle: "It resolves in layout.tt and not in content, so an image path built from it points at the domain root and 404s. Nothing says the scope differs, and the failure is silent."
brand: plain
status: shipped
status-note: "The INTERIM shipped in 0.10.4 (a4653a3): validate_page warned that the theme variables were layout-scope, and the authoring briefing stated the split. The FULL fix is complete on main and unreleased. The layout and the active theme are now resolved BEFORE the body render rather than between the body render and the layout render, so theme_assets, theme_name, theme, theme_css and layout_name all resolve in a page body. The concern that held this - that get_layout_path calls fetch_remote_layout and so cannot run twice per request - was real but smaller than recorded: it needed the resolution MOVED, not duplicated, and get_layout_path reads only site variables (layout, manager_path), so there was no circular dependency on the body render's output. render_content gained a hook that fires once the variables are complete and before the TT pass; render_template passes it, and the three callers that render a body with no layout pass nothing and are unaffected. The interim from 2026-08-09 is REVERSED: validate_page's layout-variable-in-page warning is REMOVED, because a warning describing a constraint the engine no longer has teaches authors to hard-code /lazysite-assets/<layout>/<theme>/ paths that go stale on the next theme change, to avoid a failure that cannot happen. t/unit/mcp/15 now guards the warning's absence; t/unit/processor/19 proves the variables resolve in a body and fails against the pre-change processor. Hot path: bench.pl --check within tolerance. Reported by the sjm-claude-code site agent 2026-08-08; it cost another agent an entire handover."
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

## Done 2026-08-09: the silence, not the scope

The expensive property was never the scope split - it was that breaking it is
SILENT. That half is fixed:

- `validate_page` warns on `theme_assets`, `theme_name`, `theme` and `theme_css`
  in a page body, names which one was used, explains that TT substitutes an
  undefined variable with the empty string, and gives the literal
  `/lazysite-assets/<layout>/<theme>/` form to use instead. A warning, never a
  refusal - writing the token is legitimate when documenting it.
- The authoring briefing states the scope split, which the docs answered nowhere
  before, with the failing example and the working alternative.

**Exposing `theme_assets` to page bodies is NOT done, and is not a small
change.** The value derives from `$layout_key`, which comes from
`get_layout_path` - and that calls `fetch_remote_layout` for a remote layout, so
it cannot safely run twice in a request. Making the variable available means
resolving layout and theme ONCE, before the body render, and threading the result
through: a restructure of the render path ADR 0001 governs.

Doing it half-way would be worse than not doing it. A `theme_assets` that
resolves under a local layout and not a remote one looks reliable and is not,
which is the same class of trap as the original.

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

## What shipped, 2026-08-09

The resolution moved. `render_content` gained a hook that fires once the
variables are complete and before the body's TT pass; `render_template` passes a
closure that calls the extracted `resolve_layout_vars`. The three callers that
render a body with **no** layout - raw pages, api pages - pass nothing and are
unaffected, so the theme variables stay absent there. That is the correct answer
for a page with no chrome rather than a misleading one.

### The blocker was real but smaller than recorded

The status note said this needed "a restructure of the ADR-0001 hot path".
`get_layout_path` does call `fetch_remote_layout`, so it must run once per
request - but that meant the call had to **move**, not be duplicated. And the
`$vars` it reads (`layout`, `manager_path`) come from `resolve_site_vars()`
inside `render_content`, not from the body render's output, so there was no
circular dependency. It is a reordering. Recorded because the original
assessment would have deferred this indefinitely on a constraint that did not
hold.

No modules move, so ADR 0001 is untouched, and `bench.pl --check` reports every
operation within tolerance of the baseline.

### The scope note below is superseded

"Exposing the full `theme` hash to content" was listed as out of scope, and
`theme_css` was to remain layout-only. Both are now exposed, because they are set
in the same block and withholding them would mean deliberately deleting them from
the body stash - which would leave `[% theme_css %]` silently empty in a page
body, reintroducing the exact failure this filing is about. One rule is better
than a line nobody can predict.

### The interim warning is removed, not softened

The 2026-08-09 interim added a `validate_page` warning telling authors these were
layout-scope. That warning is now false and is deleted. A warning describing a
constraint the engine no longer has is worse than none: it teaches an author to
write `/lazysite-assets/<layout>/<theme>/hero.jpg` literally, which then 404s the
next time someone activates a different theme, in order to avoid a failure that
can no longer occur.

`t/unit/mcp/15` was rewritten to assert the warning's **absence**, including that
no other warning still carries the explanation, so reintroducing it fails.

## Not in scope

- Changing how the layout render works.
