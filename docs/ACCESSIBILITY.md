---
title: "lazysite - accessibility statement"
subtitle: "Conformance target and known state for the manager UI and shipped themes"
brand: plain
standard-margins: true
---

## Scope and target

This statement covers the two interfaces lazysite ships:

- the **manager UI** (`/manager` and its pages), the operator-facing application;
- the **default starter theme** used to render public site pages.

The target is **WCAG 2.1 Level AA**. This is a self-assessment, honest about what
has been verified and what has not - it is not an independent audit or a formal
conformance claim. Where a criterion is met by design it is stated; where it is
untested it is listed as such.

## What is verified

Colour contrast
: audited and held to a documented standard, light and dark. The manager's
  `--mg-*` colour tokens were chosen by computing relative-luminance contrast
  against their actual surfaces, not by eye, to meet AA (4.5:1 normal text,
  3:1 large text and UI boundaries). The method, targets and per-token audit are
  in [manager-colour-contrast.md](reference/manager-colour-contrast.md).

Visible focus (2.4.7)
: interactive controls show a focus indicator. Where the native `outline` is
  removed it is replaced with a focus-ring `box-shadow` (`--mg-focus-ring`) on
  buttons and form fields - focus is never suppressed without a replacement.

Semantic structure and landmarks (1.3.1, 2.4.1, 4.1.2)
: the manager document sets `lang="en"`, uses a landmark `<nav aria-label="Manager
  navigation">` and `<main>`, marks the current page with `aria-current="page"`,
  and uses native `<button>`, `<a>`, `<label>` and form controls rather than
  click-handler `<div>`s. Icon-only controls (command palette, theme toggle,
  notifications) carry `aria-label`; the command palette list uses
  `role="listbox"`.

Text resizing and reflow (1.4.4, 1.4.10)
: the layout uses relative units and flex/grid, so browser zoom and text scaling
  reflow rather than clip.

## Known limitations and untested areas

```datatable
columns: Area | State
widths: 6cm | X
bold: 1
tone: medium
text: 2
---
Independent assistive-technology testing (screen readers, voice control) | Not yet done - the assessment above is code-level, not AT-user-verified.
Keyboard operability of the modal dialog and command palette | Designed with native controls; focus-trap and Escape-to-close behaviour not yet verified end to end.
The shipped default theme (public pages) | Contrast and semantics inherit the token discipline, but themes are operator-replaceable - a custom theme is the operator's accessibility responsibility.
Motion / prefers-reduced-motion | Transitions are minimal; a `prefers-reduced-motion` audit is pending.
Formal WCAG 2.2 criteria | The target is 2.1 AA; the 2.2 additions (e.g. focus-not-obscured, target size) are not yet assessed.
```

## Operator responsibilities

- A **custom theme** replaces the default markup and CSS; its accessibility is
  the operator's to maintain. Keep the contrast method in
  `manager-colour-contrast.md` as the reference, and preserve semantic HTML.
- **Authored content** (headings, image `alt` text, link text) determines page
  accessibility as much as the theme. Use a logical heading order and describe
  images.

## Feedback

Accessibility problems in the manager UI or the default theme can be reported the
same way as any other issue (see the repo-root `SECURITY.md` for the reporting
channel; accessibility reports are not security-sensitive and may be filed
openly). This statement is revised as items above are verified.
