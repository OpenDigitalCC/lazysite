---
id: SM1250
title: "SM1250: a multi-step form no longer restyles a themed page"
subtitle: "lazysite-chrome.css carried the fallback template's page rules as bare element selectors, and a stepped form links that file under any layout. The page rules are scoped to the fallback's own body class now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-21
raised-by: the OOM Lab agent, inbox 2026-10-21-multistep-form-pulls-fallback-body-rules-over-the-theme.md
area: processor
status-note: "SHIPPED (PENDING) on n728: body.lazysite-fallback on the fallback template; every page rule in starter/assets/lazysite-chrome.css under it; t/unit/processor/148."
---

# What happened

`_form_step_css` (lazysite-processor/forms.pm, SM098/SM352) emits
`<link rel="stylesheet" href="/assets/lazysite-chrome.css">` with every
multi-step form. That file holds two things: the SM098 step rules, all under
`.lazysite-form[data-multistep]`, and the page chrome of the built-in fallback
template, which began `body { font-family: system-ui, sans-serif; max-width:
800px; margin: 2rem auto; padding: 0 1rem; color: #333; }` and went on with
bare `h1`, `pre`, `code`, `footer` and `a` rules.

The fallback template is not the only page that loads the file, as its own
comment assumed. Under a layout, the form's link comes after the theme's
stylesheet, so at equal specificity these rules won. Reproduced from the code:
a stepped form rendered under a layout links the file, and nothing in the file
stopped its `body` rule applying to that page. The lab saw every page with a
stepped form switch to the system font and an inset 800px column, and worked
around it in both its themes with `html body { ... }`.

# What shipped

- The fallback template (`$FALLBACK_LAYOUT`, lazysite-processor.pl) opens
  `<body class="lazysite-fallback">`. No layout sets that class.
- Every fallback page rule in `starter/assets/lazysite-chrome.css` is scoped to
  it: `body.lazysite-fallback { ... }` and `.lazysite-fallback <selector>` for
  the rest. Specificity order inside the file is unchanged (`.site-bar a` still
  beats `a`, `.nav-link` still beats `a`).
- The step rules are unchanged and unscoped by the class, so they apply under a
  layout as before.

The file stays one bundle (SM352's call); only who its page rules reach changed.

# Tests

t/unit/processor/148: every selector in the stylesheet is under
`body.lazysite-fallback` / `.lazysite-fallback`, or is a `.lazysite-form` rule;
the step rules are still present; a stepped form rendered with no layout links
the file and has the class on its body, and the same form under a layout links
the file and has no such class. With the stylesheet and the template reverted,
the scoping and the fallback-class assertions fail.
