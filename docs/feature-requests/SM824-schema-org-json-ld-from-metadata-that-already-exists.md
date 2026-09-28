---
id: SM824
title: "SM824: schema.org JSON-LD, emitted from metadata the page already has"
subtitle: "Accepted 2026-09-10 from the knowledge-standards recommendation, as the first of its sequence. Emit WebSite/WebPage/Article JSON-LD into the head from front matter and site config that already exist, extendable per page for richer types. It serves the ordinary visitor web through search and answer engines regardless of how agent standards settle, which is why it is first and why it is worth doing even if every other recommendation is declined."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-28, audit first as the filing asked, and its four questions are answered in the injector's own header rather than in a separate document. WHAT METADATA RELIABLY EXISTS: a title always, the site name and site_url from config, a description from meta_desc or the subtitle. Author and dates are commonly absent, so NOTHING asserts them - a block claiming an author the page does not have publishes a false statement about the page. WHERE IT IS EMITTED: beside SM112's generator meta and SM151's canonical link, on both the real-layout and the no-layout paths, which is what makes it work for a site running its own layout; a layout that emits its own ld+json keeps it. IS `Article` EVER RIGHT BY DEFAULT: no, and a page with a date AND an author is still a WebPage - the only way to get another type is `schema_type:` in front matter, which lands as a SECOND type rather than replacing WebPage, and which is ignored unless it is one bounded word. THE ESCAPING BOUNDARY had two halves and both bite: `</script>` inside a JSON string ends the block in a browser however well-formed the JSON is, so every `</` is written `<\\/`; and the values arrive HTML-ESCAPED for the <title> tag, which would put `&amp;` inside a JSON string, so they are decoded by the exact inverse first. `_canonical_path` was factored out of the canonical-link injector rather than copied, because two answers to 'which URL is this page' is how a canonical link and a JSON-LD url come to disagree. t/unit/render/71, four sabotages. TWICE while writing the test I selected the wrong node from the graph - by 'has a name', then by 'has a slash in its @id' - and got the WebSite both times, which let a sabotage pass; there is one helper now that asks for the page node by its url."
raised: 2026-09-10
raised-by: release manager, from the knowledge-standards survey
area: discoverability
---

# What is asked

JSON-LD blocks generated **at render, into `<head>`, via the layout**, from
metadata that already exists: title, subtitle, dates and author from front
matter, plus site config. `WebSite` / `WebPage` / `Article` as the base, with a
front-matter key to extend to richer types per page.

**No new authoring burden** is the load-bearing constraint. If an author has to
add anything for the ordinary case, this has been built wrong.

# Why this one first

The recommendation's own argument, and it holds: this serves the visitor web
whichever way agent standards go. Search and answer engines are where a site's
visitors actually arrive from, the vocabulary has been stable for a decade, and
the consumer side has a validator. Nothing else in the sequence has all three.

# Audit first, and what the audit must answer

Per the standard method, and these are the questions rather than the design:

- **What metadata actually exists per page**, and which fields are reliably
  present versus commonly absent. A JSON-LD block asserting an author or a date
  the site does not have is worse than no block: it publishes a claim about
  the page that is not true.
- **Where the layout can emit it** without every layout having to opt in - the
  base layouts ship, but a site may carry its own, and a discoverability feature
  that only works on shipped layouts is half a feature.
- **Whether `Article` is ever right by default.** Most lazysite pages are not
  articles. Guessing the type from the presence of a date would be exactly the
  plausible-inference-presented-as-fact this codebase files against.
- **The escaping boundary.** JSON-LD inside `<script type="application/ld+json">`
  needs JSON escaping AND protection against `</script>` in a value - a
  different problem from the HTML escaping [[SM786]] is about, and on the same
  metadata.
- **CSP.** The manager and site carry a policy; an inline `ld+json` block is not
  script execution but it is an inline element, so whether it needs a nonce or is
  exempt has to be established rather than assumed.

# Verify

Against Google's Rich Results test, on a real page, before it is called done -
the recommendation names this and it is the right gate: the consumer's validator
is the only thing that says whether the emitted block is understood.

# Provenance

`inbox/knowledge-standards.md`, Recommendation 1, accepted by the release manager
2026-09-10. The doc cites this as "the existing D011 discoverability scope,
promoted"; D011 has no filing in this tree, so this is its first.

# EXTENSION OR CORE, researched 2026-09-10: extension, and it is blocked on a hook

The release manager asked which this should be, with extension preferred. The
answer is extension, and the research turned up the reason it cannot be one yet -
which changes when it should be built rather than whether.

**The processor calls no plugin during a render.** Read from the source: the only
plugin-related thing `lazysite-processor.pl` does is `_enabled_plugins()`, which
reads the `plugins:` list out of `lazysite.conf` so the manager nav can hide an
item. No plugin code is loaded, invoked or consulted while a page is rendered.

**And the extension contract has no room for one.** A plugin's `--describe`
declares exactly four things across every shipped plugin: `actions`, `owns`,
`on_enable`, `on_disable`. There is no hook, no filter, no render participation.

So JSON-LD - which must emit into `<head>` from the page's own metadata, at render
- **cannot be an extension today.** The two honest options:

1. **Core**: a few lines in the processor emitting from `$meta`, gated by a conf
   flag. Cheap, and it puts discoverability enrichment in the renderer the
   release manager wants kept standalone and simple. It is the wrong answer to
   the stated principle, and it would be the third thing in core that is
   extension-shaped after the access log.
2. **Extension, once there is a render-time registry.** [[SM222]]'s L0 needs
   exactly that - core calling through a registry a disabled unit is absent from -
   and it is being built with [[SM817]].

**Recommendation: 2, and note what it buys.** SM824 becomes **the registry's
first real consumer**, and a registry with no consumer is a mechanism nobody has
exercised. Building L0 for the access log alone proves it can stop work
happening; building it with JSON-LD proves it can make work happen too, which is
the harder half and the one a later extension will actually use.

So the sequence is: extensions batch first, then this. Not before.
