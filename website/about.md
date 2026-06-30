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

## Why is it lazy?

Is it hard to install?
: Not at all - you don't even have to install it. Download or clone the repo, install a handful of modules from your distribution, and start the built-in server. It serves the sample content, or yours, straight away.

Really - how do I install it?
: For a permanent setup, run the install script. It configures lazysite with Apache, or the web server of your choice - it is just a CGI script.

What about content?
: It ships with basic content you can simply edit. It is Markdown - plain text. Add your own.

And layouts and themes?
: The lazysite-layouts repo has ready-made layouts and themes you can install. The quickest way to try one is to run the local server and copy a layout or theme into the starter site.

Can I build a static site and host it elsewhere?
: Yes - it runs in generation mode. lazysite is both dynamic and static: you create content and it builds the pages on the fly, or exports them as a fully static site.

Most static builders do only that - what about more advanced sites?
: A full templating system is built in: dynamic and remote content, news feeds, sitemaps, reading remote JSON data, looping over content, conditional display, and more.

So - no commitment while you find your feet, minimal infrastructure to test themes, and just text. What could be easier?

## Why it exists

lazysite grew out of a wish for something between hand-written HTML and a heavyweight CMS - fast, file-based, and yours. Read the [motivation](/motivation) for the full story and the design decisions behind it.

## Who makes it

lazysite is built by [Open Digital](https://opendigital.cc) and developed in the open. The source lives on GitHub at [OpenDigitalCC/lazysite](https://github.com/OpenDigitalCC/lazysite), under the MIT licence - free to use, modify and distribute.

## Explore

See [what lazysite does](/features), [who it is for](/who-its-for), or [how it compares](/comparison).
