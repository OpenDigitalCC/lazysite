---
title: "SM498: the flagship worked example could not work - a template expression inside Markdown image syntax"
subtitle: "The GS12 gallery example rendered a stray exclamation mark and a link instead of every image. Docs corrected to the raw <img> form the field agent tested; the limitation and the real pipeline order are now stated where authors read."
brand: plain
standard-margins: true
status: shipped
status-note: "FROM THE FIELD 2026-08-24, filed by the site agent verifying 0.10.28, and it undoes the thing it was added for: the GS12 'gallery from a JSON file - worked end to end' example, published verbatim with its own JSON, rendered two cards, correct data, and ZERO img tags - each image a literal '!' plus a link. THEIR ISOLATION (four cases, one page): plain image fine; plain image inside a fence fine; TT in the alt broken; TT only in the SRC broken - so ANY template expression anywhere inside Markdown image syntax fails, and the fence is irrelevant. MECHANISM, read from the processor rather than inferred: the body pipeline is markdown-to-HTML FIRST, TT SECOND (the TT pass runs over the already-rendered HTML with code blocks shielded). The image converter meets the TT tag as raw text, cannot match across it, falls back to link conversion and strands the bang. Loops only LOOK TT-first: the fence has already become one div, and the surrounding FOREACH multiplies the rendered HTML - which is why the example's two cards appeared while its images did not. The doc SAID 'the page's TT runs first', which is wrong and is corrected, not patched around. SHIPPED as a docs correction, tested executably: the gallery example now uses the raw img form the agent tested, the authoring briefing states the limitation in its own right - Markdown image syntax cannot carry a template expression; use a raw img tag when any part is templated - and the pipeline order is stated honestly. t/integration/68 publishes the documented shape against a real docroot and asserts actual img tags with the row's src and alt, plus that the briefing never regresses to a copy-pasteable broken example line - the executable-example test this defect proves was missing. ALSO from the same report: the layouts briefing said var(--theme-colors-accent); the engine emits --theme-<group>-<key> from the theme.json's OWN keys, and every schema example in that document spells the group 'colours' - corrected to match, with a sentence saying the spelling mirrors your theme.json. DELIBERATELY NOT TAKEN: making the image regex TT-tolerant. The behaviour is now documented with a stated workaround; teaching the Markdown converter to parse template syntax couples two languages at their worst seam, and nobody has asked for templated Markdown images once the raw img line is in the briefing. If field use disagrees, that is a new filing with this one as its evidence."
---

# The finding, verbatim shape

The example the briefing shipped for GS12:

    ![[% p.title %]](/gallery/img/[% p.file %])

renders, on every build:

    <p>!<a href="/gallery/img/harbour.jpg">Harbour, dusk</a></p>

Two cards, correct data, zero `<img>` tags. The example exists because agents
could not find `json:`; an agent that now finds it and copies it gets a
gallery with no pictures.

# The pipeline order, stated once and honestly

Markdown becomes HTML first - inline images included - and the body TT pass
runs SECOND, over the rendered HTML (code blocks shielded). A `[% FOREACH %]`
around a fence multiplies the fence's rendered div, which looks like TT ran
first and is why the wrong sentence survived review. Inline syntax gets no
such illusion: the image regex meets the raw TT tag and fails.

# What shipped

- The gallery example uses the raw `<img>` form the field agent tested.
- The authoring briefing states the limitation in its own right, beside the
  example.
- The ordering sentence now tells the truth stated above.
- The layouts briefing's token example matches the engine's emission and its
  own schema examples (`--theme-colours-accent`), and says the spelling
  mirrors the theme.json keys.
- t/integration/68: the documented shape renders real images, executably,
  and the briefing cannot regress to the broken form unnoticed.
