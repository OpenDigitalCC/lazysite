---
title: About lazysite
subtitle: A small engine with a big idea - your site is just files.
register:
  - sitemap.xml
  - llms.txt
---

lazysite is a Markdown-driven website engine and lightweight CMS. Drop a `.md` file into a folder and it is served as a fully rendered page - no build step, no database, no application server, just a CGI script and a tree of text. The first request renders and caches the page; every request after that is a plain static file.

Around that core sits a full publishing stack: layouts and themes, content includes and remote sources, forms, authentication, payments, a browser-based manager, a control API, and first-class support for AI agents that publish through exactly the same rules a person does.

The guiding idea is **one enforced core, many thin doors**: every way in - the browser, WebDAV, the API, an AI connector - runs through the same checks, so a lock, a permission, or an audit entry holds identically whoever knocks.

## Why it exists

lazysite grew out of a wish for something between hand-written HTML and a heavyweight CMS - fast, file-based, and yours. Read the [motivation](/motivation) for the full story and the design decisions behind it.

## Who makes it

lazysite is built by [Open Digital](https://opendigital.cc) and developed in the open. The source lives on GitHub at [OpenDigitalCC/lazysite](https://github.com/OpenDigitalCC/lazysite), under the MIT licence - free to use, modify and distribute.

## Explore

See [what lazysite does](/features), [who it is for](/who-its-for), or [how it compares](/comparison).
