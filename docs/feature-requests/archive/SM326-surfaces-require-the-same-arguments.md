---
title: "SM326 - an argument required on one surface must be required on the other"
subtitle: "MCP declared path required; the control API supplied it from a shared dispatcher default. Both surfaces looked correct to every check in the repository."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11 as t/lint/52, the follow-up SM306 filed. It pairs MCP's required-argument lists against the control API's dispatcher defaults, both DERIVED from source so a second default added later forces every pairing to be reconsidered rather than silently inheriting an exemption. Shown to fail by reverting acl-set's guard. FILED 2026-08-16."
---

# The gap

`set_permissions` declares `required => ['path']`, so MCP has always refused a
call with no target. The control API derived its target from a shared dispatcher
default:

```perl
my $path = $params{path} // '/';
```

so the same operation with no path applied a **site-wide read restriction** and
returned `ok:1`. A partner agent took a live site off the air that way (SM306).

**Nothing could have caught it.** SM239 pins that both surfaces expose the same
*actions*, and `t/lint/23` records which are deliberately one-sided. Neither
compares what the two surfaces *require*, so one channel could demand an argument
while the other invented a dangerous default for it, and both looked correct.

# What it converts

Three actions move from safe-by-accident to safe-on-the-record. `git-history`,
`git-show` and `git-restore` all inherit the `/` default and are harmless only
because `validate_path` and `is_editable_text` reject a directory **downstream**.

That is precisely the state `acl-set` was in before SM287 made a root ACL take
effect: a change somewhere else turned a harmless default into a destructive one,
and nothing was watching the seam. Those three are now recorded with the reason
they are safe, and a stale exemption is itself checked.

# Why it is narrower than its title

The hazard is specific: an argument one surface **requires** and the other
**silently supplies**. The control API has exactly one dispatcher-level default -
`path` - so that is the pairing to check. Both sides are derived from source
rather than listed, so adding a second default cannot quietly widen the
exemption.

# Related

SM306 (the defect that filed this), SM239 and `t/lint/23` (action parity, which
this complements), SM287 (the change that made the default destructive), SM278
(unknown arguments refused on the MCP surface).
