---
id: SM1289
title: "SM1289: a form under any theme has base styles the theme overrides"
subtitle: "Under a theme with no form rules, a stepped form's fields and buttons were the browser's own. The engine now links zero-specificity :where() base rules on any page with a form, layout or not, so a theme overrides any of it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "edge observation O-4; the release manager, ruling 30 (2026-10-23)"
area: processor
status-note: "SHIPPED (PENDING) on n735: native-form base rules in lazysite-chrome.css, each selector a :where(); _inject_form_base links the file first in the head of a layout's page with a form and drops the stepped form's later copy; t/unit/processor/161, t/unit/processor/148."
---

# What happened

On edge, under lumen - a theme that writes nothing about forms - a stepped
form's fields were narrow browser inputs, its buttons were the browser's grey,
and its step fieldsets wore the browser's grooved border (O-4). SM1250 had just
scoped the chrome's page rules to the fallback, correctly, which left a themed
site's forms with nothing at all unless the theme styled them. Q30 asked whether
that is each theme's job or the engine's; ruling 30: zero-specificity base
styles, loaded on any page with a form, so a theme overrides any of it.

# What shipped

- `starter/assets/lazysite-chrome.css` has a native-form base block. It covers
  the `::: form` markup (`.lazysite-form`: field spacing, labels, full-width
  text inputs, textareas and selects, the option lists, buttons in the page's
  font, the submit row, the step fieldsets and legends, the status line) and the
  sign-in pages' forms (`.login-form`, `.claim-form`, `.reset-form`), plus the
  error and context lines (`.form-status-error`, `.auth-error`,
  `.login-context`).
- **Every selector is a `:where()`**, so every rule has zero specificity: the
  lowest-specificity rule a theme can write about the element, a single type
  selector, beats it. No rule sets a colour beyond `currentColor` and `inherit`,
  and none sets a background, so a theme never has to undo one.
- **Loaded on any page with a form.** The fallback template links the file
  already. Under a layout, `_inject_form_base` (lazysite-processor/layout.pm)
  links it when the rendered markup has a form of one of those classes - the
  markup decides, as it does for the data helper - and puts the link first in
  the head, after the charset, ahead of the layout's own stylesheets, so a
  theme's own zero-specificity rule (`*`, or a `:where()`) wins by order too.
  The stepped form's in-body link (SM098, SM1252) is dropped when the head
  carries one, since a second copy after the theme would put the base rules
  after it again. A layout's own search box in its header is not one of those
  forms, so a themed site does not fetch the file on every page.
- The fallback rules (SM1250, SM1251, SM1288) are more specific, so a site with
  no layout looks as before.
- `docs/features/configuration/themes.md` says what the base gives and that a
  theme's rule always wins.

# Tests

- t/unit/processor/161: parsed from the stylesheet, the base rules are present,
  every selector of every one is made only of `:where()` (and the combinators
  between them), none sets a colour beyond `currentColor`/`inherit` or any
  background, and the ruling's five areas are covered; rendered, a one-step and
  a stepped form under a layout and theme link the file first in the head and
  once, a page with no form does not link it, the login page under a layout
  links it, and a form with no layout has it through the fallback. With the
  stylesheet and layout.pm as before, 13 assertions fail; with only the
  injection reverted, 6.
- t/unit/processor/148 splits selector lists at their top-level commas (a
  `:where()` holds a list) and accepts a zero-specificity rule as one that
  cannot restyle a layout's page.
