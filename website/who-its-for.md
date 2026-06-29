---
title: Who lazysite is for
subtitle: From a one-file portfolio to an AI-published content business — and built for the human/AI partnership in between.
register:
  - sitemap.xml
  - llms.txt
---

lazysite suits anyone who wants a fast, file-based site without the weight of a database or a CMS to maintain. It is especially at home where an **AI agent does the work** — describe what you want, and it is published. You stay in control of every file.

<style>.aud-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px;margin:1.4rem 0 2rem}.aud-card{border:1px solid var(--theme-colours-border,#e3e3e3);border-radius:10px;padding:16px 18px;background:rgba(0,0,0,.015)}.aud-card h3{margin:0 0 6px;font-size:1.05rem}.aud-card p{margin:0;font-size:.92rem;line-height:1.5}.use-card{border-left:3px solid var(--theme-colours-primary,#16a34a);padding:.4rem 0 .4rem 1rem;margin:1rem 0}.ctrl li{margin:.35rem 0}</style>

## Who it's for

<div class="aud-grid"><div class="aud-card"><h3>Students &amp; junior developers</h3><p>A professional portfolio in minutes — free, fast, and yours — to land an internship or showcase coursework. No build tooling to learn first.</p></div><div class="aud-card"><h3>Engineers &amp; sysadmins</h3><p>A personal blog or project documentation with no database to run and no CMS to patch. It is just a CGI script and a tree of Markdown.</p></div><div class="aud-card"><h3>Content automators</h3><p>Generating Markdown from scripts or an LLM? lazysite is the drop-in renderer — write files, they are served, with feeds and an <code>llms.txt</code> for free.</p></div><div class="aud-card"><h3>Marketers &amp; site designers</h3><p>Using AI for rapid site development: spin up a site, restyle it from a gallery of themes, and iterate in minutes instead of sprints.</p></div><div class="aud-card"><h3>Publishers</h3><p>Get content out the door quickly — and keep some of it private behind pay-per-read, so writing can earn as it is read.</p></div></div>

## What you can do with it

<div class="use-card"><p><strong>Publish from your phone.</strong> Describe an article to Claude. It writes the Markdown and publishes it — <strong>live instantly</strong>, or <strong>held for review</strong> first if you would rather approve it. No laptop, no dashboard, no deploy.</p></div>

<div class="use-card"><p><strong>Sell what you write.</strong> Put a page behind pay-per-read with the built-in x402 payment support. Private, paid content sits alongside your free pages and uses the same workflow.</p></div>

<div class="use-card"><p><strong>Let the docs write themselves.</strong> Pull pages straight from a code repository with <code>.url</code> files, so documentation always reflects the current version without copying it twice.</p></div>

## Built for a human/AI partnership

lazysite treats **AI publishing as a first-class use case**, not a bolt-on. An agent edits content over WebDAV, a control API, or the Model Context Protocol — and it goes through **exactly the same rules a person does**. There is no privileged back door for automation: the agent inherits a partner's capabilities and per-file permissions, every change is logged, and you decide how much it may touch.

That means you can hand an assistant a narrow, time-boxed grant — "draft and publish to the blog, nothing else, expires Friday" — and trust the core to hold that line.

## You stay in control

Fine-grained controls let you decide exactly who — human or AI — can do what:

<ul class="ctrl">
<li><strong>Lock files</strong> so no one else can alter them while you work — a lock taken anywhere is respected everywhere.</li>
<li><strong>Per-user capabilities</strong> — grant editing, theming, configuration or user-creation independently, so each account does only what it should.</li>
<li><strong>Per-file access control</strong> — set an owner with read and write lists; access only ever narrows, never widens.</li>
<li><strong>Account &amp; token expiries</strong> — time-box a contributor or a partner; access fails closed when it lapses.</li>
<li><strong>Delegation &amp; sub-users</strong> — let a partner mint scoped sub-accounts, but never grant more authority than they hold themselves.</li>
<li><strong>An audit trail</strong> — an append-only record of who changed what, when, from where, and the outcome.</li>
</ul>

See the [full feature list](/features), [how lazysite compares](/comparison), or [try the demo](/lazysite-demo).
