---
id: SM752
title: "SM752: the daemon Status action could not load its own module, and the manager said 'Action produced no output'"
subtitle: "Found by the field in one click, in the state 0.13.0 was proudest of: plugin enabled, runtime not started, an operator asking why nothing is happening. The safety half held; the diagnostic half was absent exactly where it was designed to be present."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.13.1 (landed 2026-09-05, commit 08de995e, under the label SM752 - this document was written at the pre-cut pass). plugins/daemon.pl carries the @INC bootstrap; t/lint/59 covers plugins/ as well as tools/; t/unit/daemon/04 runs the action as the manager does, as a subprocess, and reads its JSON."
---

# What happened

`plugins/daemon.pl` shipped with `require Lazysite::Daemon::Supervisor` and no
`@INC` bootstrap. The manager runs a plugin action as a subprocess, so the
require died; a plugin action that dies prints nothing to stdout; the manager
reported "Action produced no output".

`t/unit/daemon/01` tested `Supervisor::status()` directly and passed
throughout, because an in-process call never exercises the subprocess load.
That is the gap: the function was tested and the button was shipped.

# What shipped

1. The bootstrap, copied from `tools/`: the plugin locates the module tree
   relative to itself and falls back to the system `@INC`.
2. `t/lint/59` (tools can find their modules) extended to `plugins/`: every
   plugin that loads a Lazysite module carries the bootstrap, and a plugin
   without it fails a lint the day it is written.
3. `t/unit/daemon/04` runs the Status action **as the manager does** - a
   subprocess with `PERL5LIB` cleared, so the test's own module path cannot
   rescue it - and asserts JSON the manager can render. SM222 later moved its
   vocabulary to the lifecycle contract (`desired: on`, `verdict: inconsistent`,
   a remedy naming the `systemctl` line).

# Related

SM666 (the runtime), SM222 (the vocabulary), SM366 (the same class in tools/).
