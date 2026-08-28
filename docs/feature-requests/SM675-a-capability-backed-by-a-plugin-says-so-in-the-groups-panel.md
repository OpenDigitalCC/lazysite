---
title: "SM675: a capability that only works while a plugin is enabled should say so, or not be offered"
subtitle: "Release manager, 2026-08-28: 'groups that require modules should say so - if switching on data tables, it should check that the plugin is enabled ... whichever policy fits best with the proposed cleaner plugin infrastructure'"
brand: plain
standard-margins: true
status: candidate
---

# The gap

`manage_data` grants nothing while the data plugin is disabled. `manage_briefs`
grants nothing while the briefs plugin is disabled - every brief action returns
"The briefs plugin is disabled" before it looks at capabilities at all.

The Groups panel offers both as ordinary checkboxes. An operator grants one,
the grid shows it on, `whoami` reports it held, and the surface refuses. Nothing
anywhere says the grant is inert.

# The engine already knows

This is the part that makes the request small. A plugin DECLARES what it owns,
and the declaration is validated:

- `plugins/data.pl` - `owns => { capabilities => ['manage_data'] }`
- `plugins/briefs.pl` - `owns => { capabilities => ['manage_briefs'] }`
- `lib/Lazysite/Plugins/Owns.pm` (ADR 0009) reads and validates it
- `whoami` already consults it, to decide who may see a plugin's `_enabled`
  state

So the mapping from capability to owning plugin exists and is authoritative.
The Groups panel simply never asks.

# And the pattern exists too

SM180 solved the identical problem one axis over: a CHANNEL that is granted
while its site service is switched off is marked dormant in the grid, with a
tooltip saying an admin must enable the service in Settings for the grant to
take effect.

    if (isChannel && caps[c[0]] && channelServices[c[0]] === 0) { ... dormant ... }

A capability whose plugin is disabled is the same statement about a different
switch. The cheapest correct version of this request is that condition, widened.

# The two policies, and which fits

The request offers both. They are not equivalent.

**Mark it dormant** (SM180's shape)
: The capability stays visible and grantable; granting it while the plugin is
  off shows the warning. An operator can prepare a group before enabling a
  plugin, and a grant that already exists does not vanish from the grid when a
  plugin is switched off - it explains itself.

**Hide the capability when its plugin is off**
: Tidier at first glance, and wrong in the case that matters: a group that
  ALREADY holds `manage_data` keeps holding it, and hiding the row means the
  operator cannot see, audit or revoke a grant that is still recorded in the
  store. It also makes the grid's contents depend on plugin state, so two
  instances with the same groups show different rows.

**Recommendation: mark it dormant.** Hiding a grant that exists is the failure
mode this project keeps finding elsewhere - SM439 and SM615 both widened the
Sessions and Keys pages on the principle that there be no hidden case where
access is active or potentially active, and SM668 closed the last one this
month. A capability held but inert is exactly such a case.

# Where it belongs

The release manager's own framing: add it to the cleaner plugin infrastructure
rather than as a standalone change. That is [[SM640]]'s line-list and
per-plugin modal, which is where a plugin's state becomes a thing the manager
UI reads per plugin rather than renders inline for all of them.

The natural shape once that exists: the Groups panel asks the same question the
Plugin Config page asks - is this plugin enabled - and the capability grid marks
any capability whose owning plugin answers no. One source (`owns`), one
question, two pages.

# What it needs

1. `plugin-list` (or `group-settings-get`) to carry the capability-to-plugin
   map and each plugin's enabled state, the way `channelServices` is already
   carried for channels.
2. The dormant condition in `groups.md` widened from channels to any capability
   whose owning plugin is off.
3. The tooltip to name the plugin and where to enable it, as SM180's does for a
   service.

Not needed: any change to enforcement. The surfaces already refuse correctly -
this is about the grant not being silently inert.

# Related

[[SM180]] (the dormant-channel marker this copies), ADR 0009 / `Owns.pm` (the
declaration this reads), [[SM640]] (the plugin infrastructure this should land
with), [[SM668]] / SM439 / SM615 (no hidden case where access is active or
potentially active - the argument against hiding).

# Not started
