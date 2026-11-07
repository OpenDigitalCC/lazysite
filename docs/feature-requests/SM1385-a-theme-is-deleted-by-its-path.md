---
id: SM1385
title: "SM1385: a theme is deleted by its path, under any layout"
subtitle: "delete_theme, theme-delete and the manager's Themes page found a theme only under the active layout, so a theme under another layout was removable only file by file. They take the theme's path, as theme-copy does, with the same refusals."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent (0.16.7 small fixes)"
area: themes
status-note: "SHIPPED (0.16.7) on n764: action_theme_delete takes lazysite/layouts/<layout>/themes/<name>; a served-copy path is refused by served_artifact_refusal; the Themes page deletes by path under every layout. t/unit/manager/471."
---

# What happened

`action_theme_delete` (control API `theme-delete`, MCP `delete_theme`, the
manager's Themes page) looked for the theme under the active layout's `themes/`
only (D013). A theme under any other layout - an old layout's themes, a theme
installed under several layouts - could be removed only by deleting its files
one at a time, or by activating that layout first. `theme-copy` has taken a
theme by its path since SM1339; delete took only the name.

# What shipped

**By path.** `theme-delete`'s `path` and `delete_theme`'s `theme` accept
`lazysite/layouts/<layout>/themes/<name>` (leading and trailing slashes allowed),
and the layout in the path is the layout. The bare name still means the active
layout's theme, so every existing caller is unchanged. The answer names the
`layout` and `path` deleted.

**The same refusals.**

- The active theme (the primary's layout and theme) is refused by path as by name;
  the same name under another layout is not the active theme.
- A theme any domain serves under that layout (`domains_using`, effective values) is
  refused, naming the domains (SM177).
- Over MCP and for a token or a domain-confined manager, only a theme this account
  made (SM262, SM268): the side record is read for the layout the path names.
- A path into a host's served copy (`.../lazysite-assets/<layout>/<theme>`) is
  refused by `served_artifact_refusal`, kind `served-artifact-refused`, naming the
  source to act on; any other path that is not a theme's is refused, saying so.

**The manager.** The Themes page offered Delete only under the active layout. It
now offers it on every theme no domain serves, under every layout, and sends the
theme's path.

# Tests

t/unit/manager/471: through the control API as a cookie manager, a path deletes
under the named layout and leaves the same name under the active layout; the bare
name deletes under the active layout; the active theme by path is refused and the
same name under another layout is deleted; a theme a domain serves under that layout
is refused naming it; a served-copy path is refused naming the source; a layout file
path is refused. Creator-restricted, a record under another layout does not count
and the theme's own does. With Themes.pm as on main the path forms are refused as
malformed names.

t/lint/218: theme-delete leaves `%NOT_INSTANCE_WIDE`, since it now asks the
served-artifact rule, which asks the domain rule.
