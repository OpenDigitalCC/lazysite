---
id: SM1399
title: "SM1399: the engine's template filters can be tested from outside"
subtitle: "A candidate: a test export of the engine's json and url_safe template filters, or a documented way to load them from an installed engine, so a layouts catalogue can test its layouts against the real ones rather than copies."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-07
raised-by: "the n770 brief, item 5, from the layouts catalogue"
area: layouts
status-note: "CANDIDATE, filed on n770 (no build). The filters are processor subs (_json_filter, _url_safe_filter in lazysite-processor/include.pm), reachable only by loading the processor; a catalogue test today copies them or stubs them."
---

# The gap

A layout's template is rendered by the engine with its own filters: `json`
(SM824, the one safe way to put a value into JSON-LD), `url_safe` (SM970, a
whole `href`, `src` or `action`) and `markdown`. A layouts catalogue that
renders its layouts in its own tests has no way to load the real filters: they
are subs of the processor's parts (`_json_filter` and `_url_safe_filter` in
`lazysite-processor/include.pm`), defined in `package main` when the processor
is loaded, and the processor is not a module. A catalogue test therefore copies
the filters, and a copy drifts from the engine without anyone noticing - the
risk lint 125 names for every copied reader.

# Options

```datatable
columns: Ref | Option | For | Against
widths: 1cm | 4cm | X | X
---
F-1 | A test export: `Lazysite::Template::Filters` in `lib/`, the processor's parts calling it | One definition, loadable with `-I<engine>/lib` from an installed engine | The render path loads a Lazysite:: module (ADR 0001) - unless the part keeps its copy and a lint pins the two, as lint 125 pins the registry readers
F-2 | A documented way to load the filters from an installed engine: `do` the processor under `LAZYSITE_FILTERS_ONLY=1` and read `main::_json_filter` | No new module; the real code | Loading the processor is loading a CGI, with its BEGIN and its parts; brittle for a test outside the tree
F-3 | A `lazysite render --layout DIR --page FILE` verb that renders a page through the real engine | Tests the whole render, not the filters alone; what a catalogue wants | A new verb, and a catalogue test that shells out
```

No recommendation yet; F-3 fits the catalogue's question best and F-1 the
engine's shape. For the release manager to place.
