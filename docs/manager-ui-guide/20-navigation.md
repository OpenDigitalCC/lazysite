---
title: "Navigation"
brand: plain
---

# Navigation

Governing capability: `manage_nav`, to save. Reading the menu needs no
capability beyond manager access - `nav-read` on the control API and `read_nav`
over MCP alike - and shows only the domains the reader reaches (SM943 ruling 2,
SM976). `manage_content` grants nothing nav-specific.

## Edit the menu

Where
: Site -> Navigation

Do
: Add an item, reorder two, nest one under another, and save. Then visit the
  public site.

Expect
: The editor shows the current menu. Saving writes `lazysite/nav.conf` and the
  change appears on the next public render, cached pages included - a nav edit
  invalidates them.

Negative
: Without `manage_nav` the item is greyed with a padlock for a user who could
  grant it, and absent for one who could not. Over WebDAV, `lazysite/nav.conf` is
  the one file inside `lazysite/` a `manage_nav` holder may write - and a partner
  holding only `manage_content` is refused it.

## Per-domain navigation

Where
: Site -> Navigation, with more than one domain configured

Do
: Switch to a secondary domain and give it its own menu.

Expect
: The secondary serves its own nav; the primary is unchanged. A domain with no
  override inherits the primary's, and the editor says which of the two it is
  showing.

Negative
: A scope-confined manager can only reach the navigation of domains inside their
  scope.
