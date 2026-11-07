---
id: SM1378
title: "SM1378: a layout says the engine it needs, and the engine reads it"
subtitle: "The layouts catalogue writes requires.lazysite in every layout.json and the engine read it nowhere, so a layout installed on an older engine said ok:1 and failed at render time. Installing and activating now warn, as SM337 does, and never refuse."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (ruling 133, triage T-31)"
area: layouts
status-note: "SHIPPED (0.16.6) on n760, ruling 133: Themes::layout_engine_requirement reads layout.json requires.lazysite against .install-state.json; install, activate and a domain's layout binding warn and go ahead. t/unit/manager/470."
---

# What happened

Every `layout.json` in the layouts catalogue carries
`"requires": { "lazysite": "0.15.11" }`: the lowest release whose template
variables and filters the layout uses. The catalogue's README says the engine
does not read it, and it did not. A layout installed on an older engine answered
`ok: 1`, then failed or rendered without parts at request time (an unknown
filter is a template error).

# What shipped

Ruling 133:

- **Read.** `requires.lazysite` is compared, segment by segment, with the site's
  running engine (`.install-state.json` `version`, the value the generator meta
  and `action_version` report).
- **Warn, never refuse** (as [[SM337]] for a layout with no `[% nav %]`). The
  layout installs and activates; the answer carries `requires` and a `warning`
  naming both versions.
- **Where:** `_install_layout_from_dir` (every install path: the catalogue
  manifest install, the release zip install, MCP `install_layout`), reading the
  release being installed; `action_layout_activate` (beside SM337's note when
  both apply); `domain_set` for a domain's `layout` (in its `warnings`).
- **Nothing to compare, nothing said:** no `requires`, or no install state (a
  development tree). A value that is not a version is named in the warning.

# Not changed

The catalogue's README still says the engine does not enforce the key; that is
the catalogue's text to update (it now reads it, and warns).
