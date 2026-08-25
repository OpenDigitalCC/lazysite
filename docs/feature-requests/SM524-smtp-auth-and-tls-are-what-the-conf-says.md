---
title: "SM524: SMTP auth and TLS are what the conf says"
subtitle: "auth: 1 and auth: yes silently skip SMTP authentication, and a run with tls: false still reports tls as checked."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-forms-smtp-auth-spelling.pl; class: security-integrity; recommended timing: BEFORE-BETA-PUBLISH. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. form-smtp.pl tests the auth key with /^true$/i at 320 (send_via_smtp) and 462 (validate_smtp), so the spellings 1, yes and on that its own _truthy accepts for attach_files skip authentication entirely; and 511 compares the tls string so tls: false is still listed under checked. Against a mock server that 535s AUTH, auth: true reaches stage auth while auth: 1 returns ok:1 checked=[host,port,connect,tls]. The fix routes both reads through _truthy."
---

# The finding

`auth: 1` and `auth: yes` silently skip SMTP authentication in both
`validate_smtp` (`plugins/form-smtp.pl 462`) and `send_via_smtp`
(`plugins/form-smtp.pl 320`), which test `/^true$/i`, while `_truthy` in
the same file (200) accepts 1/yes/on for `attach_files`. The same run
lists `tls` as checked when `tls: false`, because `plugins/form-smtp.pl
511` tests the string. Against a mock server that answers 535 to AUTH,
`auth: true` reaches stage `auth`; `auth: 1` returns `ok:1
checked=[host,port,connect,tls]`.

# Why it matters

Security-integrity: the operator believes authentication and TLS were
verified when neither was. The validation report is the evidence they
act on, and here it vouches for steps that never ran.

# The proving test

Extend the `t/unit/forms/05` mock-server block (85-103): `is($r->{stage},
'auth')` for `auth: 1`; `ok(!grep { $_ eq 'tls' } @{$r->{checked}})`
when tls is false.

# Fix shape

Read `auth` and `tls` through the file's existing `_truthy` predicate at
320, 462 and 511, so every accepted spelling drives the same behaviour
and the `checked` list reflects what actually ran.
