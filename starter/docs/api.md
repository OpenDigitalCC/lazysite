---
title: API and raw mode
subtitle: JSON endpoints, content fragments, and query string variables.
register:
  - sitemap.xml
---

## Raw mode

Setting `raw: true` in front matter outputs the converted Markdown body
without the view template wrapper. TT variables still resolve. Useful for
content fragments, AJAX partials, or HTML snippets fetched by other pages.

```yaml
---
title: Fragment
raw: true
---

Content here - no html, head, or layout wrapper.
[% version %] resolves normally.
```

The default content type for raw mode is `text/plain; charset=utf-8`.

## API mode

Setting `api: true` skips the Markdown pipeline entirely and treats the
page body as a pure TT template. No Markdown conversion, no layout wrapper.
Default content type is `application/json; charset=utf-8`.

Useful for lightweight JSON endpoints that aggregate remote data:

```yaml
---
title: Status API
api: true
---
{
  "status": "ok",
  "site": "[% site_name %]",
  "version": "[% version %]"
}
```

The output is trimmed of leading and trailing whitespace for clean JSON.

## Content type

Override the default content type with `content_type:` front matter. Works
with both `raw: true` and `api: true`:

```yaml
---
api: true
content_type: text/csv; charset=utf-8
---
name,value
site,[% site_name %]
```

## Query string variables

Pages that declare `query_params:` in front matter can access URL query
string values as `[% query.param_name %]` in TT. Only declared parameters
are accessible - undeclared parameters are silently ignored.

```yaml
---
title: Search
query_params:
  - q
  - page
---

[% IF query.q %]
Results for: [% query.q %]
[% ELSE %]
Enter a search term.
[% END %]
```

Requests with matching query parameters bypass the cache - the page always
regenerates. Requests without matching parameters (or to pages without
`query_params:`) use the normal cache path.

Query parameter values are HTML-escaped before being passed to TT.
Undeclared parameters are never passed to TT regardless of the URL.

### Combining with api mode

Query strings work with `api: true` for dynamic JSON endpoints:

```yaml
---
api: true
query_params:
  - q
---
{"query": "[% query.q || '' %]", "results": []}
```

Query requests to API pages are not cached.

## Caching behaviour summary

| Mode | Query params | Cached |
| ---- | ------------ | ------ |
| Normal | None or undeclared | Yes |
| Normal | Declared params present | No |
| raw: true | None | Yes |
| raw: true | Declared params present | No |
| api: true | None | Yes |
| api: true | Declared params present | No |
