---
title: "SM082 - Separate content vs theme/layout write capability"
subtitle: "Let a partner edit themes without content access (or vice versa)"
brand: plain
---

::: widebox
Observed while connecting ChatGPT (the `chatgpt-web` partner, `webdav:true`,
`manage_themes:false`): the MCP file tools gate uniformly on `webdav`, so a
partner either has full content+file write or none. We want finer grain - e.g. a
"theme designer" partner that may edit layouts/themes but **not** the content
pages, or a content-only partner with no theme access.
:::

## The gap

WebDAV (`lazysite-dav.pl`) is already **path-aware**: `authorise_layout()` gates
`lazysite/layouts/**` on `manage_themes`/`manage_layouts`, while the content
namespace is gated by `webdav` + the dav scope. But the **MCP file tools**
(`write_file`, `move_file`, `delete_file`, `set_permissions`) are gated up-front
on a single `webdav` capability in the tool registry - coarser than WebDAV. So:

- A `manage_themes`-only partner (no `webdav`) cannot use `write_file` at all,
  even on a theme file it is allowed to edit over WebDAV.
- A `webdav` partner can write any content file; there is no "content" capability
  distinct from file access generally.

## Options

1. **Path-aware MCP gating (smallest):** drop the blanket `webdav` gate on the
   file tools and let the same per-path authorisation WebDAV uses decide (theme
   paths -> manage_themes/manage_layouts, content -> webdav). One shared
   authorise() reused by dav + the MCP/control-API handlers. A theme-only partner
   then edits theme files through the connector but is refused content writes.
2. **A distinct `manage_content` capability:** split today's `webdav` (which
   conflates "may use the file API" with "may write content") into `manage_content`
   (content pages) + keep `webdav` as the transport/mechanism flag. More explicit,
   but a settings migration + UI change.

Option 1 is the lighter, more consistent fix (it makes the MCP match WebDAV's
existing model). Option 2 is cleaner long-term but heavier.

## Status

**Done (2026-06-25)** - option 2, the back-compatible way. A new `manage_content`
capability governs the content namespace; `effective_settings` resolves it to the
`webdav` grant when unset, so existing partners are unchanged. Setting it **off**
(a new Users-page toggle) makes a **theme-only** partner: content reads/writes are
refused while `manage_themes`/`manage_layouts` (theme files via the WebDAV
carve-out + the activate tools) still work. Enforced in both surfaces - the MCP
content tools gate on `manage_content`, and `lazysite-dav.pl` refuses the content
namespace - so neither the connector nor raw WebDAV can bypass it. Pinned by
`12-onboarding.t` (default/override) and `dav-publish.t` (a theme-only partner is
refused a content PUT + read). Full suite 1557.
