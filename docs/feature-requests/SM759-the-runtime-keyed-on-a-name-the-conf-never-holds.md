---
id: SM759
title: "SM759: the runtime keyed on a name the conf never holds, so Enable never enabled it"
subtitle: "The 0.13.2 field pass, 2026-09-06: the plugin listed as enabled and Status said disabled, five minutes after the switch - because the supervisor looked up daemon.pl and the Plugin Manager writes plugins/daemon.pl. The start-page gate had the same bug."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-06 on claude/sm759-the-runtime-keyed-on-a-name-the-conf-never-holds for 0.13.3. Also from the field filing on the status line: the disabled line names its next step, the runtime check carries the host remedy, and Status carries the run record (runs) since no remote grant can read lazysite/daemon/. Supervisor $PLUGIN and StartPage plugin => are registry keys; t/unit/daemon/09 enables through the real writer and asks both readers (fails on the old code, 10 ways); t/lint/119 refuses a bare name in any enabled-check or fixture; the six fixtures that wrote '- daemon.pl' / '- stats.pl' / '- notify-xmpp.pl' by hand now write the key. Needs a cut and a deploy before 132E-01 can run."
---

# The report

From the sites agent, relayed 2026-09-06 during the 0.13.2 pass:

> Confirmed: daemon _enabled=True (token channel) yet Status still reports
> "disabled"/desired:off/service:inactive 5+ minutes after enable - the
> service never started - does it require me to start it?

# What was true

The Plugin Manager writes a plugin's **registry key** into the conf's
`plugins:` list - `plugins/daemon.pl` - and `_enabled_map()` reads it back
under that key. Every enabled-check in the engine asks for that key
(`plugins/data.pl`, `plugins/briefs.pl`) except two:

- `Lazysite::Daemon::Supervisor::$PLUGIN` was `'daemon.pl'`. `should_run()`
  therefore returned 0 on every site where the plugin had been enabled the
  only way a sysop can enable it. Status said "the daemon plugin is disabled,
  so no process is started"; the timer-started service read the same and
  exited 0 with "not starting: the daemon plugin is disabled"; `is-active`
  was inactive; the sysop had switched it on five minutes earlier.
- `Lazysite::Manager::StartPage` named `plugin => 'data.pl'` and
  `'stats.pl'`, so a start page on either was unreachable whenever the plugin
  was on.

The runtime shipped this way in 0.13.0, 0.13.1 and 0.13.2. Nothing caught it
because **every fixture wrote the conf by hand** - `plugins:\n  - daemon.pl` -
in the shape the reader expected. The fixture agreed with the reader; the
writer was never in the room. The daemon's eight-dimension review, the field
pass on 0.13.1 (which could not provision) and 12,582 tests all passed over a
gate that could never open.

# What is built

- Both readers name the registry key.
- `t/unit/daemon/09` sits a site one level below a directory carrying the
  engine's real `plugins/`, enables through `action_plugin_enable`, and asks
  `should_run`, `status()`, the on_enable hook's answer, and
  `StartPage::_page_reachable`. Against the old readers it fails ten ways.
- `t/lint/119`: every literal handed to `plugin_enabled()`, `$PLUGIN`, and a
  `plugin =>` naming a shipped script must start with `plugins/`; no test
  writes a bare plugin name where a conf entry goes (a line that means to,
  says `bare-name-on-purpose`).
- The fixtures in daemon 01/04/06/07/08, manager 157 and the two notify tests
  write the key. `Notify.pm` strips the directory before comparing, so it was
  right either way; its fixtures now match the writer too.

# The answer to the agent's question

No - the manager cannot start the service and the sysop is not asked to. The
timer starts it within five minutes of Enable; it did, and the runtime read
the conf, looked for a different word, and left. Nothing on the host was
wrong. 132E-01 runs again from step 1 once 0.13.3 is deployed.

# Why this is a lint and a join test, not just a fix

The fix is one string. The defect class is "reader and fixture agree, writer
absent", which is the shape memory records as *fixtures agree with readers*
and *the fixture writes both sides*. A join through the real writer is the
only test that proves the key; a lint is what stops the next reader being
written against a fixture's belief.

# The status-line filing, answered in the same branch

The agent's second filing (`the daemon status line fails the test 132E-01
sets for it`) lists three defects. One and two are this bug: the falsehood is
`should_run` reading the wrong key, and the job account was invisible because
`job_account_checks` runs only when the plugin reads as enabled - with the key
right, `job_account` and `job:<name>` checks appear beside the host checks,
with the account name and the missing capability (`t/unit/daemon/08`, which
already proved that against a fixture that agreed with the reader). The
third - no next step - was real on its own for the disabled state, which is
a healthy verdict by the lifecycle contract and so carried no remedy field:
the one-line summary now ends `- enable it on the Plugin Manager to start
the runtime`, and the `runtime` check carries the host remedy when the
plugin is enabled and nothing is running. `t/unit/daemon/08` walks the
field's state list and holds that every state short of running names a next
step.

Their structural check - "no status string may assert a plugin's enabled
state from a source other than the one the Plugin Manager reads" - is
`t/lint/119` and `t/unit/daemon/09`.

And the run record: no remote grant reaches `lazysite/daemon/`, by design,
so the record the plan's step 5 asks for could only be read by someone with
the filesystem. Status now carries it as `runs` - per job, the outcome, when,
as whom, and the refusal reason - so the Status button is where a sysop or a
partner reads what the jobs did.
