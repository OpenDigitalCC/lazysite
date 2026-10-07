---
id: SM959
title: "SM959: A child process that exits before reading kills the process writing to it"
subtitle: "Eleven places in the shipped code wrote to a child's stdin with SIGPIPE at its default; a mail helper that failed to start took the form handler or the manager API down with no message."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, from a flaky test (t/unit/forms/24) during the SM958 handoff
area: robustness
status-note: "SHIPPED (PENDING): every open2 / |- spawn in the shipped code (12 sites) runs with SIGPIPE ignored; lint 211 holds it; t/unit/lib/199 sends 300 KB to a child that exits at once and asserts the caller is not killed (signal 13 without the guard). t/unit/forms/24 went from 4 failures in 8 parallel runs to 0 in 8."
---

# Measured

`t/unit/forms/24` failed with `Wstat: 13 (Signal: PIPE)` in 4 of 8 runs of
`prove -j8 t/unit/forms/` on main. Its second call hands
`Handlers::_acknowledge_submitter` a mail script that does not exist; the child
exits at once, and `_run_smtp_script`'s `print {$in}` met a closed pipe. With
SIGPIPE at its default action that kills the caller - whether it does depends on
whether the write lands before the child has gone, which is why it flaked.

The same shape is in production: if `plugins/form-smtp.pl` (or any helper the
CGIs spawn) dies before reading - a missing module, a compile error - the form
handler, the manager API or the auth CGI is killed mid-request, and the visitor
or operator gets a dead connection with nothing logged.

Only `lazysite-processor.pl` (and the dev server) guarded against it. The other
sites, all `open2` or `'|-'`: install.pl (tar), lazysite-auth.pl (users tool,
SMTP), lazysite-manager-api.pl (plugin action, stats export, users tool),
lazysite-mcp.pl, lazysite-oauth.pl, Handlers.pm (form SMTP), Notify.pm (mail),
plugins/form-smtp.pl (sendmail), tools/bench.pl.

# The fix

`local $SIG{PIPE} = 'IGNORE'` before each spawn, in the block that writes to it.
A write to a child that has gone now fails as a write; each caller already turns
an empty answer into its own error (`no answer`, `Cannot run ...`).

# Evidence

- t/lint/211: every `open2` / `'|-'` in the shipped code has the guard within the
  lines before it. Removing one names the file and line.
- t/unit/lib/199: the real `_run_smtp_script`, 300 KB to a child that exits at
  once, in a subprocess read through a list-form pipe (through `/bin/sh` a signal
  death reads as exit 141 and would hide). With the guard: not killed, returns a
  failure. Without: signal 13.
- t/unit/forms/24: 8 of 8 parallel runs pass.

# Related

[[SM958]] (whose handoff surfaced it).
