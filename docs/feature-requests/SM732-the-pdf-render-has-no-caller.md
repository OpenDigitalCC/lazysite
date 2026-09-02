---
id: SM732
title: "SM732: the PDF render has no caller"
subtitle: "SM706 shipped a plugin that converts a page to a branded PDF, refuses a composed document whose parts cannot all be read, and caches the result. Nothing calls it. Verified in the engine tree: convert() has no caller on any surface, and format=pdf appears nowhere at all."
brand: plain
standard-margins: true
status: candidate
---

# What is missing

Reported by the edge testing agent, 2026-09-02, after a session with a sysop UI
login. **Verified independently in the engine tree**, which is why this filing
is stronger than the report:

- **`plugins/pandoc.pl::convert()` has no caller.** Nothing in
  `lazysite-processor.pl`, `lazysite-manager-api.pl`, `lazysite-mcp.pl` or
  `lib/` reaches it.
- **`format=pdf` appears nowhere in the repository.** Not emitted, not consumed,
  not documented as a route.

The plugin's own actions are `init`, `status` and `clear`. None renders.

# So what DID ship, and what did not

**Shipped and working**: the dependency refusal. A host without `md-to-pdf` is
told so, by name, and the plugin stays off. That is what 8T-10 and 9T-06's
negative half proved on edge, twice, and it is genuinely good.

**Not shipped**: any way to obtain a PDF. `convert()`, the composed-document
refusal, the part-by-part `may_read` check and the cache that SM706 is *about*
are all present, tested at the unit tier, and unreachable.

`t/unit/plugins/41` passes because it calls `convert()` directly. **Eleven
sabotages of a function nothing invokes.**

# What I cannot explain, and am not going to guess

The agent observed the deployed beta emitting a Download-PDF link -
`href=".../pdftest/whole?format=pdf"` - on a page carrying a `parts:` list. **No
such link is emitted by anything in this repository.** It may come from a layout
or theme outside the engine tree, or from staged page content. I have not found
it and am not going to invent an explanation; whoever picks this up should
establish where that link comes from before assuming the wiring half-exists.

What is certain either way: **even when that link is followed, nothing routes
into `convert()`**, so the observed behaviour - the ordinary HTML page returned,
silently, with the parts not even assembled - is consistent with there being no
route at all.

# Why this was not caught

Three gates could each have caught it and none was looking:

- The unit tier tests `convert()` directly, so a missing caller is invisible.
- The test plans asked for the refuse-when-absent behaviour, which works, and
  deferred the positive path twice - first because `md-to-pdf` was not installed,
  then because installing it drove the host to 504s. **The deferral hid the
  gap**: two rounds reported "not proved" for an environmental reason when the
  feature had no trigger.
- `t/lint/85` requires every TOOL to declare its gate, but a plugin function
  that no surface exposes is not a tool.

**The general defect is worth more than this instance.** Nothing checks that a
plugin's declared capability is reachable. A lint asking "does every plugin
function the plugin describes have a route to it" would have failed the day
SM706 landed.

# What it needs

A decision first, not code: **where should a PDF be asked for?** A page route,
a manager action, an MCP tool, or the control API. SM706 assumed one existed and
its filing never named it.

Then the wiring, and then the test the two plans have been waiting to run:
`whole` with all parts readable expects one PDF containing both; `broken`
expects a refusal naming the missing part rather than a shortened PDF.

# Related

SM706 should be reopened rather than left `shipped`: what it claims is
demonstrably not reachable, and a filing marked shipped is a filing nobody
re-reads.
