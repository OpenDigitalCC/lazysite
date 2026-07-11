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

## Switch the site to a different layout

Requires: `manage_layouts`

1. call list_layout_catalogue (MCP) or GET action=layouts-manifest (control API) to see what is available and installed
2. call install_layout (MCP) or POST action=layout-install (control API) - it installs AND activates the new layout in one step
3. ONLY THEN, if the old layout is no longer wanted: delete_layout / layout-delete. Deleting the ACTIVE layout is always refused - install/activate the replacement first, never delete first

## Undo a content change (restore a recorded version)

Requires: `manage_content`

1. call list_versions (MCP) or GET action=git-history (control API) for the file - needs the site's Content history plugin enabled
2. call view_version / git-show to confirm the version (content + diff against the current file)
3. call restore_version / git-restore - the historic content is saved back through the normal save path and the restore itself becomes the newest version, so nothing is lost

## Publish a page

Requires: `manage_content`

1. create the page with the MCP create_page tool, or PUT the .md over WebDAV in the content namespace
2. optionally preview_page (MCP) to confirm the render before it goes live

## Wire a form to a handler

Requires: `manage_forms`

1. call bind_form (MCP), or PUT lazysite/forms/<name>.conf over WebDAV, naming an operator-defined handler

