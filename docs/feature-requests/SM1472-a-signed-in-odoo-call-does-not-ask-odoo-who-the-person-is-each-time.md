---
id: SM1472
title: "SM1472: a signed-in Odoo call does not ask Odoo who the person is each time"
subtitle: "An in-process signed-in call opens with Odoo's get_session_info, the slowest RPC of the call, and the extension passes OOM no field-cache setting, so the field-definition stamp is re-read every few seconds or the cache is bypassed."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "a field report from a lab site (archived at inbox/archive/2026-11-17-odoo-extension-per-call-identity-and-field-cache.md)"
area: performance
status-note: "CANDIDATE, filed 2026-11-17. Nothing built. Target 0.17.x edge. Checked against the code below: the mechanism is corrected (the argument is OOM's session_identity, and the site record holds no uid), R3 confirmed. Questions for a ruling at the end, the first of them a security one."
---

# What was reported

A read-only trace of the real `lazysite-odoo.pl` against an Odoo 18 instance, in-process OOM, one
connection per call (TCP 0.3 ms, TLS 1.3 handshake 2.9 ms, so the connection is not the cost). The
RPC list per call came from a wrapper on `Odoo::Transport::post`. The reporter's measurements,
recorded as theirs and not repeated here:

- A signed-in read of 121 rows made 4 RPCs, or 7. `/web/session/get_session_info` took 150 to 260 ms,
  the three data reads 11 to 70 ms each, and the `ir.model.fields` stamp read (3 RPCs, sometimes)
  about 150 ms together.
- A signed-in call that reads 7 tables made 8 RPCs, or 11 with the stamp read. `get_session_info` is
  the slowest of the call and 35 to 60 percent of its RPC time.

# What the code says

Each claim was read against lazysite at d886cf350 and OOM 0.45 (/srv/projects/odoo/oom, read only;
the copy lazysite vendors under t/vendor/oom has the same Session.pm lines).

Confirmed
: - `Lazysite::Odoo::context` builds a session context for a person's call (Odoo.pm, the
    `defined $o{session}` branch, lines 1002 to 1033). OOM's session transport asks
    `/web/session/get_session_info` for the identity on `authenticate` when it holds none
    (Transport/Session.pm lines 339 to 345), and takes one from `identity => $args{identity}`
    (line 92).
  - The Config the extension builds sets no `cache_ttl_fields_stamp` and no `cache_stamp_conf` in
    either branch of `context`. OOM's defaults are 5 seconds and none (Ops/Config.pm lines 244,
    245), and the cache is on unless `cache = 0`. `Odoo::Client::fields_cached` keeps a login's
    field definitions only while it holds a stamp, and with no stamp reader for a login that may
    not read `ir.model.fields` it fetches live (Client.pm lines 596 to 610; Doctor's message at
    Core/Doctor.pm line 357 says the same). That is the reporter's account, read in the code and not
    run here.
  - `odoo_daemon` exists (extensions/odoo.pl line 123), is `off` by default, and `lazysite check`
    says nothing when it is off: `Check::daemon` returns at once when the mode is `off`
    (extensions/odoo/lib/Lazysite/Odoo/Check.pm, the `mode ne 'off'` test). The only user text
    is the setting's own note. No page of the docs recommends it for a call a person waits for.

