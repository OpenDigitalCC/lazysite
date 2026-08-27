---
title: "SM413 fix: an upgrade invalidates rendered pages"
subtitle: "A cached page regenerates when its SOURCE changes, and an upgrade changes no source - so a page nobody edits kept its pre-upgrade render for ever. The installer already knew the rule and applied it on rollback only."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-20, the release manager choosing 'upgrade invalidates renders' over a documented operator step - the field had just demonstrated that the step gets forgotten, four releases running. THE ASYMMETRY REMOVED: install.pl's ROLLBACK path already dropped rendered HTML, with the reason written beside it ('content at the pre-upgrade version may reference state that no longer matches'), and the UPGRADE path did not. One helper now serves both. SCOPE, deliberately narrow: only rendered .html is dropped, never the cache tree - per-host mirrors and other cache state have their own lifecycles, and this is a re-render trigger rather than a reset. Pages re-render on next request, so the cost is one render per page actually visited, not a whole-site rebuild at upgrade time. Runs on mode 'upgrade' only: a fresh install has nothing rendered, and a same-version REINSTALL is excluded on purpose because the renders already came from that code. TEST GOTCHAS, both recorded in t/tools/03: installing twice is a REINSTALL, not an upgrade (the first draft never reached the path it tested), and the fixture site must be put on the edge channel or the ladder correctly SKIPS the upgrade - by replacing the seeded update_channel line rather than appending, since the reader takes the first match."
---

# The field case

`/` on edge served a render produced under 0.10.13 through the 0.10.14, .15,
.16 and .17 deployments, and was corrected only when an operator invalidated
the index by hand. The headers were right throughout; the engine was serving
its own stale artefact.

::: widebox
The homepage is the page least likely to be edited and the first one an
operator checks after an upgrade. Both facts point the same way, which is why
this presented as "the upgrade did not take".
:::

# Verification

`t/tools/03-install-pl.t`: a genuine version-change upgrade against a site on a
channel that accepts the build, with rendered pages and a per-host copy dropped,
non-render cache state surviving, and a fresh install staying silent. Two
sabotages bite - no invalidation on upgrade, and an over-eager clear that takes
non-renders with it. A third (firing on fresh installs too) is not exploitable
and is recorded as such rather than papered over.
