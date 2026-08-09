---
title: "SM250 - A theme can make a site's content invisible, and only a script reveals it"
subtitle: "opacity:0 by default with a scroll script adding the reveal class. Remove the script and every section vanishes for everyone - and the reduced-motion rule that looks like a safety net is not one."
brand: plain
status: shipped
status-note: "IMPLEMENTED 2026-08-09. All three asks: create_theme already warned (SM243), audit_site now reports hidden_by_script for INSTALLED themes, and the layouts briefing states the pattern and the reduced-motion trap explicitly. Detection deliberately rough - the pattern is distinctive, and a false positive costs ten seconds while a false negative costs a live site its content. A prefers-reduced-motion rule does NOT count as a fallback, which is the specific thing that misled the reporter. Reported by the sjm-claude-code site agent 2026-08-08 after leaving every section of a live site permanently invisible. Worth a guardrail because the failure is silent, total, and survives casual checking - the hero was unaffected, so four successive visual checks looked fine. It is also an accessibility and crawler problem in its own right, independent of the incident."
---

# SM250 - a theme can hide content behind a script

## Why

A theme may carry a scroll-reveal pattern:

```css
.rv    { opacity: 0; transform: translateY(22px); }
.rv.in { opacity: 1; transform: none }
```

with an in-page script adding `.in` as sections enter the viewport. Content is
invisible **by default** and visible only once JavaScript has run.

A third rule appears to neutralise it:

```css
@media (prefers-reduced-motion: reduce) { .rv { opacity: 1 } }
```

It does not. It applies only to visitors who have asked for reduced motion. On a
quick read it looks like the animation has already been made safe, which is
exactly how the reporting agent read it - they removed the page script while
moving chrome into the layout, and left every section of a live site permanently
invisible for everyone else.

The hero sat outside the pattern and was unaffected, so **four successive checks
looked fine.** That is what makes this worth a mechanical guardrail rather than a
note: the failure is silent, total below the fold, and survives the obvious way
of verifying.

## It is a defect even when nothing is removed

Independent of the incident, content that is `opacity: 0` until a script runs is
invisible to:

- a visitor with JavaScript disabled or blocked,
- many crawlers, which do not execute page script,
- anything reading the page for text extraction.

So the pattern degrades badly on its own terms. The site looks complete to its
author and is empty to a meaningful fraction of what reads it.

## Shipped 2026-08-09

`audit_site` returns `hidden_by_script`: installed themes whose CSS sets
`opacity: 0` or `visibility: hidden` with no non-script path back to visible.
This is the half that was missing - `create_theme` already warned at write time
(SM243), but that does nothing for a theme already on a site.

**A `prefers-reduced-motion` rule does not count as a fallback.** Reduced-motion
blocks are stripped before looking for one, because reading that rule as a
neutraliser is exactly what caused the incident. `.no-js`, `html:not(.js)` and
`noscript` do count.

Deliberately rough, per this filing: a fractional opacity is not the zero case,
`visibility: hidden` is the same failure in a different property, and a theme
that hides nothing raises nothing - all pinned in t/unit/mcp/17.

The layouts briefing now states the pattern, names the reduced-motion trap, and
gives the two acceptable shapes (start visible, or provide a `<noscript>` path).

## What to add

### `audit_site` reports script-revealed content

Report a theme or page CSS rule that sets `opacity: 0` (or
`visibility: hidden`) on a content selector with no non-script path to
visibility. Detection does not need to be perfect - the pattern is distinctive,
and a false positive costs an operator ten seconds while a false negative costs a
live site's content.

This pairs with SM244, which already extends `audit_site` to report what the
site knows about itself; the same pass can carry it.

### `create_theme` warns on write

SM243 establishes the shape: warn at the moment of writing, not only in a
briefing an agent read once. A theme whose CSS hides content by default is worth
a warning naming the consequence - no-JS visitors and crawlers see nothing -
without refusing it, because the pattern is legitimate when the reveal has a
non-script fallback.

### Say it in the layouts briefing

Two sentences: a reveal animation must start from a visible state, or provide a
`<noscript>` path; and **a rule inside `prefers-reduced-motion` is not a
neutraliser** - it applies to a minority of visitors and is the specific thing
that misled a careful reader here.

## Verification

- A theme using the opacity-0-plus-script pattern is reported by `audit_site`.
- A theme whose reveal starts visible, or provides a non-script fallback, is not.
- `create_theme` warns without refusing.
- The layouts briefing states the reduced-motion trap explicitly.

## Not in scope

- Refusing the pattern. It is legitimate with a fallback, and a platform that
  refused it would be wrong more often than the authors it protected.
- Any general CSS linting. This is one distinctive, high-cost pattern, not the
  start of a stylesheet checker.