Corrected
: - **How the identity is passed.** The extension does not call `Odoo::Transport::Session->new`
    in production: it does so only when `$Lazysite::Odoo::Session::HTTP` is set, which is a test
    seam ("unset in production"). Otherwise it gives `Odoo::Ops::Context->new` a config whose
    credential is `session`, and OOM builds the transport (Context.pm lines 99 to 101 and
    `build_transport`, 223 to 243). The argument that carries a known identity is
    **`session_identity`** on `Context->new`, which forwards it as `identity` to the transport.
    So R1 is a new argument to that one call, not a change of transport.
  - **What the site holds.** "The site already holds the person's verified Odoo identity (the
    sessions record, valid for `odoo_identity_ttl`)" is not so. The site session record
    (`Lazysite::Auth::Session::mint_provider_session`) holds `sid`, `user` (`odoo:<login>`), `t`,
    `provider`, `checked`, `name`, `groups`, `ip` and `ua`: no uid and no partner. The Odoo session
    id itself is in no store; it rides in a signed cookie (`lzs_odoo_session`, twelve hours,
    SM747 B). The identity cookie carries a name, language, time zone, companies and groups and,
    by its own rule (OI4, Lazysite::Odoo::Identity), "never the session id, a user id, a login".
    So the uid a call needs is held nowhere on the site today; R1 would hold it for the first time.
  - **"At least `uid`" is not enough.** What OOM reads from a session's identity: `Acting::person`
    takes `uid`, `login`, `name` and `partner_id` (Acting.pm lines 150 to 155; without a
    `partner_id` it reads `res.users` instead, which costs a call) and the commercial partner it
    caches on the identity; `Client::fields_cached` keys the field cache on the identity's `login`
    (an identity with no login makes it fetch live). So a uid alone would trade one RPC for a
    bypassed field cache. The whole of `_identity` except `raw` is what a faithful record holds
    (uid, login, name, lang, tz, company_id, company_ids, is_admin, is_system, partner_id, db).
  - **oomd already does this for 60 seconds.** With `odoo_daemon: on`, oomd remembers a session's
    identity for `cache_ttl_session` (default 60 s) and gives it to the transport
    (Ops/Service.pm `_remembered_identity`, `_settle_session`), forgets it when Odoo says the
    session has expired, and reads the field-definition stamp through its own connection
    credential for every login (`_stamp_source`). So for a site with oomd running, R1's per-call
    cost is already at most one `get_session_info` per session per minute, and R2's stamp read
    is already shared. The in-process path (oomd off, or down with `on`) is the one the trace
    measured and the one R1 and R2 change.

Could not check
: - Every timing and RPC count above. They come from a trace this build did not run, against an
    Odoo this build must not reach.
  - Whether an Odoo session id keeps one uid for its whole life. R1's safety argument below relies
    on it, and it is Odoo's behaviour, not code in either tree.

# The requests

R1
: **Give OOM the identity of the person's session, held server-side, so the call does not ask Odoo.**
  Pass `session_identity => {...}` to `Odoo::Ops::Context->new` in the session branch of
  `context`, from a record the extension keeps for the Odoo session; ask Odoo (today's
  `get_session_info`) only when there is no record, it has expired, or its session id has changed.
  The record is written from Odoo's own answer at sign-in and at each identity refresh
  (`identity_of`, `site_session_renew`), which already ask Odoo, and it holds what OOM reads (see
  Corrected). Where it lives is the first question for a ruling.

R2
: **Pass OOM's field-cache settings through, with a default suited to a web call.** Two extension
  settings in odoo.conf, `odoo_fields_stamp_ttl` (to `cache_ttl_fields_stamp`, whole seconds, a
  default longer than 5) and a way for a login that may not read `ir.model.fields` to have the
  stamp read for it. OOM names that way `cache_stamp_conf`, a path to an ops config whose login may.
  The extension need not use that: `Context->new` takes a `stamp_source` code reference, so the
  extension could read the stamp through the connection user it already holds, with no second
  config file. The default and that choice are questions below.

