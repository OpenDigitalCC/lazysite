---
id: SM908
title: "SM908: a suite failure that cannot be diagnosed costs the gate twice"
subtitle: "One test in 14,833 failed on a gate run and reported nothing about why: `apache would not start with its guard block: ` and an empty string after the colon. It passed alone and passed on the re-run, so the twelve-minute gate was paid twice and the cause went with the overwritten log. Two hypotheses for it were measured and both are false. What IS demonstrated is the silence: t/integration/96 ran apache through a bare system() and reported the ErrorLog, and apache refusing a configuration says so on STDERR and never opens that log."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-27 for 0.15.0, as the diagnostic rather than a fix for a named cause, because the cause is not named and this filing says so. MEASURED AND DISPROVED, both hypotheses this agent offered the release manager: (1) the port helper's TOCTOU window - free_port binds, closes and returns the number, so two parallel test processes could be handed the same port - measured over 40 rounds of 4 simultaneous askers with no collision; (2) the loop reusing ONE port across eight apache start/stop cycles, where the wait is for the pid file and not the socket - measured on an idle host, the port came back bindable within 0.1s four times out of four. BUILT: t/integration/96 takes a port per iteration (one fewer thing an iteration depends on, one syscall), and starts apache through a new shared ApacheHarness::start_apache_conf that CAPTURES what apache said. Proved by sabotage: a conf with a built-in module loaded reports `apache2: Syntax error on line 12 ... module unixd_module is built-in and can't be loaded` where it used to report an empty string, and confirms `(no error log written)` is what the file offers in that case."
raised: 2026-09-27
raised-by: engine agent (the SM907 AT2 gate run)
area: testing
---

# What happened

The gate for `claude/n167-at2-trail-state` failed on one test:

```
#   Failed test 'Apache'
t/integration/96-a-moved-engine-tree-keeps-the-acl-guard.t (Tests: 2 Failed: 1)
```

and, from the test's own failure message:

```
apache would not start with its guard block:
```

Nothing after the colon. The test passed when run alone, and passed on the
re-run, so the release paid for two full suite runs and learned nothing about the
first.

# The two hypotheses, and why neither stands

Recorded because each was offered to the release manager as the likely cause
before it was measured, and both are false.

**The port helper's window.** `NginxHarness::free_port` asks the kernel for an
ephemeral port, closes the socket, and returns the number; between the close and
the server's bind the port belongs to nobody. Twenty-five call sites share it. The
measure: four processes asking simultaneously, forty rounds.

```
0 of 40 rounds handed the same port to two processes (0 collisions)
```

The kernel rotates its ephemeral allocation, so near-simultaneous askers do not
alias. The window is real and this is not what it costs.

**One port, eight restarts.** The Apache subtest took a single port before its
loop and started and stopped apache on it eight times, waiting only for the PID
FILE to disappear - which says nothing about the listening socket. The measure:
start, stop the way the test does, and try to bind at the moment the next start
would begin.

```
round 1: pid file gone after 0.10s; port bindable now: yes
round 2: pid file gone after 0.10s; port bindable now: yes
round 3: pid file gone after 0.10s; port bindable now: yes
round 4: pid file gone after 0.10s; port bindable now: yes
```

On an idle host, four for four. Under a loaded parallel suite it may differ, and
that is a guess, not a measurement.

# What is demonstrated

The silence, which is the part that made the cost double rather than single.

`ApacheHarness` has a `start_apache` that captures output, but it builds its own
TLS and vhost configuration, which a test proving a rewrite guard cannot use. So
this test rolled its own `system(...)` with no capture and reported the ErrorLog
on failure. Apache refusing a configuration writes to STDERR and never opens the
ErrorLog, so the report was an empty string.

Measured while building the fix, by getting a configuration deliberately wrong:

```
apache said: apache2: Syntax error on line 12 of .../httpd.conf:
             module unixd_module is built-in and can't be loaded
error log: (no error log written)
```

# What shipped

| Ref | Cx | What |
|-----|----|------|
| PR1 | S | `ApacheHarness::start_apache_conf` / `stop_apache_conf`: start apache from a conf the caller wrote and hand back what it said. The capture the existing helper has, available to a test that needs its own configuration. |
| PR2 | XS | t/integration/96 uses it, and prints apache's own words and the ErrorLog on a failure to start, as two separate diagnostics. |
| PR3 | XS | A port per iteration rather than one for eight restarts. Not a fix for a proven cause, and the comment says so. |

# What is NOT done, and why

The port helper still hands back a number after closing the socket. Closing that
window properly means holding the reservation until the server binds, which every
one of the twenty-five call sites would have to take part in, and the measurement
above says the window is not currently costing anything. Left open deliberately
rather than half-closed: if the next failure names a port clash, this filing has
the measurement that says where to start.
