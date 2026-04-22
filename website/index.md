---
title: lazysite
subtitle: Markdown-driven static pages for any CGI-capable web server. No build step, no database, no CMS.
register:
  - sitemap.xml
  - llms.txt
---


## Why is it lazy?

Is it hard to install?
: No need to even install it. just download or clone the repo, install a handful of modules available on common Linux distributions, and fire up the server - it just works from it's local lightweight service and will serve the sample content or yours.

Really, how to install?
: If you want a more permenant installation, run the install script. This sets Lazysite up with Apache or your webserver of choice - it's just a CGI script.

What about content?
: It comes with some basic content that you can just edit. It's markdown, so simple text. Add your own.

And layouts and themes?
: The lazysite-layouts repo has some basic layouts and themes - you can clone these and install. The quickest way to test is to run the local server, and just copy the layout or theme in to the starter site.

Can I build a static site and run elsewhere?
: Yes, it runs in generation mode. In fsact, lazysite is a dynamic and static system - create your content and it creates the pages on the fly. 

Most static builders do just that - what about more advanced sites?
: There is a powerful templating system built in, allowing pages to have dynamic content (even remote content), export news feeds, sitemaps, read in remote dynamic data and json files, loop through content, conditionally display.

So - no-commitment whilst you become familair, simple minimal infrastructure to test themes, just text - what could be easier?

## What it is

Drop a `.md` file in your docroot and it is served as a fully rendered HTML page. The first request generates the HTML and caches it alongside the source file. Every subsequent request is a plain static file - no process, no overhead.

Write content in Markdown. Design the site in a `layout.tt` template file, with a separate theme layer for colours and fonts. The three never touch each other.

::: widebox
This site is its own demonstration. The pages are `.url` files - lazysite fetches the Markdown from the [GitHub repository][github] and renders it on first request.
:::

## Where to go

[Readme](/README)
: Installation, requirements, configuration, troubleshooting, and technical internals. Start here if you are setting up lazysite on a server.

[Authoring](/authoring)
: Writing pages - front matter, Markdown, Template Toolkit variables, fenced divs, remote sources, and cache management. Start here if you are building or maintaining a site.

## Key features

No build step
: Write a `.md` file, save it, it is live. Delete the cached `.html` to republish after edits. That is the entire workflow.

No database
: Files are the source of truth. Nothing to back up separately, nothing to migrate.

Fast by default
: Dynamic only on the first request. Plain cached HTML is served after that - no interpreter, no overhead.

Design and content separated
: The `layout.tt` template owns the structural HTML; a separate theme supplies colours, fonts, and assets. Content authors work only in `.md` files. None of the three touch each other.

Version control ready
: Everything is a file. The entire site lives in a git repository.

Remote sources
: `.url` files pull Markdown from a remote URL - a GitHub raw file, for example - and render it through the same pipeline. Documentation lives with the code; the site always shows the current version.

Content includes
: `:::include` inlines local or remote content - Markdown partials, code files, remote feeds - directly into a page at render time.

Navigation from a config file
: `nav.conf` defines the site navigation as a plain text file. The layout template reads it as a structured variable and renders the menu. Editing the menu does not require touching the template.

Layouts and themes
: `layout.tt` controls the HTML chrome; a theme on top adds colours, fonts, and assets. Install both from [lazysite-layouts][layouts] or write your own. Themes declare compatibility per layout, with design tokens auto-emitted as CSS custom properties. lazysite includes a built-in fallback so it works without any configuration files.

Content is portable
: Plain `.md` files work with any Markdown processor. Switching tools does not mean rewriting content.

## Licence

MIT. Source on [GitHub][github].

[github]: https://github.com/OpenDigitalCC/lazysite
[layouts]: https://github.com/OpenDigitalCC/lazysite-layouts
