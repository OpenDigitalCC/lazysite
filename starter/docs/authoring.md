---
title: Authoring
subtitle: How to create and edit pages - the short version.
register:
  - sitemap.xml
  - llms.txt
---

Writing for lazysite is just writing Markdown. There is no build step and no database: drop a `.md` file into the site, and it is a page.

## Create a page

Save a file anywhere in the site, for example `guide.md`:

```markdown
---
title: My Guide
subtitle: Getting started
---

## Hello

This is a **lazysite** page, written in Markdown.
```

Visit `/guide` and it is there. The first request renders the Markdown to HTML and caches it next to the source; every request after that is a plain static file. The block at the top, between the `---` lines, is [front matter](/docs/frontmatter) - the page's metadata.

URLs come from file paths, without the extension:

```
index.md          ->  /
about.md          ->  /about
docs/install.md   ->  /docs/install
```

Always link with extensionless URLs - `/about`, not `/about.html`.

## Edit a page

Change the file and save - that is the whole workflow. Edit it however suits you:

- **On disk** - any text editor, then your normal git flow.
- **Over WebDAV** - mount the site and edit files directly. This is also how an AI agent or a script publishes.
- **In the manager** - the built-in browser editor.

A saved edit re-renders on the next request. There is nothing to rebuild and nothing to deploy.

## Write the content

Standard Markdown works as you would expect - headings, lists, links, **bold**, `code`, tables, block quotes. Two lazysite touches:

- **Headings start at `##`.** `#` is reserved for the page title (it comes from the front matter), so your sections begin at level two.
- **Fenced divs** wrap content in a styled container without writing raw HTML:

```markdown
::: callout
This becomes a styled box.
:::
```

  That renders as `<div class="callout">...</div>` for your theme to style.

## Where to next

- **[Front matter](/docs/frontmatter)** - the metadata keys you can set on a page.
- **[Advanced authoring](/docs/features)** - the full set of capabilities by topic: dynamic variables, content includes, remote sources, page scans, feeds, forms, JSON data, caching and more, each on its own page.
- **[Reference](/docs/reference)** - configuration keys, template variables, and file locations.
