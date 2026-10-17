---
id: SM1156
title: "SM1156: lazysite adopts OOM 0.27"
subtitle: "The pinned OOM snapshot moves from 0.24 to 0.27, and a two-factor account that OOM now answers as pending is refused by name instead of being taken for a sign-in."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (accepted the OOM agent's L4 proposal)
area: odoo
status-note: "SHIPPED on n644: t/vendor/oom (OOM 33136df, Package 0.27), lib/Lazysite/Odoo/Session.pm, t/lib/OdooSessionHTTP.pm, SM747 re-filed spec; t/unit/odoo/25."
---

# What happened

OOM 0.27 is installed on the host (`libodoo-oom-perl` 0.27) and the OOM agent
filed L4 (Odoo's own two-factor code in the sign-in dialog), which depends on
it. The release manager accepted the proposals on 2026-10-17. lazysite's tests
run on a pinned snapshot (SM1081), so the first step is to adopt 0.27 as that
snapshot, as SM1117 did for 0.24, and to find what 0.27 changed that
lazysite reads.

Run on the new snapshot, and on the installed deb with
`LAZYSITE_OOM_LIB=/usr/share/perl5`, the Odoo tests (`t/unit/odoo`,
`t/integration/170-174`) failed in two files, both the same case: a
two-factor account (t/unit/odoo/25 and 27). Two gaps:

1. **The category was renamed.** 0.24 named "accepted, no session opened"
   `second_factor`; 0.27 names it `second-factor-required` (`is_no_session`
   still reads it). And the older fault OOM raises when Odoo sets no session
   cookie at all, "authentication did not establish a session"
   (`oom.NoSession`), is no longer a credential fault: it is category
   `other`. lazysite's message test sat behind the credential test, so it
   never saw it, and the account read as an internal error (500) instead of
   `two-factor` (403).
2. **`authenticate` no longer dies for a two-factor account that Odoo
   accepts.** It answers `{ second_factor => 'totp', pending => 1 }`, a true
   value, with a half-open session id held in the transport. lazysite took
   any true answer for a sign-in: it would have minted a signed cookie for a
   session that runs nothing. This is the gap that mattered, and no test
   covered it, because the stand-in for Odoo's HTTP never played the pending
   route.

# What shipped

- `Lazysite::Odoo::Session::sign_in` refuses a pending answer by name
  (`two-factor`, 403), ends the half-open session at Odoo, and sets no
  cookie. `_classify` reads `is_no_session` and both category spellings
  first and the message for any fault, as before 0.24.
- `t/lib/OdooSessionHTTP.pm` plays Odoo's `auth_totp` step as OOM reads it
  (a half-open session, the code form, a wrong code, the rate limit, the
  trusted-device cookie), so SM1157 can test through OOM's real transport.
- `t/vendor/oom` is OOM commit 33136df ("Package 0.27"), the code the
  installed deb carries, by `tools/vendor-oom.sh` (214 files; t/lint/261's
  MANIFEST).
- SM747's filed copy of the mapper specification is re-filed from it:
  sections 7 to 10 and the spec's Open list, the recorded sha256, the
  provenance rows (t/lint/207).
- The plugin's dependency floor is unchanged (`libodoo-oom-perl >= 0.03`):
  nothing here needs 0.27 on every path. SM1157 refuses the two-factor step
  by name on an OOM that cannot do it.

The Odoo tests pass on the new snapshot and on the installed deb.
t/unit/odoo/25 fails without the change to `Session.pm`.
