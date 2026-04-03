---
title: Why lazysite
subtitle: The frustrations it grew from, and the decisions that shaped it.
register:
  - sitemap.xml
---

## Starting point

The starting point was Apache Server Side Includes. SSI is elegant for what it does - a standard mechanism built into Apache for composing pages from fragments, with no runtime dependency beyond the web server itself. Header, footer, navigation as separate files, included at serve time. Fast, simple, no moving parts.

The problem is content authoring. SSI handles page composition well but has nothing to say about how you write or manage the content inside those pages. You end up writing HTML directly - which is fine for templates but poor for prose. Any non-trivial site accumulates HTML files that are tedious to write and painful to update.

## What was needed

The requirements that shaped lazysite:

Speed
: Pages should be fast. A CGI process on every request is not fast. Static file serving is fast. The caching model means the CGI fires once per page, then Apache serves plain static HTML. The common case is a file read, not a process fork.

Simplicity
: No database. No admin interface. No framework. No build pipeline. Drop a file, get a page. The processor is a single readable Perl script with no dependencies beyond three standard Debian packages.

Markdown
: Content written in Markdown - not because Markdown is perfect, but because it is the established lingua franca for structured plain text. It works in any editor, versions cleanly in git, and is readable without rendering.

Control
: The view template is a file you own and edit directly. The CSS is yours. The HTML structure is yours. lazysite renders Markdown into a slot in your template - it does not impose a theme, a component model, or a styling convention.

Portability
: A page authored for one site should work on any other site running lazysite. Front matter format, fenced div syntax, URL structure - all consistent. Moving content between sites is a file copy.

## What emerged during development

Several capabilities were not in the original plan but followed naturally from the architecture.

Remote sources via `.url` files came from the need to pull documentation directly from a GitHub repository rather than duplicating it. The documentation lives with the code; the site always shows the current version. This site uses exactly that mechanism - the page content is in the [lazysite repository][github] and served here via `.url` files.

Template Toolkit variables fetched from remote URLs - version numbers from a `VERSION` file, release metadata from a GitHub API endpoint - baked into the cached page at render time rather than fetched client-side.

The registry system generates `llms.txt`, `sitemap.xml`, and RSS/Atom feeds from page front matter, updated automatically when pages render. Adding a new registry format requires only a template file.

oEmbed support for PeerTube, YouTube, and other providers with a one-line syntax. The iframe is baked into the cache - no client-side API call.

Content includes via `:::include` - inline local Markdown partials, code files, or remote content directly into a page. Useful for shared sections, documentation pulled from a repository, or configuration examples kept in sync with the source.

Navigation from a plain text config file - `nav.conf` defines the menu structure. The view template reads it as a structured variable. Editing the menu does not require touching the template, and a syntax error in `nav.conf` cannot break the page structure.

The local development server - `perl tools/lazysite-server.pl` - runs the full processor on a non-privileged port. Clone the repository, run the server, and the starter site is immediately browseable. No Apache configuration required for development.

Static site generation via `build-static.sh` - pre-rendering all pages for deployment to GitHub Pages, Netlify, or any host without CGI support.

Each of these followed from the same principle: the mechanism should be simple, the output should be static where possible, and the operator should retain control.

## Alternatives

lazysite suits a specific use case. These may be a better fit depending on your requirements.

Hugo
: A static site generator. Build step produces a complete static site from Markdown sources. Fast, mature, large ecosystem. Better if you want a full build pipeline, complex themes, multi-language support, or are comfortable with a Go toolchain.

Pico CMS
: A flat-file PHP CMS with a similar Markdown-drop philosophy, plugin ecosystem, and admin themes. Better if you want a richer authoring experience without a database. Requires PHP on every request.

Jekyll
: Ruby-based static site generator, well-established in the GitHub Pages ecosystem. Good if your content lives on GitHub and you want free hosting with automatic builds on push.

WordPress
: Full CMS with database, admin UI, and vast plugin ecosystem. Better for non-technical authors, multi-user publishing, e-commerce, or any site needing dynamic content beyond what static caching provides.

[github]: https://github.com/OpenDigitalCC/lazysite
