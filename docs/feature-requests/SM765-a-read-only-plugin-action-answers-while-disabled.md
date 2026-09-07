---
id: SM765
title: "SM765: a read-only plugin action answers while the plugin is disabled"
subtitle: "The 0.13.4 field pass, 2026-09-07: Disable said the runtime stopped; pressing Status a minute later said only that the plugin is disabled. The question is asked afterwards, not during, and a read does not execute anything."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-07 on claude/sm765-a-read-only-plugin-action-answers-while-disabled for 0.13.5. Descriptor actions may declare read: 1; _gate_execution lets a declared read run on a disabled contract plugin; daemon's status is one; ADR 0009 amended; t/unit/manager/62 holds that a read leaves no witness; t/unit/daemon/09 asserts the standalone Status path while disabled."
---

# The filing

`2026-09-07-status-while-disabled-still-hides-the-runtime.md`: the disable
response (SM760's on_disable hook) carried the whole state - "the runtime is
stopped", `host.service`, `runtime_user`, `runs`, `healthy: 1` - and a
standalone Status press seven minutes later, plugin still disabled, returned
only `This plugin is disabled. A sysop can enable it on the Plugin Manager
page.` The agent's point, accepted whole: "did it actually stop?" is asked
when the operator comes back, and every later route goes through Status.

# What was true

ADR 0009: a disabled contract plugin executes nothing. `_gate_execution`
refused every action on a disabled plugin, and `status` is an action. The
hook path bypasses the gate by design (hooks are the toggle's own run), which
is why the disable response could answer and the button could not - two
paths, one question, one refusal.

# What is built

- A descriptor action may declare `read: 1`. `_gate_execution` takes the
  action and lets a declared read run on a disabled contract plugin; the
  daemon's `status` declares it. Config read and save were already open
  while disabled (SM409) for the same reason - the gate stops a disabled
  plugin doing anything, and a read does not.
- ADR 0009 carries the exception, narrow and declared, with the rule that a
  read that changes anything is a defect.
- `t/unit/manager/62` (disabled means off) gains a `peek` read action on its
  fixture plugin: it answers while the plugin is off and leaves no witness
  file, while `touch` stays refused. `t/unit/daemon/09` presses Status
  through `action_plugin_action` after disabling and asserts `desired: off`,
  "the runtime is stopped", and `host`/`checks`/`runs` present - the
  standalone path, which is the whole finding.

# The agent's structural rule

"A read-only plugin action must not be refused solely because its plugin is
disabled" - that is now the code, keyed on the declaration. Lint 76 (the
descriptor reader) sees `read` as an ordinary key.
