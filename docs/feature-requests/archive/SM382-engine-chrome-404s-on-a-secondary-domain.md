---
title: "SM382: the engine's chrome 404s on a content-rooted secondary domain"
subtitle: "SM352 moved the engine's own script and stylesheet into /assets/, which ship into the docroot. Static resolution is content-root scoped, so on a secondary domain the bundle never loads - and the frame suppression, auth-control sync and form handling stop with nothing to say so."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19 on claude/sm382-chrome-on-secondary-domains, before the cut. A regression from SM352 steps 1-3, found by the pre-beta review and reproduced on a two-root fixture: 200 on the primary, 404 on the secondary. Engine-owned assets now resolve from the DOCROOT even under a content root, by an EXPLICIT LIST of paths rather than a prefix - a general fallback would be a way out of the SM151 confinement, and the test asserts a non-engine file is still refused."
---

# What broke

SM352 steps 1-3 moved the engine's chrome out of inline blocks and into
`/assets/lazysite-chrome.css` and `.js`. Those ship into the **docroot**.

Static resolution is content-root scoped (SM151) and refuses anything
outside the root, so a domain with its own `content_root` looks for the
bundle under **its** root, does not find it, and 404s.

::: widebox
**Nothing reports it.** The script carries the frame suppression, the
SM099 auth-control sync, and the form submit and multi-step handling.
They do not fail - they never load. There is no error on the page, no
entry in the log an operator reads, and the site otherwise renders
perfectly.
:::

Measured on a two-root fixture: **200 on the primary, 404 on the
secondary.**

# The fix

Engine-owned assets resolve from the docroot even under a content root,
because they are the engine's, not the site's.

**By an explicit list of paths, not a prefix.** A prefix would let a
future file under `/assets/` inherit an exemption nobody decided to give
it, and a general docroot fallback would be a way out of exactly the
confinement SM151 exists to enforce - a content-rooted domain reading
its siblings would be a far worse defect than this one.

# A note on the fixture, because it failed three times first

An alias content root applies **only** when the host is also declared in
`alias_hosts`. Three versions of this fixture omitted that, served every
request from the primary, and returned 200/200 - which reads exactly
like an absence of defect.

`t/unit/processor/41` therefore opens with a control subtest that proves
the secondary really is on its own root, by serving a marker only that
root has. Without it the result cannot be believed in either direction.

# Verification

- Primary and secondary both serve the bundle.
- A non-engine file in the primary is still refused to a secondary
  domain; widening the list to a prefix fails that subtest.
- Removing the fallback fails the secondary case and nothing else.

# Related

[[SM352]] (the move that caused it), [[SM151]] (the confinement this
must not weaken), [[SM099]] (one of the behaviours that silently stopped).
