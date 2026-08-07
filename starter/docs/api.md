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

## The control API is not callable from a browser page

This is a design position, not an omission, and it will not change.

The control API sends no CORS headers and answers a preflight with an explicit
`405`. Its authenticated surfaces serve agents, scripts and the manager - all of
which hold operator-issued credentials. A page running on an arbitrary origin
holds none, and a credential a browser could hold is a credential that is
exposed.

Understanding the reason matters more than the rule, because a variant design
with the same problem will meet the same answer.

What to do instead, depending on what you actually need:

**A browser needs to send something to the site.** Use a form. It is
same-origin, needs no sign-in, validates per field, stores the submission, and
raises a notification - see [Forms](/docs/forms). This is the supported path,
and it covers questionnaires, long pasted text and file uploads.

**A browser application needs privileged work done.** Serve the application as a
static file from the site, and do the privileged work from somewhere that holds a
credential - an agent over MCP, or a script calling this API. The page asks; the
credentialled component acts.

**A browser needs to read published content.** It already can. Anything served on
the public read path is same-origin and involves no CORS at all.

The two `/.well-known/` discovery documents are deliberately open to any origin.
They carry no account data and exist so a browser-side onboarding probe can find
an instance. They are the only exception, and a test pins that.

## Caching behaviour summary

| Mode | Query params | Cached |
| ---- | ------------ | ------ |
| Normal | None or undeclared | Yes |
| Normal | Declared params present | No |
| raw: true | None | Yes |
| raw: true | Declared params present | No |
| api: true | None | Yes |
| api: true | Declared params present | No |

### Content type caching

For `raw:` and `api:` pages with non-default content types, the
content type is cached alongside the `.html` file in
`lazysite/cache/ct/`. This ensures the correct content type is served
even when the page is served from cache.

The cache uses a flat file structure with `:` as a path delimiter:

    lazysite/cache/ct/api:status.ct     <- for /api/status
    lazysite/cache/ct/docs:api.ct       <- for /docs/api

Normal HTML pages do not write a `.ct` file. The cache directory is
protected from web access by the `/lazysite/` URI block.

To clear content type cache entries:

    find public_html/lazysite/cache/ct -name "*.ct" -delete

When a `.html` cache file is deleted, the corresponding `.ct` file
is also deleted automatically by the processor.
