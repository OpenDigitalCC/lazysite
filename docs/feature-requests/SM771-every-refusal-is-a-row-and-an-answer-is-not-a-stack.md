---
id: SM771
title: "SM771: every refusal is a row, and an answer that never came is not a stack"
subtitle: "0.13.6 on edge (136E-02, 136E-06): authorisation and payload refusals reached the audit trail but not the connector's own record, so a connector's log could not show that an account outside its callers had tried it; and an unanswered call's answer carried LWP's transport error with '/usr/share/perl5/LWP/Protocol/http.pm line 50' appended - one template away from a public page."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm768-an-unopenable-connector-store-is-not-an-empty-one (same store, same file, beside SM768). One _refused helper: every refusal - mode, callers, payload shape, rate cap, unreadable store - is recorded with why and actor and logged; refusals do not count against the rate cap. _answer_of keeps the first line of an LWP internal response without its ' at <path> line N.'. t/unit/manager/159 asserts both and fails on the old file."
---

# What the field saw

**136E-02.** The rate refusal appeared in `connector-calls` with
`why: "rate cap"`; the caller-group and payload refusals appeared only in
the audit trail. The field's reading: "an operator reviewing a connector's
own log will not see that an unauthorised account tried to use it, which
is arguably the row they most want."

**136E-06.** A connector pointed at a non-routable address with a 2-second
timeout came back `unanswered` in 2178 ms - correct - with `answer`:

```
Can't connect to 192.0.2.1:443 (Connection timed out)
Connection timed out at /usr/share/perl5/LWP/Protocol/http.pm line 50.
```

An answer can be kept in a table and rendered on a page.

# What is built

- One `_refused` helper for every refusal in `call`: a row in the record
  (`state: refused`, `why`, `actor`, `mode`, `trigger`) and a WARN, in the
  same shape the rate cap already had. Refused rows are skipped by the
  rate counter, so a refusal never consumes the cap it was refused under.
- `_answer_of` recognises LWP's internal response (`Client-Warning:
  Internal response`) and keeps its first line without the ` at <path>
  line N.` suffix: "Can't connect to 192.0.2.1:443 (Connection timed out)".
- `/docs/connectors` says both.
- `t/unit/manager/159`: five refusals on the record beside three answers
  under a cap of three, the outside account there by name with the reason;
  the unanswered answer names the transport reason and no path or line.
