---
id: SM970
title: "SM970: A value used as a whole link target keeps its URL scheme"
subtitle: "Escaping stops a value breaking out of an attribute; it does not stop `javascript:` being the attribute."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (n271)
area: security
status-note: "SHIPPED (0.15.3) on n275, ruled 2026-10-07 option 1 with 3: a `url_safe` filter on every render passes no-scheme, http, https, mailto and tel values unchanged and turns any other scheme into #; the authoring docs say to use it in href/src/action; lint 213 holds the shipped pages, templates and fallback layout to it. WORK-PLAN-0153 Q12b."
---

# What the review recorded

Query and data values reach a page HTML-escaped (SM869, SM966), so a value cannot
leave the attribute it is placed in. But when an author writes the value as the
WHOLE target - `<a href="[% query.next %]">`, `<img src="[% i.url %]">` - escaping
does not change the scheme: `javascript:` and `data:` survive, and the link runs
script when followed. The shipped pages do not do this with visitor values
(login.md's `next` is checked server-side); a site author can.

# The decision needed

1. **A URL-safe accessor**: the engine offers a filter (`| url_safe` or similar)
   that passes `http`, `https`, `mailto`, `tel` and relative URLs and replaces
   anything else with `#`, and the authoring docs tell authors to use it in
   `href`/`src`. Explicit, opt-in, no surprises for existing pages.
2. **Checked by default**: the stash's escaped copy of a value that looks like a
   URL with a dangerous scheme is neutralised everywhere. Safer by default, but
   changes what every page receives and needs a definition of "looks like a URL".
3. **A lint for shipped pages only**, and documentation for authors.

Recommended: 1 with 3 - the filter plus a lint that shipped pages and layouts use
it wherever a template value is a whole `href`/`src`.

# Done when

Ruled and built; a test that a `javascript:` value placed as a whole href by the
recommended route renders inert.

# Ruling

2026-10-07, release manager: option 1 with 3 - "a url_safe filter that passes
http/https/mailto/tel/relative and turns anything else into '#'; docs tell
authors to use it in href/src; a lint makes shipped pages and layouts use it
wherever a template value is a whole href/src".

# Built (n275)

- **The filter**: `_url_safe_filter` in `lazysite-processor.pl`, registered as
  `url_safe` on every Template object the processor makes - the page body, the
  layout, components, the built-in fallback layout and the registries. Inside
  the processor, not a module, because the render path is module-free (ADR
  0001).
- **What it reads**: the value is decoded - numeric character references (with
  or without the semicolon), the named references that can change a scheme
  (`&colon;`, `&Tab;`, `&NewLine;`, `&plus;`, `&period;`, `&amp;`, `&percnt;`)
  and percent-encoding - layer by layer, up to eight, and the scheme is checked
  at every layer, after dropping leading controls and spaces and removing
  tab/CR/LF as a URL parser does. A browser decodes an attribute once and never
  percent-decodes a scheme, so this is stricter than any browser, never looser.
  Allowed: no scheme, `http`, `https`, `mailto`, `tel`, in any case.
- **Protocol-relative `//host` is allowed**: it has no scheme of its own and
  takes the page's, which is http or https, so it cannot become script.
- **What it returns**: the original text - already escaped once by the stash -
  or `#`. It never escapes again and never returns the decoded form.
- **Docs**: query-params, data-tables, ai-briefing-data, ai-briefing-authoring,
  auth, nav-conf and ai-briefing-layouts. The practice docs say nothing about
  links from data, so ai-briefing-practice is unchanged.
- **Lint 213**: every `href`, `src`, `action`, `formaction` or `poster` in a
  shipped `.md` or `.tt` under starter/, or in the processor, whose value is one
  whole directive must end in `| url_safe`. Exempt by name: `l.url` and
  `languages.0.url` (language alternates the engine builds from the page path)
  and `site_url` (the sysop's configuration). It moved the fallback layout's nav
  links, the features index and the nav examples in the docs onto the filter.
- **Tests**: `t/unit/processor/92` drives the processor: a query value in a page
  body and a layout (`query.*` and `params.*`), an author literal, db rows, and
  the fallback layout's nav. Each assertion was shown to fail under a sabotage.
