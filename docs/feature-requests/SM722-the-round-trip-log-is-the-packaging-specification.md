---
id: SM722
title: "SM722: the round-trip log is the packaging specification"
subtitle: "Phase 8 of the apps portability plan, and the gate for calling the feature done. A real app is carried to a fresh instance by hand, every hand-fix is logged, and the packaging functions are built to eliminate that log item by item - not designed in advance."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 8 of 8, and the definition of done.** Depends on SM715 through SM719,
and on the uninstall/reinstall half of SM721. Does **not** depend on SM720
(declarative migrations) or on fork migration.

**This is the critical-mass point.** Before it, the plan is machinery nobody
outside the team can use. After it, apps are portable and the marketplace
(SM723) becomes buildable.

# The method, and why it is this way round

The packaging functions are built **from the log of a manual round trip, not
before it**. This is the phase's whole discipline and the thing most likely to
be skipped under schedule pressure, because writing the functions first feels
faster and produces something demonstrable sooner.

It produces the wrong functions. What a packaging system must automate is
whatever a real app actually needed done by hand - which nobody knows until
somebody does it by hand and writes down what they did.

# The procedure

1. **Refactor the messiest bespoke app to the spec.** Per ADR 0009's
   exemplar-first reasoning: a spec that survives the worst case absorbs the
   tidy ones. The tidiest app would prove almost nothing.
2. **Commit it to the repo by hand.** The marketplace at this stage is a plain
   git repo, nothing more.
3. **Install it onto a fresh instance** - different domain and site name, no
   pre-existing groups, default plugin state - **as a realistic account holding
   install and `manage_users`, not as sysop.** A round trip proved as sysop
   proves nothing about the grants a real installer holds.
4. **Log every hand-fix required.** That log is the packaging specification.
5. **Uninstall**, verify retained tables and tombstone; **reinstall**, verify
   reattachment.
6. **Then build the packaging functions**, to eliminate the log item by item.

# Expected failure classes

Written down so they are checked off rather than rediscovered:

- hardcoded self-reference in links, JavaScript and descriptors
- registrations and entries outside the app's folder
- group-name assumptions
- the app's fixtures tangled with live rows

An unexpected failure class is the most valuable output of this phase. It
should be filed, not just fixed.

# Outcome test

- The exemplar app installs onto a fresh instance with **zero** hand-fixes, by
  an account holding install and `manage_users` only.
- Uninstall retains the tables and leaves a tombstone naming them.
- Reinstall reattaches; the app's data is as it was.
- Journey-tier coverage exists for install, update-refusal, uninstall and
  reinstall-reattach.
- The round-trip log is closed: every item either eliminated by a packaging
  function or recorded as a deliberate manual step with its reason.
