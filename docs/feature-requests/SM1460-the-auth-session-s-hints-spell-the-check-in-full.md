---
id: SM1460
title: "SM1460: the auth session's hints spell the check in full"
subtitle: "Four hints in the session code, and a dozen more across the engine, name a bare `lazysite check` or a <docroot> placeholder where every other advice line spells the command as this host runs it, with the real docroot."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the SM1459 review"
area: check
status-note: "OPEN. Target 0.17.2. Advice text only. Follows SM1458, which fixed the check's own advice, and SM1459, which spelled the new provider hints."
---

# What was found

The session code's older hints read "(lazysite check --docroot names it)" or "lazysite check
--docroot <docroot> names it": a bare `lazysite`, which a tarball host does not have on its path,
and either a missing or a placeholder docroot. SM1458 fixed this in the check's own advice and
SM1459 spelled the hints it added; the older ones in the same file were not touched. The same two
faults stand in log lines and command-line refusals of other modules.

# Why

A hint is the one thing an operator reads next, and it is copied and run. A placeholder has to be
edited first; a bare `lazysite` fails on a host that has none on its path.

# The request

R1
: Every hint in `Lazysite::Auth::Session` that names the check spells it with `cli_spelling` and the
  site's real docroot, through one helper, `Lazysite::Util::check_command`, which the file's own
  `_check_names_fix` (SM1459) also uses.

R2
: The same for every other log line and command-line refusal in the engine that names the check or
  another command with a bare `lazysite` or a `<docroot>` placeholder meant for an operator.

R3
: Text a web door shows to a visitor or a manager keeps its placeholder: a page carries no host
  path (SM494, ruling 243), and the processor's render path loads no Lazysite module (ADR 0001).
  Those are listed in the changelog note, not changed.
