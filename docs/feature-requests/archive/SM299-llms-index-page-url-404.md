---
title: "SM299 - Every site's llms.txt opens with a dead link"
subtitle: "The template appends .md to a page URL. An index page's URL already ends in a slash, so the homepage entry is <dir>/.md - which 404s. It is the first line of the file."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.9 (7ad34f9). The template now appends `index.md` on a trailing slash and `.md` otherwise. `page.path` was rejected as the fix: it is docroot-relative and carries the `sites/<name>/` prefix on a content-rooted domain, so it would have been wrong in a less obvious way on exactly the multi-domain deployments SM151 exists for. t/integration/51 installs the SHIPPED template rather than a copy, so the fixture tests what operators receive. FILED 2026-08-14 from a site-agent report during an IA consolidation on a 0.10.0 site, and CONFIRMED present in the current tree - an upgrade does not resolve it. lazysite's own shipped documentation carries the same fault at /docs/integrations/.md."
---

# SM299 - the first entry is the broken one

## What is wrong

`starter/lazysite/templates/registries/llms.txt.tt:8`:

```
- [[% page.title %]]([% site_url %][% page.url %].md)[% IF page.subtitle %]: [% page.subtitle %][% END %]
```

`.md` is appended to `page.url` unconditionally. For an ordinary page that is
right: `/about` becomes `/about.md`. For an **index page** the URL already ends
in a slash, so `/docs/integrations/` becomes `/docs/integrations/.md`, which is
not a file and 404s.

The homepage is an index page. **So the first entry in every site's `llms.txt`
is a dead link**, and it is the entry an AI client is most likely to follow
first.

Confirmed in this repository's own documentation output as
`/docs/integrations/.md`.

## Why it matters more than a broken link usually would

`llms.txt` exists to be read by machines that will not check whether a link
resolved before drawing a conclusion from its absence. A 404 on the site's own
front page reads as "this site has no home page content" rather than as a
template bug.

## The fix

Append `index.md` when the URL ends in a slash, `.md` otherwise - which is what
the source file is actually called in both cases.

`page.path` looks like an easier answer and is not: it is the docroot-relative
source path, so on a content-rooted domain it carries the `sites/<name>/`
prefix, which is not part of any public URL. It would produce a link that is
wrong in a different and less obvious way on exactly the multi-domain
deployments SM151 exists for.

## Related

[[SM251]] (registry staleness), [[SM181]] (registry routing), and the
`register:` front-matter key that decides which pages appear at all.
