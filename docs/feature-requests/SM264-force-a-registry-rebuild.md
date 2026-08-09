---
title: "SM264 - An agent can force a registry rebuild, so delete-then-verify is a workflow"
subtitle: "A delete clears the registries and rebuilds them on the next request. An agent that deletes and immediately checks the sitemap sees the old URL and reasonably concludes the delete failed."
brand: plain
status: shipped
status-note: "IMPLEMENTED 2026-08-09. From the site agent's 0.10.4 validation and the operator's disposition on SM251: the fix works but is silently deferred, and the remedy wanted is an ACTION rather than a better error message - waiting is not a workflow. Measured on 0.10.4: the page 404s at once, the URL was still in sitemap.xml at +20s, and had cleared shortly after."
---

# SM264 - force a registry rebuild

## Why

SM251 made a delete clear the generated registries for every content root. It
works. What it does not do is rebuild them on the same request - the processor
regenerates a missing registry when one is next fetched.

Measured on 0.10.4: the page 404s immediately, the URL was still in
`sitemap.xml` and `llms.txt` at +20 seconds, and had cleared when polled shortly
after. The four-hour `$REGISTRY_TTL` is not involved; the delete-triggered clear
is doing its job and simply does not land synchronously.

**The practical problem is what the caller concludes.** An agent deletes a page,
checks the sitemap, still sees the URL, and reasonably decides the delete failed -
or starts editing the generated registry by hand, which is what happened on
theunited.fund before SM251 existed. A bare `ok` is what made that a reasonable
conclusion.

## What shipped

**`regenerate_registries`** (MCP, `manage_content`) clears the generated
registries across every content root and reports which roots it touched, plus a
note that the rebuild happens on the next fetch. "Delete, regenerate, fetch,
verify" is then a complete sequence with no waiting in it.

**`delete_page` now says so.** Its result carries a `registries` field stating
that they are cleared, that the sitemap may still show the URL until the next
request, and what to call if you need to verify now. The operator's first
suggestion, kept alongside the second because a caller who never reads the new
tool's description still gets told.

Two details worth recording:

- The tool reuses the same invalidator the write paths use, so it clears **every
  content root** rather than the docroot's. A docroot-only clear is exactly the
  SM251 defect, and reimplementing it here would have reintroduced it.
- `cleared_roots` is site-relative, not filesystem paths - SM260's rule, checked
  in the test rather than assumed.

`Manager::Files` gained `invalidate_registries` and `registry_roots` as public
entry points. Reaching into the private `_`-prefixed subs from another file is
the coupling the underscore exists to discourage, and perlcritic said so.

## Not in scope

- A control-API twin. The need came from an MCP agent verifying a delete; the
  API path can gain one when someone asks. Recorded as a deliberate one-sided
  action in `t/lint/23`.
- Changing when the processor rebuilds. The asynchronous rebuild is correct - it
  keeps a delete cheap. What was missing was a way to ask for it.
