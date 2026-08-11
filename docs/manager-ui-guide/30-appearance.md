---
title: "Appearance"
brand: plain
---

# Appearance

Governing capabilities: `manage_themes` or `manage_layouts` - either opens the
page, and the controls inside are gated separately.

## Choose a theme

Where
: Content -> Appearance

Do
: Preview a theme, then activate it. Check the public site on a hard reload.

Expect
: The theme list shows what is installed per layout and which is active.
  Activating rewrites the site's theme key, mirrors the theme's assets into the
  served tree, and clears cached renders. Static assets carry a long cache life,
  so the reload matters - a stale sheet after a theme change is the cache doing
  its job, and the `?v=` busting is what resolves it.

Negative
: With `manage_layouts` but not `manage_themes`, the theme controls are inert and
  say which grant is missing.

## Install and manage layouts

Where
: Content -> Appearance -> layouts

Do
: Install a layout from the configured repository, activate it, then try to
  delete the one in use.

Expect
: The catalogue lists available layouts and releases. Activating switches the
  site and re-offers only the themes that layout carries. Deleting a layout in
  use by any domain - including a sub-domain - is refused, and the refusal names
  the domain holding it.

Negative
: Without `manage_layouts`, installation and deletion are unavailable while theme
  selection still works.

## Upload a theme

Where
: Content -> Appearance -> upload

Do
: Upload a theme archive, including one containing a path that escapes its own
  directory.

Expect
: A well-formed archive installs and appears in the list. A traversing archive is
  refused outright rather than partially extracted.

Negative
: The upload control is absent without `manage_themes`.

## No CDN

Where
: Content -> Appearance, any bundled theme

Do
: View source on a public page and look for third-party origins.

Expect
: None. Fonts are bundled under OFL or Apache licences and served from this site.

Negative
: This is a standing product rule with **no gate in this repository** - nothing
  in `t/` looks for a third-party origin in a theme. So the check is genuinely
  manual, and it is most needed on a theme an operator uploaded or hand-edited,
  which no gate would have seen anyway.
