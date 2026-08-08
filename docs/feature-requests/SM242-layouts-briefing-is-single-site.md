---
title: "SM242 - The layouts briefing assumes one site, and its remedy breaks a multi-domain instance"
subtitle: "'If it 404s, re-activate to rebuild it' is correct on a single site and actively harmful on an instance with more than one domain, where it switches the primary site's theme."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-08 alongside SM241, from the same harmony2050.org diagnosis. Documentation only. The engine fix (SM241) turns most of this from a warning about a sharp edge into an explanation, so the two should be weighed together - but the docs gap is real whether or not SM241 is built."
---

# SM242 - the layouts briefing is single-site

## Why

`docs/ai-briefing-layouts.md` has a good section, "Theme assets and the
activation mirror". It gives the mirror path, says assets must live under
`assets/`, and states:

> **The mirror is rebuilt on every activation** (`theme-activate` /
> `layout-activate`) [...] If it ever `404`s, re-activate to rebuild it (or, as
> a fallback, write the mirror files directly over WebDAV).

That section mentions no domains, no content roots, no per-domain themes and no
site packages. It reads as though every instance is one site. On a multi-domain
instance the advice does not merely fail - it damages a site the reader was not
working on.

An agent that followed it on harmony2050.org would have rewritten the
instance-wide `theme:` key and moved theunited.fund from `united-r6` to
`harmony`. The agent did not, correctly, and instead wrote the theme source
directly - producing a theme that exists, validates, and cannot be served.

**The whole layouts briefing never mentions `domain-set`, `content_root`, or
that a domain can carry its own layout and theme.** An agent given a
second-domain task has no document describing the shape of the task it has been
given.

## What to write

### 1. A multi-domain section, with a pointer from the mirror section

It must say plainly: **on an instance with more than one domain, do not use
`theme-activate` to fix a secondary domain's assets.** It is instance-wide - it
rewrites the site's `theme:` key - and it only operates within the active layout
at all, so for a secondary domain on a different layout it refuses with "Theme
not found" rather than helping.

Say what to do instead. Today that is `site_apply` with the target `host`, which
mirrors on apply (SM193) and is the only correct route - and which no document
currently names for this purpose. If SM241 lands, it becomes `domain-set`, and
this section shrinks to a description rather than a warning.

### 2. Qualify the existing sentence

"Re-activate to rebuild it" should read "on a single-site instance, re-activate
to rebuild it; on a multi-domain instance see <multi-domain>". The sentence is
not wrong, it is unscoped, and unscoped advice is what made it dangerous.

### 3. Make the fallback actionable

"Write the mirror files directly over WebDAV" assumes the reader knows the mirror
is `/lazysite-assets/<layout>/<theme>/` and that it is writable. Give the path
explicitly, and say plainly that it is a **copy that will not track later edits
to the theme source** - so a hand-written mirror is a repair, not a state to
leave a site in.

### 4. Say where per-domain binding lives at all

A short section on domains carrying their own layout, theme, nav and content
root, and which action sets them. Without it the briefing describes half a
product to anyone working on a multi-domain instance.

### 5. Note the cache interaction

`/lazysite-assets/` is served with a ten-year cache header, so a layout linking
`main.css?v=1` must bump `v` on every CSS change or browsers keep the old file.
This is already known operationally and is not written down where a layout author
would find it.

## Verification

- The mirror section carries a scope qualifier and a pointer to the multi-domain
  section.
- The multi-domain section names the correct action for fixing a secondary
  domain's assets, and warns against the instance-wide one by name.
- The fallback names the mirror path and its copy semantics.
- `domain-set`, `content_root` and per-domain layout/theme appear in the layouts
  briefing at least once.
- The cache-busting requirement is stated where a layout author will meet it.

## Not in scope

- The engine change. That is SM241, and if it lands this document becomes
  explanatory rather than cautionary - which is the better outcome and the reason
  to weigh them together.
