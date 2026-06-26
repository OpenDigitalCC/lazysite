---
title: "SM098 - multi-page (wizard) forms"
subtitle: "Multi-step forms that collect across pages and submit once"
brand: plain
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

Queued. Bounded for the linear case: a renderer change in `_render_form` plus a
small step-navigation script; no change to delivery.
