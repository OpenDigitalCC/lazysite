---
title: "SM098 - multi-page (wizard) forms"
subtitle: "Multi-step forms that collect across pages and submit once"
brand: plain
status: shipped
status-note: "landed across 1 release(s), 0.6.1 .. 0.6.1"
---

## What

Support multi-step / wizard forms: a single logical form split across several
screens (Next / Back), validated per step, submitted once at the end. Today a
`:::form` renders one single-page HTML form.

## Why

Raised 2026-06-26. Longer enquiry / application / onboarding forms are friendlier as
steps than one long page.

## Shape (sketch)

- Author syntax: either one `:::form` with step delimiters (e.g. `--- step ---`
  between field groups), or `:::form-step` blocks within a `:::form`. The processor
  renders all steps into one `<form>` with each step a `<fieldset>`; a small bundled
  script shows one step at a time with Next/Back and a progress indicator, validating
  the visible step before advancing.
- Submission is unchanged: the whole form posts once to the existing handler (the
  HMAC token, honeypot, and delivery binding all stay the same) - the multi-step is
  purely a client-side presentation over one submission, so no server change to the
  form handler is needed.
- Per-step `required`/`pattern` validation uses the native constraint API before
  allowing Next; the final step submits.
- Progressive enhancement: with no JS, all steps show as plain sections and still
  submit (graceful degradation).

## Open questions

- Conditional steps (skip a step based on an earlier answer) - a later enhancement;
  v1 is linear steps.
- Save-and-resume across sessions - out of scope for v1 (would need server state).

## Status

**Done (2026-07-04).** Linear multi-step forms ship. Author syntax: a
`--- step ---` line (optionally titled, `--- step: Contact details ---`) inside a
`::: form` splits the fields into steps. `_render_form` wraps each step in a
`<fieldset class="lsf-step">` (titled steps get a `<legend>`), adds a progress
indicator and Back/Next nav, and emits a step-navigation script that shows one
step at a time and validates the visible step (native constraint API) before
advancing. No delimiter = the classic single-page form (unchanged output).
Delivery is untouched - the whole form still posts once to the handler with the
same token/honeypot. Progressive enhancement: without JS every step shows and the
form still submits. Conditional steps and save-and-resume remain out of scope
(the open questions above).
