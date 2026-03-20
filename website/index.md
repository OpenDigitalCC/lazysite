---
title: lazysite
subtitle: Markdown-driven static pages for any CGI-capable web server. No build step, no database, no CMS.
register:
  - sitemap.xml
  - llms.txt
---

## What it is

Drop a `.md` file in your docroot and it is served as a fully rendered HTML page. The first request generates the HTML and caches it alongside the source file. Every subsequent request is a plain static file — no process, no overhead.

Write content in Markdown. Design the site in a Template Toolkit layout file. The two never touch each other.

::: widebox
This site is its own demonstration. The three pages are `.md` files stored in the [lazysite GitHub repository][github] and served here via `.url` files — lazysite fetches and renders them on first request.
:::

## Install

```bash
sudo bash install.sh
```

The installer registers a HestiaCP web template. Apply it to a domain in HestiaCP, rebuild vhosts, and the processor and starter files are in place. A standalone Apache configuration is also produced for use without HestiaCP.

Full installation instructions are in the [docs](/authoring).

## Key features

No build step
: Write a `.md` file, save it, it is live. Delete the cached `.html` to republish after edits. That is the entire workflow.

No database
: Files are the source of truth. Nothing to back up separately, nothing to migrate.

Fast by default
: Dynamic only on the first request. Plain cached HTML is served after that — no interpreter, no overhead.

Design and content separated
: The Template Toolkit layout owns the site design. Content authors work only in `.md` files.

Version control ready
: Everything is a file. The entire site lives in a git repository.

Remote sources
: `.url` files pull Markdown from a remote URL — a GitHub raw file, for example — and render it through the same pipeline. Documentation lives with the code; the site always shows the current version.

Content is portable
: Plain `.md` files work with any Markdown processor. Switching tools does not mean rewriting content.

## Requirements

- Any web server with CGI support and configurable error handlers
- Apache 2.4 with HestiaCP — installer provided; applies as a domain template
- Apache 2.4 standalone — configure `ErrorDocument 403/404` manually
- Nginx — use `error_page 403 404` to point to the CGI script
- Three Debian packages: `libtext-multimarkdown-perl`, `libtemplate-perl`, `libwww-perl`

## Licence

MIT. Source on [GitHub][github].

[github]: https://github.com/OpenDigitalCC/lazysite
