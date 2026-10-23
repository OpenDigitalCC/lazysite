---
title: Query string variables
subtitle: Accept URL query parameters as TT variables in a page.
tags:
  - authoring
  - api
  - caching
---

## Query string variables

Declare which query parameters a page accepts in front matter. Declared
parameters are URL-decoded, HTML-escaped, and made available as TT
variables via the `query` hash. Undeclared parameters are silently
ignored.

### Syntax

    ---
    title: Search
    query_params:
      - q
      - page
    ---
    [% IF query.q %]
    Searching for: [% query.q %]
    [% END %]

### Declaring parameters

Use a YAML list under `query_params:` in front matter:

    ---
    query_params:
      - name
      - color
    ---

### Accessing in TT

Parameters appear in the `query` hash:

    [% query.name %]
    [% query.color %]

### Example

    ---
    title: Greeting
    query_params:
      - name
    ---
    [% IF query.name %]
    Hello, [% query.name %]!
    [% ELSE %]
    Hello, visitor!
    [% END %]

Request `/greeting?name=Alice` renders "Hello, Alice!".

### Security

- Values reach the page **already HTML-escaped**: `&`, `<`, `>`, `"` and
  `'` arrive as HTML entities, and a line break as `&#10;`. So
  `[% query.name %]` is safe as text and inside a quoted attribute, with
  no filter.
- **Do not add `| html`.** It escapes the value a second time: an `&` in
  the URL then shows as `&amp;` on the page, and a hidden field posts it
  back that way. The same applies to `params.*`, which is the same values.
- There is no unescaped form for a page. The engine keeps the visitor's
  original value for its own use - a form field's `prefill:` - and that
  feature escapes it where it writes the field.
- **A value used as a whole link target needs `| url_safe`.** Escaping keeps
  a value inside its attribute; it does not change `javascript:` into
  anything else. Write `<a href="[% query.next | url_safe %]">` (and the
  same for `src` and `action`): a value with no scheme - a path, `?query`,
  `#fragment` or `//host` - or one starting `http:`, `https:`, `mailto:`
  or `tel:` passes unchanged, and anything else becomes `#`. The filter
  reads the scheme through character references and percent-encoding, so
  `&#106;avascript:` and `java%73cript:` become `#` too. It does not
  escape the value again.
- Only declared parameters are passed through - undeclared parameters
  in the URL are dropped entirely
- URL-decoding is applied (`%XX` hex sequences and `+` for spaces)

### Caching behaviour

Pages with active query parameters (a declared parameter is present
in the request URL) are rendered dynamically on each request and the
result is not cached. Requests without query parameters still serve
from cache normally.

### Notes

- The cache bypass only triggers when a declared parameter appears
  in the actual request - merely declaring `query_params` does not
  disable caching for requests without parameters
- Works with all modes: normal, raw, and api
- [API mode](/docs/features/authoring/api-mode) - combine with
  `api: true` for JSON endpoints that accept parameters
