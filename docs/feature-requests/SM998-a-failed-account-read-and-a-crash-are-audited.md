---
id: SM998
title: "SM998: a failed account read and a crashed handler are audited"
subtitle: "SM943 ruled that refusals and errors are audited. The control API's users read sub-actions wrote nothing when they failed, and a handler that died wrote nothing on any surface."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: WORK-PLAN-0153 follow-up, listed as WORK-PLAN-0154 P24; ruling of 2026-10-12
area: audit
status-note: "SHIPPED (0.15.5): a failed users read sub-action writes a user-<sub> fail row with its class only; a crashed control API handler (END guard) and a crashed MCP tool each write one fail row naming the action, never the error (t/integration/133)."
---

# The ruling

Under SM943's audit rule (refusals and errors are audited): the control API's
`users` read sub-actions (incl. verify-credential) write an audit row when they
fail; a handler that crashes writes one failure row on every surface (API, MCP)
naming the action, never the error's secret content.

# What changed

**A failed account read.** `%uskip` in lazysite-manager-api.pl names the
`users` sub-actions that only read (list, users-detail, verify-credential,
credential-status, totp-code and the rest). They were skipped whatever the
outcome. Now they are skipped when they succeed and recorded when they fail,
as `user-<sub>` against the account named, status `fail` - as a top-level read
is since SM943. A GET carries its sub-action in `sub=`, which is read for the
row. The detail is the refusal's `audit_detail` or `kind`, else `failed`; never
its `error` text, because the users tool turns a die inside a read into
`{ ok: 0, error: <the die> }`, and a read's input can be a credential or a
TOTP secret.

**A crashed handler, control API.** A die in a dispatch branch left the process
before the audit block. A guard is armed above the dispatch chain and disarmed
after it; an END block writes one row when the chain did not finish and the
process is exiting on a failure: the action (`user-<sub>` for action=users),
the caller, `fail`, the origin, and the detail "crashed: the handler failed -
the error is in the error log". The exit status is kept. A branch that exits 0
itself (a streamed response) writes nothing here.

**A crashed tool, MCP.** The tool's die was already caught and logged at ERROR
with the error; it now also writes one `fail` row naming the tool, with the same
detail, before answering "Tool error".

The HTTP answer to a crashed control API request is unchanged (the process
still dies; the web server answers 500).

# Tests

t/integration/133: a successful users-detail writes no row; a failed
verify-credential writes one `user-verify-credential` row naming the account,
without the secret; verify-credential made to die holding the secret (a test
hook, t/lib/CrashHook.pm, loaded with PERL5OPT) records `failed` and not the
secret; nav-read made to die writes one `nav-read` fail row saying it crashed,
without the error; MCP read_nav made to die writes one `read_nav` fail row,
without the error.
