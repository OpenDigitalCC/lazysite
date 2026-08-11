---
title: "SM282 - Preview a draft section as the public sees it"
subtitle: "The fourth item of SM267's panel. An editor can see a draft section because they are signed in, which is exactly why they cannot tell what a visitor gets."
brand: plain
status: candidate
status-note: "SPLIT from SM267 on 2026-08-11 when the operator found the panel could not create a protected section at all. That gap (SM267 item 2) was fixed on the spot; this one - item 4 - is filed rather than rushed in behind it. NOT STARTED."
---

# SM282 - preview a draft section as the public sees it

## Why

A draft section is invisible to the public and visible to a signed-in editor.
That is the feature working. It is also why the editor is the one person who
cannot check it: everything looks fine from where they are standing.

The current answer is to open a private browsing window, which works and is what
`docs/MANUAL-CHECKS.md` tells a reviewer to do. It is a poor answer for an
operator doing this routinely - it means leaving the manager, and the thing being
checked is precisely whether leaving the manager changes what you see.

## What

A **Preview as public** control on each draft row of the Protected sections
panel, rendering the section's index page as an anonymous visitor would receive
it - including the 404, which is the correct and expected result and should be
shown as such rather than as an error.

The machinery exists: `domain-preview` already shells the processor with no auth
headers to render a domain as a public visitor, precisely so an operator can see
a domain before DNS points at it. This is the same trick at page scope.

## Care needed

**The preview must not become a way to read a gated section.** Rendering
anonymously is safe by construction - the processor applies the same refusal it
would to a visitor - but the control must render through that path rather than
around it. A preview that fetched the file and displayed it would be a read
bypass wearing a preview's clothes, on the one panel whose entire subject is
access control.

So: the acceptance is not "the operator can see the draft page". It is "the
operator sees exactly what a visitor sees, including nothing".

## Acceptance

- A draft row offers Preview as public; the result is the anonymous render.
- For a draft section that is a 404 to the public, the preview SHOWS the 404
  rather than reporting a failure.
- A gated (non-draft) section previews as the sign-in bounce a visitor gets.
- The preview reads through the processor's public path, so no new read surface
  is introduced. A test asserts that a preview of a gated section does not return
  its content.

## Related

[[SM267]] (the panel; items 1-3 shipped), [[SM181]] (the engine half),
[[SM223]] (static files under access control - the same question for assets),
`domain-preview` in the control API.
