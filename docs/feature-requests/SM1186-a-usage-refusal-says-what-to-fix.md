---
id: SM1186
title: "SM1186: a usage refusal says what to fix"
subtitle: "A read or write the operation refuses as bad input answers 400 with the operation's own message and fix line, cleaned and capped, so a page can tell the person what to change."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: OOM Lab, inbox 2026-10-19-odoo-extension-findings-from-the-hr-apps.md row L-18
area: odoo
status-note: "SHIPPED on n673: lib/Lazysite/Odoo.pm fault() and _usage_text; t/unit/odoo/75."
---

# What happened

The HR apps' findings, row L-18 (Timesheet week with `?date=`):

> A read whose operation throws a usage error answers 400 "the operation refused
> what it was given - see the event log". The operation's own message, for
> example a bad date, is not passed on, so a page cannot tell the person what to
> fix.

`fault()` mapped every OOM error kind it had no row for to `invalid` and the one
generic sentence, so a mistyped date and a bug in the page were told alike.

# What shipped

`fault()` passes the operation's own message, and its `fix` line when OOM gives
one, for errors of kind `usage` and for no other kind. The answer is still
`ok: 0, kind: invalid`, status 400 (a call in a batch carries it in its own
result; a confirm answers through the same function). The new field is `fix`;
`error` is the message. The event log line is unchanged and carries the whole
text.

Every other kind keeps today's sentence and its text stays in the log:
Odoo faults, transport, refused, config, and a die that is not OOM's.

## What was checked

OOM's usage messages are written for the caller, but not all are safe to hand a
browser. Read in `t/vendor/oom`: `Odoo::Error`, `Ops::Operation` (`check_params`,
`_typed`, `check_rows`), `Ops::File->check`, `Ops::Rows`, `Ops::Source`,
`Ops::Runs`, `Ops::Plan`, `Ops::Service`, `Transport::*`, `Model`/`Record`.
Most name a parameter, a type, a limit or an id. Some carry:

- a host path: `cannot read $path: $!`, `cannot open $dir`, `cannot load mapping
  $path: $@` (with perl's `at FILE line N`), `no run '$id' in $dir` (the runs
  directory);
- another database's column names (`dbi reader: key column ... (columns: ...)`);
- a caller-supplied value echoed back, which can be a key or a token.

So the text is not passed whole as it stands. `_usage_text` turns control
characters into spaces and collapses runs of space, then WITHHOLDS the message
(the generic sentence, and no `fix`) when it holds an absolute or `~` path, a
`dir/file.ext` path, a Windows path, perl's `at X line N`, a token of 25 or
more key-like characters (a key, a session id, a hash), or the words traceback,
api key, password, secret, token, session id, cookie, authorization or bearer.
Withheld, not redacted: a redacted path still says a file exists. Whatever is
left is cut at 300 characters (`$Lazysite::Odoo::USAGE_TEXT_MAX`). The `fix`
line goes through the same rule on its own, so a fix that names a path is
dropped while the message is kept.

A message that echoes the caller's own input (a bad date) reaches the page in a
JSON string, as every error does. A page puts it in text, never in markup.

Test: `t/unit/odoo/75-a-usage-refusal-says-what-to-fix.t`, on the fake Odoo and
a test operation `shop.week` (`t/lib/LazysiteTest/OdooOps/Week.pm`). It fails on
the unchanged code (read, cap and batch subtests) and passes after; with the
original `Odoo.pm` restored it fails again.

Not covered: no test makes a confirm's apply throw a usage error; the confirm
path ends in the same `_finish` and `fault()` as a read.
