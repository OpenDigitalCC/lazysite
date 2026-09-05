---
id: SM749
title: "SM749: the active theme is read-only on one surface out of three, and the refusal does not say what to do instead"
subtitle: "WebDAV refuses a write to the theme being served. The control API and MCP write it without comment, through a choke point that has never heard of it. Copy, edit, activate is the only correct way to change a live theme - so the rule is right and it is in one caller instead of where all three meet."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-05 on claude/sm749-active-theme-everywhere for 0.13.1. The rule is Manager::Common::active_artifact_refusal - pure, taking the active pointers - and is asked by the choke point on EVERY write verb (save, binary save, delete, mkdir, move either end, copy destination) and by the DAV stack, whose three private copies of the text are gone. The refusal names copy, edit, activate with the verb on each surface and offers no way round within one. The workflow's first step now exists as one verb: action_theme_copy, reachable as copy_theme (MCP), theme-copy (control API, manage_themes, token-reachable) and Copy on the manager Themes page; the copy is named as its own theme, records the copier, carries the asset mirror, and changes nothing live. t/lint/114 generalises 141: every *_refusal rule in Common is called from both write stacks or is exempted with a reason. ONE ASYMMETRY REMAINS, FOR THE RELEASE MANAGER: theme-upload with update:true snapshots and then cp -r's over an existing theme, including the active one (the SM365 fix, so a layout release and its theme update together). That is a whole-artefact replace rather than a file write, but it is not atomic either; whether it should refuse the active theme, or apply via copy-and-repoint, is a decision this branch did not take. DECIDED 2026-09-05: nothing writes into an active artefact on any surface - an update installs beside and switches in - filed as SM756."
---

# What is true today

`lazysite-dav.pl` refuses a write to the active theme or the active layout:

> the active theme (studio) is read-only over WebDAV; switch the active theme
> first, or edit a non-active one

The rule is correct and the release manager has confirmed the intent:
**editing an inactive theme and then activating it is essential, and it is the
only way to change a live theme safely.** A theme apply is meant to be atomic;
a stream of individual file writes into the thing currently being rendered is
not.

**It exists in exactly one file.** `grep` for the rule across the tree returns
`lazysite-dav.pl` and nothing else. `active_theme` appears in `lazysite-mcp.pl`
once, reporting it. `lazysite-manager-api.pl` has no equivalent refusal at all.
`Lazysite::Manager::Files::action_save` - the choke point the manager, the
control API and MCP all write through - has never heard of it.

So the same write is refused over WebDAV and accepted over the other two, and
the theme being served changes under visitors either way.

# This is SM748 again

SM748 was the parse guard living in one CALLER of a shared function while the
primary editing path went unguarded for four releases. The lesson it produced
was written down:

> A rule enforced in a CALLER protects that caller. A rule at the choke point
> protects whoever is added next.

This is the same shape with the surfaces reversed - the rule is on the
re-implemented stack and absent from the shared one, which is the harder
direction to notice, because the surface that HAS the rule is the one people
expect to be the odd one out.

# What is asked for

**The rule moves to the choke point**, so all three surfaces refuse a write to
the active theme or active layout, and WebDAV keeps its own copy the way SM189
and SM748 do - two write stacks, not four.

**The refusal signposts the workflow rather than the workaround.** The current
message offers two escapes *within WebDAV* ("switch the active theme first, or
edit a non-active one") and says nothing about what a caller should actually
do. Once every surface refuses, there is one right answer and the message
should be it: **copy the theme, edit the copy, activate it.**

That matters more than it sounds. A partner agent holding `manage_themes` met
this refusal, read the two escapes, and concluded that editing a theme needed
the manager UI or an MCP connector - reasoning correctly from what the message
said, to a list that was wrong in both directions. It named surfaces that have
no such restriction and omitted the control API entirely. **The message
described what was refused without saying what to do**, which is the third time
this class has been filed: SM712 for capabilities, SM730 for uploads, this now.

# Could a lint have caught it

Yes, and it is the check SM748 already built, pointed at a second rule.

`t/unit/manager/141` walks the tree and asserts the parse guard's call sites are
exactly the choke point and the DAV stack. The same shape applies here: the
active-theme rule should have call sites in `Files.pm` and `lazysite-dav.pl`,
and nowhere else. A rule that exists in one file and is enforced on one surface
would fail that assertion the day it was written.

Worth generalising rather than copying: **a content-write rule is enforced at
the choke point plus the DAV stack, or it is not enforced.** That is one lint
covering every such rule, and it is the third time it would have paid.

# Provenance

Raised 2026-09-04 from a partner agent's field report, which was accurate about
WebDAV and wrong about the alternatives. The intent - copy, edit, activate,
atomically, on every surface - is the release manager's, confirmed the same
day. Nothing is built.
