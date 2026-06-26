---
title: "SM096 - migrate a .url page to a local .md"
subtitle: "Capture a remote-content page's body locally so it can be edited"
brand: plain
---

::: widebox
A `.url` file is a single remote URL the processor fetches and renders. To take
local ownership of that content (and edit it), an operator currently has to fetch
the body by hand and recreate the `.md`. Add a one-click **"Migrate to local"**
action on `.url` rows in the file manager: fetch the remote body, save it as the
sibling `<name>.md`, and remove the `.url`.
:::

## Motivation

Raised 2026-06-26 while migrating ssi-md-era sites whose content is a few `.url`
proxies. Editing a `.url`'s *target content* means pulling it local. (Companion fix
already shipped: `.url` files are now editable as text - the file itself, i.e. the
URL line - so this is specifically about capturing the remote *body*.)

## Shape

A new manager-API action, `migrate-url`:

1. read `<name>.url`, take the URL;
2. fetch the body with the processor's SSRF-guarded fetch (`fetch_url` /
   `is_safe_url`) - public http(s) only;
3. write the fetched body to `<name>.md` (refuse if it already exists, unless
   `overwrite`);
4. delete `<name>.url` (and invalidate the cached `.html`);
5. audited as a material event (`migrate-url`, origin ui).

UI: on a `.url` row in `files.md`, a **"Migrate to local .md"** button in the
expand-card actions (shown only for `.url` files), with a confirm. Reuses the same
fetch the processor already uses, so the captured body is exactly what was being
served.

## Open questions

- Capture the **raw remote body** (Markdown/HTML as fetched) vs the **rendered**
  HTML? Raw body is the right answer - it stays editable Markdown; the rendered HTML
  would not round-trip. (If the remote is HTML, the operator may want to keep it as
  `<name>.html` instead - offer the extension based on content type.)
- Front matter: a fetched body may carry its own front matter; preserve it verbatim.
- Whether to keep a `.url.bak` or rely on the backups page.

## Status

Queued. Raised 2026-06-26. Small, bounded: one audited API action reusing the
existing fetch, plus a conditional button. Pairs with the shipped `.url`-editable
fix.
