---
id: SM1336
title: "SM1336: every served copy of a theme carries its tokens and its version"
subtitle: "An installed theme and a copied theme had their served copy built by hand: assets/ alone, or the docroot copy of the theme it came from. Neither carried a theme-tokens.css or a fingerprint of its own, and neither reached a secondary domain. Both now write the copy the one way every other copy is written."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the sites agent (gallery redeploy observations, §2); ruling 81 (Q13) with triage T-39"
area: themes
status-note: "SHIPPED (0.16.5) on n747: Manager::Themes::_install_theme_from_dir and action_theme_copy call _mirror_theme_assets. t/unit/manager/431."
---

# What happened

The gallery filing: a served copy written by WebDAV carried no `theme-tokens.css`
and no fingerprint, so its pages inlined their tokens and linked `?v=<engine
version>` rather than the theme's own hash (SM830), and a later edit of the theme
was served from cache until the engine version changed. SM1339 closes the WebDAV
write; two engine paths built the same kind of copy:

- **An installed theme** (the manager's Upload Theme, MCP `install_theme`):
  `_install_theme_from_dir` copied `assets/` alone into the docroot's
  `/lazysite-assets/<L>/<T>/` - no tokens, no fingerprint, and no copy under any
  content root (SM734).
- **A copied theme** (`theme-copy`, `copy_theme`): copied the docroot's copy of
  the theme it came from, if there was one - no copy on any secondary domain, and
  none anywhere when the source had never been mirrored.

# What shipped

Both call `_mirror_theme_assets`, the function every other copy is written by,
from the theme just installed or copied: build beside and switch (SM756),
`theme-tokens.css` from its own theme.json (SM352), its fingerprint (SM830), every
content root, and SM1335's refusal of a link. With SM1335 (every source write
re-mirrors) and SM1339 (no write into a copy), no copy is written any other way.

# Tests

t/unit/manager/431: an installed theme's and a copied theme's copies, in the
docroot and under a secondary domain's content root, each carry
`theme-tokens.css` (with the theme's own values) and `.fingerprint`. With
Themes.pm as on main the installed theme's copies lack both and the secondary
domain has neither copy.