R3
: **Say plainly that `odoo_daemon: on` is the setting for a call a person waits for.** In the
  setting's note and the Odoo extension's user docs: it is the whole of R1 and R2 for 60-second
  windows, and the in-process path is the fallback. And `lazysite check` says, at WARN, when
  `odoo_daemon` is `off`, the daemon extension is enabled, oomd is installed and the site has a
  pool conf (SM1226's own gate for "a front end"): the site could use oomd and does not. Nothing
  about it is a fault, so it names the setting and nothing else.

# Expected saving

As the reporter measured, not repeated here: R1 removes 150 to 260 ms per signed-in call (12 to 18
percent of a call at load 17; the `payslip-list` call's RPC time from 336 ms to about 150). R2
removes about 150 ms from a call in two. Both remove load on the Odoo side (one heavy
`get_session_info` per page). With oomd running, the saving of both is already taken for
60-second windows, and R3 is how a site finds that out.

# The security angle of R1

R1 makes the extension trust a record it holds, in place of Odoo's answer, for who a session is.
What decides whether that is safe:

- **What the record can change.** Every data RPC still carries the person's Odoo session id, and
  Odoo authorises each one against that session. A wrong record cannot widen what Odoo lets the
  call read or write. It can only misattribute: the actor in OOM's audit, the login a field
  cache is kept under, and the partner `Acting::person` scopes "my records" by (Acting.pm line
  372). That last is the real exposure: a record that named another person's partner would
  select that person's rows, within what the session may read. So the record must be one the
  visitor cannot write or choose.
- **Who writes it.** Only the extension, from Odoo's answer to the person's own session, never
  from a request's cookie or parameter. If it were put in a cookie the browser holds, a signed one
  would be tamper-evident but replayable and would break OI4 ("the identity cookie never carries
  a user id"); a server-side record keyed on the hash of the session id (as the audit already names
  a session by a hash of it, `session_label`) is not readable or writable by the visitor.
- **Expiry.** The record should expire no later than `odoo_identity_ttl`, the bound the site
  sign-in already uses for "Odoo was asked recently enough" (SM1160; default 900 s, 60 to 86400).
  The reporter's 28800 s is an operator choice, and it lengthens how long a renamed user or a
  moved partner keeps the old attribution; the call's audit and field cache would carry the old
  login for that long. A shorter bound for this record than the sign-in's is possible.
- **Logout.** Sign-out through the Odoo endpoint ends the Odoo session and the site session, each
  ending the other (SECURITY.md, SM1160). The wrapper's own logout ends the site session and leaves
  the Odoo session cookie until the next `?csrf=1` (the register's residual risk). The record
  must go with the Odoo session (sign-out, an expired-session fault from Odoo, the record's
  own expiry), not with the site session alone. A record that outlived its session would be inert
  rather than dangerous, since Odoo refuses the session id on the first RPC and the extension
  clears the cookie, but it would hold a person's partner and login on disk for longer than
  needed.
- **A changed Odoo user.** If Odoo's user behind a session id could change (a re-authentication that
  keeps the id), a record would name the old one. Odoo's own session handling is the authority and
  this build did not check it (see Could not check). If it is not certain, R1 would also compare
  the uid the first data RPC returns where OOM already has it, or restrict the record's life to
  the session's.
- **Privacy.** The record holds a login, a name and a partner id. It would sit in the extension's
  private store (`store_dir`, where its plans are kept), owner-only, and never be shown. It is personal data, so a
  retention bound (its expiry) and deletion at sign-out are part of it, as for the site session.

This is a change in the security area (auth, a stored identity), so a build gets a docs/SECURITY.md
register entry marked "awaiting the release manager's confirmation".

# What a build must keep true

- A call without a record, or past its expiry, asks Odoo as today. The slower path is the fallback,
  never a failure.
- Odoo's refusal of a session is still the end of the session: the record goes and the cookie is
  cleared (today's `clear_session`), and the call never falls back to the connection user.
- A test per request that fails against the old code: a signed-in call with a held record makes no
  `get_session_info` RPC and one without makes it; a past-expiry record is not used; sign-out removes it;
  the record cannot be written from a request.

# Questions for a ruling

1. **Where the identity lives, and whether the site may hold it at all.** (a) A server-side record
   keyed on a hash of the Odoo session id, in the extension's store, expiring at the sooner of
   `odoo_identity_ttl` and the Odoo session's end. (b) Add uid, login and partner to the
   identity cookie, which breaks OI4's "never a user id" and makes the cookie a credential-adjacent
   value. (c) Leave the in-process path as it is and make oomd the answer: R3 and a recommendation
   that a page a person waits for uses `odoo_daemon: on`, which already remembers the identity for
   60 seconds. The build prefers (c) first and (a) only if oomd is not wanted on a site; the
   release manager decides, since (a) stores a person's identity where there is none today.
2. **The expiry of the record**, if (a): `odoo_identity_ttl` as it stands, or a shorter fixed bound
   for this record, so a renamed user or a changed partner is picked up sooner than a site session
   is renewed.
3. **The default for the field-stamp interval.** A longer interval means a change to a model's
   fields in Odoo (a module installed or upgraded) is seen by a page up to that long later. 5 s is
   OOM's default and is right for a batch; for a web call the build suggests 60 s, which matches
   oomd's session window, but it is the release manager's to name.
4. **`cache_stamp_conf` or the connection user in memory.** The first is a file path to a second ops
   config holding a login; the second reads the stamp through the connection user the extension
   already holds, with no file. The build prefers the second (nothing new to protect or to
   misconfigure) and would expose no `cache_stamp_conf` setting. Agree?
5. **R3's warning.** Is a WARN from `lazysite check` for an unused oomd wanted, or only the docs? A
   WARN makes every pooled site without `odoo_daemon: on` report one, which is a sweep of existing
   sites.
