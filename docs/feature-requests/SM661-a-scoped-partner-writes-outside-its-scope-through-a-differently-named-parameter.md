---
title: "SM661: a scoped partner creates and moves content outside its scope, because the confinement check inspects three parameter names and two MCP tools use others"
subtitle: "Found 2026-08-27 while auditing path_aware for SM653. Measured on a real dispatcher with a real scoped grant: write_file is refused and create_page succeeds, into the same directory"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED, same day it was found. Every argument that can carry a content path is named ONCE in Lazysite::Manager::Common::@PATH_ARGS - path, to, from, slug, old, new - and all THREE places that inspect one read it: the SM155 scope pass, the SM268 H4 carve-out pass, and the call-time themes/layouts override. Measured before and after on a real dispatcher: a grant scoped to /sites/alpha now gets the same refusal from create_page and rename_page that it always got from write_file, and nothing is written or moved. NOT OVER-CONFINED, which is the failure that would have been reported as an outage rather than found by an audit: the same grant still creates inside its own scope, and an unscoped grant is unaffected. Both asserted. A LONGER HARDCODED LIST WOULD BE THE SAME DEFECT IN A YEAR, so t/lint/91 refuses a path_aware tool that declares a property the list does not have an answer for - a new path-shaped argument is now a decision, not a discovery - and asserts that no confinement pass has reverted to a literal qw(path to from). ALSO CORRECTED, from the same audit: path_aware is removed from audit_site, read_nav, list_pages and regenerate_registries, which declare no path-shaped argument at all - so the override could never fire for them at call time while making them visible to a themes-only grant at listing time. 27 path_aware tools down to 23, and every remaining one genuinely takes a path. Three sabotages: restoring the old list fails 5 behavioural assertions and 3 lint ones; treating title/body as paths fails the not-over-confined pair; reverting one pass to a literal fails the lint."
---

# Measured

A grant holding `manage_content` + `mcp`, `dav_scopes: ['/sites/alpha']`:

| Call | Path parameter | Result |
|---|---|---|
| `write_file {"path":"/sites/beta/x.md"}` | `path` | **refused** - *"outside your assigned scope (sites/alpha/)"* |
| `create_page {"slug":"sites/beta/sneaky"}` | `slug` | **succeeded** - wrote `/sites/beta/sneaky.md` |
| `rename_page {"old":"sites/alpha/p","new":"sites/beta/moved"}` | `old`/`new` | **succeeded** - moved the page into beta |

The refusal proves the confinement works and the grant is genuinely scoped, so
the two successes are not a misconfigured fixture.

# The cause

Two passes in the MCP dispatcher confine a call, and both iterate the same
hardcoded list:

    for my $pk (qw(path to from)) {

`create_page` declares `slug`. `rename_page` declares `old` and `new`. Neither
is inspected, so neither is confined - by the scope pass or by the carve-out
pass that SM268 H4 added for `nav.conf` and the submission store.

Nothing is malformed. The calls are well-formed, the tools do exactly what they
advertise, and the confinement simply never looks at the argument that carries
the path.

# Why it was not obvious

`path_aware` reads like the flag that makes a tool confined, and both these
tools carry it. They do. The flag governs the *themes/layouts override*, which
is a different question, and it is set on 27 tools regardless of what their
parameters are called - which is what made the audit for SM653 worth doing and
what turned it up.

# The fix, and the part that must not drift

Inspecting a longer list is the fix and would be the same defect again in a
year: a hardcoded set of parameter names is exactly what failed here, and the
next tool with a differently-named path argument reintroduces it silently.

So the list is named once, and a **lint refuses a `path_aware` tool whose
schema declares a property the confinement passes do not know about** - forcing
a decision when a new path-shaped parameter appears rather than discovering it
from a probe. That is the same shape as SM654's answer to the `unlocks` map.

# What must be true afterwards

- `create_page` and `rename_page` are refused outside scope, with the same
  message `write_file` gives.
- A scoped grant can still create and rename *inside* its scope - the fix must
  not confine a partner out of its own content.
- An unscoped grant is unaffected.
- The lint fails if a `path_aware` tool gains an uninspected property.
