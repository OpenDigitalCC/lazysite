---
title: "SM840: 'plugin' survives in three extensions' own descriptions and in the control API's errors"
subtitle: "Sites agent, 1312E-03, 2026-09-11: nav, titles, Groups, Users and Visitor Stats are clean; what remains is inside description prose and error text - which reaches an operator through any tooling"
brand: plain
standard-margins: true
status: candidate
---

# What remains

Inside extension descriptions, shown on both extension pages:

- `plugins/briefs.pl` - *"...WRITING one needs manage_briefs, which this plugin declares..."*
- `plugins/content-history.pl` - *"...(the Remote sync plugin)."*
- `plugins/git-sync.pl` - *"...needs the Content history plugin to be enabled"*,
  and its refusal *"Enable it with the Content history plugin first."*

And the control API's own error text, `Manager/Plugins.pm`: *"a plugin is required
..."* and *"no plugin 'x' is installed - call plugin-list..."*.

All confirmed by grep. The action names in the error text (`plugin-list`) are the
wire's deprecated spelling and should name `extension-list`; the word *plugin* in
the prose should read *extension*, as SM817's surface pass did everywhere else.

# Why it was missed

SM817 step 3 swept the manager pages, the nav and the shipped docs. Extension
descriptions are prose that each extension publishes about itself through
`--describe`, and error text lives in the module - neither is a page, so a sweep
of pages could not reach them.

# Related

[[SM817]].
