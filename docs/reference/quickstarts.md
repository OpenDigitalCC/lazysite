---
title: "lazysite - agent quickstarts"
subtitle: "The sanctioned path for common jobs"
brand: plain
standard-margins: true
---

**Generated file - do not edit by hand.** Produced by `tools/gen-capability-docs.pl` from `lib/Lazysite/Capabilities.pm`, the same builder behind the `describe_capabilities` endpoint. An agent with a session should call that endpoint (it also reports what THIS account holds); this doc is the static model for humans and un-authenticated readers.

Each recipe uses the supported surfaces (WebDAV / control API / MCP) - never editing the engine directly. The capability each needs is listed; if a step is refused, call `describe_capabilities` to see what your account holds.

## Install and activate a theme

Requires: `manage_themes`

1. PUT the theme files under lazysite/layouts/<layout>/themes/<name>/ over WebDAV (or use the MCP write_file tool on those paths)
2. call activate_theme (MCP) or POST action=theme-activate (control API)

## Author and activate a layout

Requires: `manage_layouts`

1. PUT layout files (view.tt, components) under lazysite/layouts/<name>/ over WebDAV
2. call activate_layout (MCP) or POST action=layout-activate (control API)

## Publish a page

Requires: `manage_content`

1. create the page with the MCP create_page tool, or PUT the .md over WebDAV in the content namespace
2. optionally preview_page (MCP) to confirm the render before it goes live

## Wire a form to a handler

Requires: `manage_forms`

1. call bind_form (MCP), or PUT lazysite/forms/<name>.conf over WebDAV, naming an operator-defined handler

