---
id: SM818
title: "SM818: disabled must mean the work stops, not that the surface refuses"
subtitle: "The release manager wants the embedded engine switches to be truly off when disabled. Today they are not, and it is not uniform: `plugin_enabled` is consulted at fourteen call sites across nine files, so `data`, `briefs` and the daemon do stop, while `audit_log` and content-history never ask, and the first-party access log has no switch at all because the core renderer writes it. So `enabled: false` is a declaration that parts of the engine ignore. One member of the set - the audit trail - is a case where truly-off is the WRONG requirement, and that needs deciding rather than building."
brand: plain
standard-margins: true
status: superseded
raised: 2026-09-10
raised-by: release manager
area: architecture
status-note: "SUPERSEDED 2026-09-10 by SM222, which is the mini-init filing and already carries the truly-off design as L1/L2/L3 plus a built Lazysite::Lifecycle contract. This was filed without checking for that prior art - the release manager pointed at it. The evidence here is not lost: it is folded into SM222 as L0, the work itself, which the three endpoint layers do not cover, and the audit ruling of 2026-09-10 is recorded there."
---

# What was asked

> I want the current embedded engine switches to be made more independent so
> they are truly off when disabled.

With the reason given alongside it: the visitor log creates data, and somebody
running locally may not want it created at all. Not "not shown" - not created.

# What is true today

[[SM469]] established that *off means off for plugin actions*, and it holds: the
action surface refuses. **But refusing the action is not the same as not doing
the work**, and the engine does not currently draw that line consistently.

`plugin_enabled` is consulted at fourteen call sites in nine files:

| Consults it | Does not |
| --- | --- |
| `lazysite-data.pl`, `Manager/Data.pm`, `plugins/form-handler.pl` (for data) | `Lazysite::Audit::audit_log` - returns early only when `$LAZYSITE_DIR` is undefined |
| `Manager/Briefs.pm` | content history - no check anywhere in the write path |
| `Daemon/Supervisor.pm` | `lazysite-mcp.pl::_stats_export` - finds `plugins/stats.pl` and runs it, erroring only if the file is absent |
| `Lazysite::Notify` (2) | the first-party access log - **no switch exists** |
| `Manager/StartPage.pm` (3), `Manager/Common.pm`, `Manager/Plugins.pm` (3) - surface and listing | |

**The access log is the clearest case and the one the release manager named.**
It is core: `lazysite-processor.pl` carries "SM140: first-party access log" and
builds `%ACCESS_REC` per request. There is no configuration key and no guard - no
`access_log:` in any conf, no `if enabled` in the write path. So disabling the
`log` or `stats` extension changes what can be *read*, and the engine goes on
recording every visit. For the operator who asked, that is the opposite of the
switch they thought they were throwing.

**This is a declaration the code ignores**, in the house's own phrase: the
manager offers `enabled: false`, and several parts of the engine never ask.

# Why it is uneven, and the shape of the fix

The current mechanism asks **every call site to remember**. That is the pattern
this codebase files against repeatedly - [[SM666]] is a capability that reached
one resolver and not another, and SEC-2026-07 (F3) is the same failure - and it
fails the same way here: fourteen sites remembered, several did not, and nothing
can tell you which.

So the fix is not "add nine more checks". It is structural:

1. **Core calls through a registry, and a disabled extension is not in it.**
   Where the renderer wants a visit recorded, it calls a recorder that the `log`
   extension registers; with the extension off there is no recorder and no call.
   Truly-off then holds **by construction** rather than by fourteen people
   remembering, and a tenth call site added next year inherits it.
2. **Move the access-log WRITE out of the core renderer.** Under the release
   manager's own principle - the core renders, standalone and simply - recording
   who visited is an extension's job and is currently core's. This is the same
   argument [[SM817]] makes for the vocabulary, arriving at a concrete file.
3. **A lint that the registry is the only route.** A direct call from core to an
   extension's file - the `_stats_export` shape - should fail, because it is
   exactly how truly-off gets quietly lost again.

# The member where truly-off is the WRONG requirement

**The audit trail.** `audit_log` does not check whether the audit extension is
enabled, and that is arguably correct: an audit trail an operator can switch off
is not an audit trail. Making it honour the switch would mean a site could
silence its own security record, and a switch that silences the record of its own
use cannot be audited by definition.

Three ways out, and this is a decision rather than an implementation:

- **The audit trail is not switchable at all** - it leaves the extensions list
  and becomes core, which is honest and costs the operator a control they should
  probably never have had.
- **It stays switchable and the switch is loud** - refused without a sysop, and
  the disabling itself written to the trail before it stops. Still a record with
  a hole in it, but a hole with a name on it.
- **It stays as it is** - listed as switchable, quietly ignoring the switch,
  which is the current state and is the worst of the three because the operator
  believes something untrue.

The same question, less sharply, applies to content history: a site that turns
off history and then finds a page's past is gone has lost something a switch
implied it was merely hiding.

# Two classes, which the release manager has confirmed

From [[SM817]]:

- **Reach outside the box**: `pandoc`, `notify-xmpp`, `git-sync`, `form-smtp`,
  `payment-demo`. These are already largely honest - they act when invoked, and
  `Notify` checks. Truly-off is nearly free here.
- **Embedded engine machinery**: `audit`, `log`, `content-history`, `stats`,
  `data`, `briefs`, `daemon`, `bad-url-blocker`, `form-handler`. This is the set
  the request is about, and the set where the work happens whether or not the
  surface is open.

# What is asked

1. Decide the audit question above before anything is built, because it changes
   whether the set is nine or eight.
2. Build the registry, and move the access-log write behind it.
3. Lint that core does not reach into an extension's file directly.
4. Then audit the remaining members one at a time, with a test each that asserts
   **no output** when disabled - not "the action refuses", which is already true
   and is what made this invisible.

Not started. It wants scheduling with [[SM817]], since both follow from the same
principle and touch the same files.

# Provenance

Asked by the release manager on 2026-09-10. The fourteen call sites, the absent
access-log switch, `audit_log`'s early return and `_stats_export`'s ungated run
were all read from this tree.
