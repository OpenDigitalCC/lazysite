---
id: SM1181
title: "SM1181: the pool decides who is signed in, and hands the answer to the page as a value"
subtitle: "SM1082 track C2, planned and reviewed before any code. The pool's front door verifies the session with the verifier the auth wrapper calls and renders a signed-in page in the worker, with no exec and no identity header; the manager API loses the wrapper's program; the rest waits for C3."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-19
raised-by: the release manager, 2026-10-19 ("Yes, plan + review first"), on SM1082 track C2 and the lab's note lazysite/inbox/2026-10-19-what-lazysite-adds-to-an-odoo-call.md
area: performance
status-note: "PARTIAL: S1 built on n675: request_session decides the identity for the auth wrapper and the data endpoint; BadUrl::guard shared; $STORE_FAULT reset per call; write_identity_env writes the wrapper's contract (t/integration/290, t/unit/auth/68). S2-S5 remain; C2 ships as one release after S4 (R7). R1-R8 ruled as proposed 2026-10-19."
---

# What was asked

SM1082, track C2 (docs/feature-requests/SM1082-every-surface-on-the-persistent-runtime.md):

> **Identity in-process** (phase 3, SM297): the front door verifies the session
> with `Lazysite::Auth::Session` and passes the identity as a value to the surface
> it dispatches, with no exec of the auth wrapper; headers are never read for
> identity in-process except through `request_identity` under `proxy_identity`.
> Its own security review and its own release.

The rulings of 2026-10-17 accepted R2 (C1, then C2 with its own review and
release, then C3) and R3 (`warm-fork` for credential-bearing surfaces, the pool for
the rest). C1 shipped as [[SM1169]]: the pool's parent preloads the engine, and
t/lint/269 classifies every file-scope variable of the resident code. The release
manager, 2026-10-19: "Yes, plan + review first". This filing is that plan and that
review. It changes no code.

The driver is the lab's note of 2026-10-19: an Odoo page call is 653 ms, of which
about 210 ms is "lazysite's request floor (two programs: the auth wrapper, then the
endpoint)", and the owner's target is that lazysite adds about 10-20 ms to what
oomd takes.

Constraints carried from SM1082 and SM297: nothing added to the web server's
configuration; one pool per site; SM760's privilege separation; plain CGI stays the
default and the dev-server path, with the wrapper's header contract unchanged on
it; t/lint/38 stays and stays passing; a pooled surface carries nothing about a
person from one request to the next.

# 1. Where identity is decided today

## The auth wrapper

`lazysite-auth.pl` runs on every request the front end wraps. Its top level runs
`_bad_url_guard` (SM128: a blocked address is refused, a probe path counts towards
a block) and then dispatches on `?action=`: `login`, `logout`, `claim`, `exchange`,
`rotate`, `forgot` and `unsubscribe` are answered by the wrapper itself; anything
else is `handle_request`, which:

1. asks `Lazysite::Util::proxy_identity($LAZYSITE_DIR)` whether this request's TCP
   peer is a trusted proxy (SM1129) and, if so, reads the proxy's user through
   `Lazysite::Auth::Identity::request_identity( proxy => $pid )`; a proxy user wins
   and the cookie is not consulted (SM1130, SM1131);
2. otherwise calls `Lazysite::Auth::Session::verify_session_cookie()`;
3. on success sets `HTTP_X_REMOTE_USER`, `HTTP_X_REMOTE_GROUPS` (the fresh
   resolution, SEC-2026-07 M5) and `LAZYSITE_AUTH_TRUSTED=1`, deletes
   `HTTP_X_REMOTE_NAME`, `_EMAIL`, `HTTP_X_PAYMENT_VERIFIED` and `_PAYER` (SM794),
   sets `HTTP_X_REMOTE_NAME` from the server-side record for an Odoo-minted session
   (SM1160), `LAZYSITE_AUTH_SID` (SM141) and `LAZYSITE_AUTH_NO_PASSWORD` (SM1070);
4. logs the failure reason at the level each has always had (`no-cookie`,
   `malformed`, `signature`, `expired`, `no-account`, `disabled`, `cannot-tell`,
   `odoo-off`/`-unsecured`/`-stale`/`no-record`, `revoked`);
5. refuses a self-exec (SEC-2026-07 H7), hands its time to the surface
   (`Lazysite::Timing::handover`, SM1144) and `exec`s `LAZYSITE_PROCESSOR`.

On a failure it sets nothing; the client's own `X-Remote-*` headers then reach the
surface, whose trust gate strips them.

## The verifier

`Lazysite::Auth::Session::verify_session_cookie` is the one chain (SM411): read the
`lazysite_auth` cookie from `$ENV{HTTP_COOKIE}` (`_read_cookie`); HMAC with
`auth/.secret` (`_auth_secret_read`, read on every call, never cached); payload
shape (three, four or five fields, SM141/SM614); expiry against
`session_lifetime()`; then for a local account `_account_state` (SM1070),
`account_disabled` (SM071), `session_revoked` (SM141, SM1040's kept session),
each failing closed on a broken store with `cannot-tell` (SM1024), and
`load_user_groups` read fresh. An `odoo=` payload goes to `_verify_odoo_session`
(SM1160): the opt-in, the unsecured-site refusal, revocation by sid, the newest
record for the sid in `auth/sessions.jsonl` (`_odoo_record`), its `checked` time
against `odoo_identity_ttl`, and the record's groups less any the current map no
longer grants. It returns `{ user, sid, groups, no_password }` (plus `odoo`, `name`,
`stale` for an Odoo session) or `( undef, $why, %detail )`.

Its context is package state: `$LAZYSITE_DIR` (set by each script; `local`ised by
the data, Odoo and form surfaces), `%LIFETIME_CACHE` (keyed by directory) and
`$STORE_FAULT`, which `verify_session_cookie` clears before the stages that set it,
but `account_disabled` and `session_revoked` set without clearing when called on
their own.

## The reader and the proxy answer

`Lazysite::Auth::Identity::request_identity` is the only code that reads identity
out of the environment (t/lint/268). Three states, by `LAZYSITE_AUTH_TRUSTED` and
`proxy_identity`: `cookie` (the wrapper vouched; the fixed names), `proxy` (the peer
is listed; the configured names, SM1131-SM1133), `direct` (the fixed names, which
the trust gates strip from a real request). Every result passes through
`_drop_address_blocked` (SM1140): a group the visitor's address is refused for does
not count. `Lazysite::Util::proxy_identity` reads `auth_proxy_trusted` and
`auth_proxy_trusted_from` and the peer from `REMOTE_ADDR`; the processor holds a
module-free copy, `_proxy_identity`, held equal by t/unit/processor/132.

## The trust gates

`apply_trust_gate` (lazysite-processor.pl) returns at once under a trusted proxy;
otherwise it deletes any custom-named identity or payment header, and unless
`LAZYSITE_AUTH_TRUSTED` is `1` deletes the six fixed headers and logs the attempt.
The manager API has its own gate block at its top (`$trusted`, line 187). Lint 13
and lint 38 hold that every CGI reading a trust header gates it; lint 268 that
nothing but the reader reads them.

## The pool today

`lazysite-processor.pl`'s pool branch preloads (`_pool_preload`, SM1169), forks
through `FCGI::ProcManager`, and runs `handle_one_request` per `Accept()`. FCGI.pm
replaces `%ENV` on every `Accept()` (the comment above `$FRONT_DOOR`; t/lint/43).
Under `FRONT_DOOR=1`, `_front_route` (the module-free twin of
`Lazysite::FrontDoor::route`, t/lint/42) marks as `wrapped` exactly: a request
carrying a `lazysite_auth` cookie that is not for an existing static file; any
existing static, legacy page or legacy index on a site with an ACL store; and
`/cgi-bin/lazysite-processor.pl` and `/cgi-bin/lazysite-manager-api.pl`.
`_front_relay` sets `$ENV{LAZYSITE_PROCESSOR}`, forks, and the child `exec`s
`lazysite-auth.pl`, which then `exec`s the target. That is the two programs per
signed-in request. A trusted-proxy request with no cookie is not wrapped and is
already decided in the worker, through `request_identity` under `_proxy_identity`.
Every other `/cgi-bin/lazysite-*.pl` is relayed unwrapped: one program.

That is the one-rule pool template (`installers/*/vhost-one-rule-pool.conf.example`).
The split pool templates send a signed-in request to the pool not at all:
`installers/nginx/vhost-fcgi.conf.example` rewrites a page miss carrying
`lazysite_auth` to the internal `/lazysite-session-carveout`, which runs
`lazysite-auth.pl` under fcgiwrap with `LAZYSITE_PROCESSOR` as a FastCGI parameter
("the pooled worker is anonymous BY DESIGN"), and the Apache fcgi template does the
same by rewrite. Every shipped template wraps exactly the processor and the manager
API, blanks the six trust headers at the edge, and runs every other surface direct.
The dev server (`tools/lazysite-server.pl`, `handle_request`) wraps every
`/cgi-bin/lazysite-*.pl` but the wrapper itself when the site has accounts - MCP,
OAuth, data and Odoo included - which is wider than any production front end. The
wrapper has no list of exec targets: the front end decides, and the wrapper refuses
only itself.

## Every surface

```datatable
columns: Surface | How identity reaches it today | What it trusts
widths: 3cm | X | 5cm
---
Signed-in page (processor) | Through the wrapper: fork, exec wrapper, exec processor (pool); the wrapper then the processor (CGI). `check_auth`, the manager entry, the admin bar (layout.pm), `scan:` (sources.pm) and the ACL group walk (acl.pm) each call `_request_identity`. `no_password` read from `LAZYSITE_AUTH_NO_PASSWORD` (main, layout.pm). | `LAZYSITE_AUTH_TRUSTED` and the fixed headers, after `apply_trust_gate`; or a listed proxy peer
Anonymous page, proxy-identity page (processor, pool) | In the worker: `request_identity` under `_proxy_identity`; no wrapper | the listed proxy peer only
Manager pages `/manager/*` (processor) | As a signed-in page; `handle_manager_path` asks `refuse_manager` (SM1140) and `_is_manager` (`ui`, SM1135) | as above
Manager API | Wrapped (cookie) or a Basic `lzs_` token verified in-process by `Lazysite::Auth::Verify` (SM685); CSRF on cookie writes; `refuse_manager` for both; capability gates | the wrapper's headers through its own gate, or the token
MCP | Not wrapped (the dev server wraps it, and it reads nothing the wrapper sets): `verify_bearer` takes a static `partner:lzs_` credential (`Lazysite::Auth::Verify::verify_credential`, narrowed by address) or an OAuth `lzat_` token (`Lazysite::Auth::OAuth::validate_token`, issued by `lazysite-oauth.pl`); the `mcp` capability, SM127's refusal of interactive accounts, per-tool caps; no CSRF (bearer only). It strips `HTTP_X_REMOTE_*`, `LAZYSITE_AUTH_*`, the cookie and Authorization before an internal preview render. Its Odoo grant keys are per-account Odoo API keys in `lazysite/odoo/keys/`, used by `_odoo_who`: an Odoo credential, never a lazysite identity | its own credential only
DAV | Not wrapped anywhere (the wrapper would strip the Authorization header it needs): Basic auth against `lazysite/auth/users` in `_authenticate`, with a per-address rate block, disabled, expiry and the `webdav` capability; no cookie, no CSRF | its own credential only
Data endpoint | Not wrapped in any shipped front end (the dev server wraps it): `verify_session_cookie` itself, or a proxy identity (SM1137); then deletes every `HTTP_X_REMOTE_*`, sets the sentinel (for an anonymous caller too, unless the identity is a proxy's) and the fixed headers from its own session, for what it calls; CSRF on writes | its own verification; a listed proxy peer
Odoo endpoint | Not wrapped in any shipped front end (the dev server wraps it, which is the lab's two programs): `verify_session_cookie( odoo_stale_ok => 1 )` itself; the `odoo=` site sign-in and its record in `auth/sessions.jsonl` (SM1160); the person's Odoo session in the signed `lzs_odoo_session` cookie; the visitor token for sign-in and sign-out; `refuse_signin` (SM1159) | its own verification and its own cookies
Forms (`form-handler.pl`) | A plain CGI, never wrapped; reads no identity header (SM402); `verify_session_cookie` only to waive the rate limit and name the actor; the form's `_tk` is an HMAC of the time (`lazysite/forms/.secret`), not a session token | its own verificationSign-in, sign-out, claim, token exchange, forgot, unsubscribe | `lazysite-auth.pl` itself, by `?action=`; `LoginRate` (SM1043), `refuse_signin` (SM1159), the account gates (`_account_gates`) | the credential presented
```

# 2. The design

## The identity value

One function produces it, and both the wrapper and the front door call it, so the
CGI path and the pool cannot drift:

`Lazysite::Auth::Session::request_session( lazysite_dir => ..., proxy => $pid,
cookie => $header )` returns `( $ident, $why, %detail )` where `$ident` is

    { user, groups => [ ... ], name, email, sid, no_password, odoo, stale,
      source => 'cookie' | 'proxy' }

It is `handle_request`'s steps 1 and 2 moved out of the script: a listed proxy
peer with a user wins (the proxy's fields read by `request_identity`, unchanged);
otherwise `verify_session_cookie`, reading the cookie from the argument rather than
`%ENV`. Groups are the verifier's fresh answer passed through the same
`_drop_address_blocked` the reader applies, so a value and a header give one
answer. `handle_request` keeps its log lines and its header writes, made from the
value; nothing on the CGI path changes what it emits.

## The pool's front door

For a request `_front_route` marks `wrapped` with surface `processor`:

1. `reset_request_state` has run (it is the first line of `handle_one_request`).
2. The front door runs the bad-URL guard the wrapper ran (moved from
   `_bad_url_guard` into `Lazysite::BadUrl::guard`, which the wrapper then calls).
3. It calls `request_session` once and stores the value in the processor's
   per-request `our $REQUEST_IDENT`. A failure stores an anonymous value with the
   reason, and logs it as the wrapper does.
4. It returns to `main()` in the worker. No fork, no exec.

In the worker, `_request_identity` passes `identity => $REQUEST_IDENT` to
`request_identity`, which returns the value (as `source` `cookie` or `proxy`) and
reads no environment at all. `no_password` comes from the value, not
`LAZYSITE_AUTH_NO_PASSWORD`. `apply_trust_gate`, when a value is held, deletes
every fixed and custom identity and payment header from `%ENV` whatever the
sentinel says, so nothing downstream can read a client's header even by mistake.
And in the pool, `request_identity` and `apply_trust_gate` never believe
`LAZYSITE_AUTH_TRUSTED` from `%ENV`: under FastCGI it is a parameter, and the only
producer of a trusted identity in a worker is the value.

For `wrapped` with surface `cgi` (the manager API), the front door does steps 1-3
and then relays to the manager API directly: in the forked child, after the fork
and before the `exec`, it first deletes the sentinel, `LAZYSITE_AUTH_SID`,
`LAZYSITE_AUTH_NO_PASSWORD` and the six trust headers whatever the parameters
carried, then writes the wrapper's exact header contract from the value (the same
helper the wrapper uses, producing or clearing every field as SM794 requires, so
t/unit/processor/71 holds both). An anonymous value writes nothing but the deletions. One program
instead of two. The worker's own `%ENV` is never written.

## Which surfaces move, and which wait

```datatable
columns: Surface | In C2 | Why
widths: 3.2cm | 3.6cm | X
---
Signed-in pages, `/manager/*` pages, ACL-protected statics | in the worker | the worker is already the processor; only the identity's route changes
Manager API | one program (no wrapper) | it is a top-level script that answers by `exit` in dozens of places; running it in the worker is a rewrite, and SM1082 R3 gives it `warm-fork` (C3)
Odoo endpoint, data endpoint | unchanged in the pool (already one program, self-verifying) | in the worker they are C3's `pool` surfaces (the Odoo part waits for OOM's resident design, ruled 2026-10-17)
MCP, DAV, OAuth, the wrapper's own actions | unchanged | their credentials are their own; R3 gives the credential-bearing ones `warm-fork`
Forms | unchanged | outside the front door; verifies itself
Split pool templates (nginx and Apache `vhost-fcgi`) | R8 asks | they keep signed-in requests on the CGI wrapper by design, so S3 reaches them only if their carve-out goes
Dev server (CGI) | R6 asks | it wraps the Odoo, data, MCP and OAuth endpoints, which verify themselves and read nothing the wrapper sets, and that is the lab's second program
```

**What C2 needs from C3: nothing.** C2 adds no new process model; it uses the
worker that exists and keeps the relay for the rest. **What C3 needs from C2:** the
value (`request_session`) and `request_identity( identity => ... )`, so a
`warm-fork` or `pool` surface takes identity as an argument from the day it moves,
and C3 never touches the auth spine.

## The per-request reset

Every new piece of per-request state, and how SM1169's mechanism covers it:

```datatable
columns: State | Where | Cleared by | Held by
widths: 3.2cm | 3.6cm | 4cm | X
---
`$REQUEST_IDENT` | lazysite-processor.pl, `our` | `reset_request_state` at the start of the request, and again after `_access_record` at its end | t/lint/269 as `reset`; a new integration test (two requests, one worker)
`$Lazysite::Auth::Session::STORE_FAULT` | Session.pm | `reset_request_state` (today only `verify_session_cookie` clears it, and only for its own stages) | t/lint/269 as `reset`
`$LAZYSITE_DIR`, `%LIFETIME_CACHE` (Session.pm) | Session.pm | not request data: the site (one pool per site) and a cache keyed by directory | t/lint/269 as `exempt`, with those reasons
Every file-scope variable of a module the verifier pulls in (Auth::Session, Odoo::SiteSignin, Auth::Settings, Auth::Credential, BadUrl) | lib/Lazysite | classified when it joins the resident set | t/lint/269 computes the set from `@POOL_PRELOAD`; adding `Lazysite::Auth::Session` and `Lazysite::BadUrl` there brings them in, and an unclassified variable fails
```

The value is never held anywhere else: no module caches it, `request_identity`
returns it and does not keep it, and `_scan_identity` (sources.pm) already resets
per request (SM1169).

# 3. Security review

Each threat, the protection and the test that must hold it. A test marked "new"
is written in the slice that adds the protection.

```datatable
columns: Ref | Threat | Protection | Test
widths: 0.9cm | 4cm | X | 4.2cm
---
T1 | One visitor's identity is served to the next in the same worker | `$REQUEST_IDENT` is cleared at both ends of `handle_one_request`; set only after `reset_request_state`; no module keeps the value | new integration test: one worker, signed-in then anonymous then another account, each sees only itself (on 288's harness); t/lint/269 with `$REQUEST_IDENT` as `reset`
T2 | A client-sent `X-Remote-*` (or a custom-named header) is read as identity in the worker | in the pool the worker's only trusted producer is the value; `apply_trust_gate` strips every identity header when a value is held; the sentinel is not believed from `%ENV` in the pool | t/lint/38, 13, 268 unchanged; new: a forged `X-Remote-User` with a valid cookie, with an invalid cookie and with none, in the pool, never becomes the identity
T3 | `LAZYSITE_AUTH_TRUSTED` or `LAZYSITE_AUTH_SID` arrives as a FastCGI parameter | not a client header (no `HTTP_` prefix) so only web-server configuration can send it; the pool ignores the sentinel and takes the sid from the value | new: a pool request with the parameter set and no cookie is anonymous
T4 | A proxy identity and a cookie disagree | `request_session` keeps SM1130's order exactly: a listed proxy peer with a user wins, the cookie is not consulted | t/integration/263, 264, 265, 272 unchanged; the 263 cases repeated through the pool
T5 | A surface loses a check the wrapper made | the wrapper's per-request checks are listed in section 1: the bad-URL guard moves to a shared function and runs in the front door; disabled, removed, revoked and cannot-tell are the verifier's and come with it; fresh groups and the address-dropped groups are in the value; the login rate limit, `refuse_signin` (SM1159) and the account gates belong to sign-in, which stays in the wrapper; CSRF is the manager API's and the verifier's token, unchanged; `refuse_manager` (SM1140) is the processor's and the API's | t/integration/14 (through the pool too, new), 187, 243; t/unit/auth/14, 52, 55, 56, 40, 67; t/integration/280, 285, 286; t/unit/manager/43, 226
T6 | The worker runs with more privilege than the CGI, or holds secrets across requests | the worker is the pool's `USER` (SM760: the request path's user), the same user as today's relayed wrapper, which is a fork of that worker; `auth/.secret` is read per call into a lexical and never cached (`_auth_secret_read`) - C2 keeps it so | t/unit/daemon/10; new: a lint that Session.pm keeps no file-scope copy of a secret
T7 | An exception, a `die` or a timeout skips the reset | the reset is at the START of the next request, not only the end, so a request that dies leaves nothing the next one reads; `handle_one_request`'s eval turns a die into a 500 and still writes the access record; a signal that ends the worker ends its state with it | t/integration/15; new: a request that dies after the identity is set, followed by an anonymous one in the same worker
T8 | The Odoo site sign-in record is read for the wrong person, or a stale one counts | unchanged: the verifier's `_verify_odoo_session` reads the newest record for the sid and requires its user to match; `odoo_stale_ok` stays the Odoo endpoint's alone (the front door never passes it) | t/unit/odoo/63, 64, 54
T9 | MCP bearer and OAuth tokens, the Odoo grant keys (`lazysite/odoo/keys/`), DAV Basic and control-API tokens reach the in-process path or the worker's memory | they do not: those surfaces are not wrapped and not moved, so no worker reads their stores; the manager API's token path is untouched and still runs in its own child; a cookie and a token together are still refused (the cookie half now coming from the value) | t/unit/mcp/01, 02; t/unit/oauth/01-04; t/unit/dav/01; t/unit/manager/10, 45; t/integration/54, 111
T10 | The pool and CGI decide differently | one function, `request_session`, behind both; the wrapper's header block is written from its value by the same helper the relay child uses | t/unit/processor/71 extended to the helper; a new parity test: the same cookies and peers through the wrapper and through `request_session` give the same identity
T11 | Logging changes leak or lose evidence | the front door logs the wrapper's lines at the wrapper's levels (SM1099: DEBUG for the ordinary cases); no cookie value is logged | t/unit/auth/61 and a pool twin
T12 | A cache or memo keyed on identity outlives it | page caching is decided by the same code as today (gated and per-viewer pages, SM857); `%ADDR_MEMO` (AddressScope) is keyed on the request's own address inputs; `_scan_identity` resets | t/integration/238, 12, 288
T13 | The bad-URL blocker today misses a pool front door's unwrapped requests | an existing gap, not C2's: the blocker runs where the wrapper runs, and the front door relays only wrapped requests through it, so an anonymous page in the pool is never counted | R5 asks whether the front door should run the guard for every request
T14 | A new reader of identity in the front door slips past the lints | lint 38 reads a fixed list of six scripts (its own comment says it does not), and none of them is a module; lint 268 holds the reader to `request_identity`; lint 13 globs every root script | S2 adds the front-door part and Session.pm to lint 268's reading, and lint 38 reads every root `*.pl` and the processor's parts by glob
```

## Found in passing, not C2's

- Under the one-rule templates `/cgi-bin/form-handler.pl` does not match the front
  door's `lazysite-[a-z-]+.pl` pattern, so it appears to fall to "page miss" and
  reach the processor, not the form handler. Read, not tried.
- `Lazysite::Auth::OAuth::save_store` sets the token store to 0660; the module's
  header says 0600.

## Tests that pin today's behaviour and stay green unchanged

The wrapper and the CGI path: t/journey/02, t/integration/14, 18, 28, 187, 243,
248, 263, 287, t/unit/auth/01-18, 26, 41, 61, t/unit/processor/71, t/unit/tools/01.
The verifier: t/unit/auth/12-16, 22, 23, 40, 52, 55, 56, t/unit/lib/05,
t/unit/manager/24, 220, t/integration/131, t/unit/users/08. The reader and the
proxy: t/unit/auth/62-65, t/unit/processor/08, 132, 133, 140, t/integration/106,
107, 108, 109, 130, 185, 264, 265, 266, 271, 272, 280, 281, 285, 286,
t/unit/manager/39, t/unit/forms/07, t/lint/35. Rate, address, CSRF: t/unit/auth/03,
04, 24, 25, 66, 67, t/unit/odoo/54, t/unit/manager/10, 13, 29, 43, 45, 226-228,
t/unit/dav/10. The pool: t/integration/15, 49, 50, 110, 239, 288, t/unit/lib/21,
t/unit/tools/40, t/tools/171. Odoo, MCP, DAV, data, manager: t/unit/odoo/63, 64,
t/integration/174, t/unit/mcp/01, 02, t/unit/oauth/01-04, t/integration/29, 54,
59, 60, 69, 80, 95, 98, 111, t/unit/dav/01, 08, 12, t/unit/manager/09, 16, 18, 40,
48, 51, 138, 159, t/integration/12, 31, 52, 77, 220, 238, t/unit/processor/20, 70.
The lints: 13, 14, 38, 42, 43, 267, 268, 269 (its table grows; its rules do not).

Most of the suite stands in for the wrapper (t/lib/ManagerSession.pm sets the fixed
headers and the sentinel and runs a CGI): that contract is the CGI path's and stays,
so those files stay green by design.

# 4. Slices

Each slice is releasable alone, in order.

```datatable
columns: Ref | Slice | What it proves
widths: 0.9cm | X | 5.4cm
---
S1 | `request_session` in Lazysite::Auth::Session; the wrapper's `handle_request` and the data endpoint call it; `Lazysite::BadUrl::guard` shared; `$STORE_FAULT` reset; the header block's helper. No pool change. | the CGI path is byte-identical (the tests above, unchanged) and both callers give one answer (the parity test, T10)
S2 | `request_identity( identity => ... )` and the processor's `$REQUEST_IDENT`, set by nobody yet; `_request_identity` and the `no_password` readers take it when held; lint 269 rows; the pool never believes the sentinel from `%ENV`. | the reader returns a value without touching `%ENV` (unit); a pool request with the parameter set is anonymous (T3)
S3 | The front door renders a wrapped processor request in the worker from the value (signed-in pages, `/manager/*`, ACL statics). Behind `FRONT_DOOR` as today; nothing else. | T1, T2, T5, T7, T11 in the pool; t/integration/50 still relays the rest; the bench's `page-signed-in` under `--with-pool`
S4 | The manager API relayed without the wrapper, the child writing the contract from the value. | t/unit/manager suites through the pool; one program in the bench's `manager`
S5 | Only if R6 is yes: the dev server stops wrapping the surfaces that verify themselves (Odoo, data, MCP, OAuth), as no production front end wraps them, and runs the bad-URL guard for them itself. | the lab's `?csrf=1` floor drops by one program; t/integration/59, 272, t/unit/odoo/63 unchanged
```

**Release plan.** C2 ships alone, in a release that carries nothing else, after S1
to S4 (and S5 if ruled) land and the overnight suite is green. Edge test-plan rows,
one per surface, filed to the sites inbox with the cut:

```datatable
columns: Surface | Edge row
widths: 3.4cm | X
---
Signed-in page | a member's page on a pooled site: the member sees it; signed out, it redirects; a second browser as another member in the same minute sees only their own name
Group-gated page | a non-member is refused; adding them to the group lets them in on the next request
Disabled, removed, revoked | each, set on the Users or Sessions page, stops the open session on its next request
Forged header | a request with `X-Remote-User: <an operator>` and no cookie is anonymous; with a member's cookie it is the member
Manager | the manager opens, saves (CSRF), and refuses an account without `ui`; Sessions marks "this session"
Proxy identity | on the proxy fixture site, the directory user wins over a stale cookie
Address rules | a group limited by address does not count from another address; a manager limited by address is refused
Bad URL | ten probe paths from one address block it, through a signed-in request
Odoo site sign-in | an `odoo:` session sees its pages; past `odoo_identity_ttl` it grants nothing until refreshed
MCP, DAV, data, forms | unchanged: each signs in and works as before
```

# 5. Rulings needed

Release manager, 2026-10-19: "All as proposed". The Proposed column is the ruling.

| Ref | Question | Proposed (ruled 2026-10-19) |
|---|---|---|
| R1 | C2's scope: signed-in pages in the pool worker, the manager API without the wrapper's program, everything else unchanged until C3 | Yes |
| R2 | The value is produced by one new function, `request_session`, called by the wrapper and the front door alike | Yes |
| R3 | In the pool, `LAZYSITE_AUTH_TRUSTED` from `%ENV` is never believed; the value is the only trusted producer in a worker | Yes |
| R4 | A held value makes `apply_trust_gate` strip every identity and payment header, whatever the sentinel says | Yes |
| R5 | The front door runs the bad-URL guard for every request, not only those it would have wrapped (closes T13) | Yes, in S3 |
| R6 | The dev server stops wrapping the surfaces that verify themselves (Odoo, data, MCP, OAuth), matching production (S5) | Yes: the lab runs the dev server, and this is its second program |
| R7 | C2 ships in a release of its own, S1 to S4 (S5 if R6), with the edge rows above | Yes |
| R8 | The split pool templates (`vhost-fcgi`) keep their session carve-out to the CGI wrapper, so C2 is the one-rule pool's; retiring the carve-out is a later template change with its own upgrade note | Yes: keep them as they are in C2 |

# 6. Expected effect

From the recorded figures only; nothing was measured for this filing.

- **A signed-in page on a pooled site.** Today it is relayed: fork, exec the
  wrapper, exec the processor (97 ms against 107 ms CGI on SM294's reference host,
  SM1082's table). After S3 it is the worker's own render, which SM1169 measured as
  a warm cache hit of 1.1 ms and a warm miss of 12.6 ms (loaded host), plus the
  verifier's reads of five small files. SM1082's target, "a few milliseconds after
  C2", is that.
- **The manager API on a pooled site.** One program instead of two. SM1144's
  figures put the wrapper's share at about 200 ms of 510 on the loaded host (`odoo`
  against `odoo-direct`), so roughly 40% of a relayed manager request; the rest
  waits for C3's `warm-fork`.
- **The Odoo endpoint.** On a pooled site it is already one program, so C2 alone
  does not move it. The lab's ~210 ms floor is two programs because the dev server
  wraps it: S5 (R6) removes one, about 200 ms on SM1144's loaded host. The other,
  and the owner's 10-20 ms target, needs C3's `pool` surface for the endpoint
  and oomd's light client (61 ms against 250 ms for OOM, the lab's note).

# What shipped

## S1: one function decides, the CGI path unchanged (n675)

`Lazysite::Auth::Session::request_session( lazysite_dir, cookie, proxy )` is
`handle_request`'s steps 1 and 2: a listed proxy peer with a user wins (read by
`request_identity`, unchanged); otherwise `verify_session_cookie`, given the Cookie
header as its new `cookie` argument rather than reading `%ENV`. The `cookie` argument
is required: a caller that omits it is refused, so nothing falls back to the
environment. A cookie identity's groups are the verifier's fresh set, de-duplicated
and passed through `Lazysite::Auth::Identity::address_allowed_groups` (the reader's
SM1140 filter). The value is `{ user, groups => [...], name, email, sid,
no_password, odoo, stale, source }`; a failure is the verifier's `( undef, $why,
%detail )`. `odoo_stale_ok` is not passed through (T8).

- **The wrapper** asks `Lazysite::Util::proxy_identity` once, passes it in, and keeps
  every log line at its level. A cookie value is written for the surface it execs by
  `Lazysite::Auth::Identity::write_identity_env`, the one writer of the wrapper's
  contract (user, groups, the sentinel, the SM794 clears, the SM1160 Odoo name,
  `LAZYSITE_AUTH_SID`, `LAZYSITE_AUTH_NO_PASSWORD`); S4's relay child will call it
  too. A proxy value writes nothing, as before.
- **The data endpoint** asks `request_session` with the same arguments; what it then
  writes to its environment is unchanged.
- **`Lazysite::BadUrl::guard`** is the wrapper's `_bad_url_guard` (same keys, last
  match wins, same visitor address, same audit row and log line) and returns a
  verdict; the wrapper keeps the 403 and the exit. S3's front door calls it.
- **`$STORE_FAULT`** is cleared at the start of `verify_session_cookie` and of
  `request_session`, so a fault on one call no longer stands after a later call that
  returns before the stages that cleared it (a no-cookie request, a proxy request).

Two differences on the CGI path, both in the header text and neither in any
decision: the groups header now carries the address-filtered set (the reader
filtered the same set downstream, so every reader's answer is unchanged), and a
group listed twice in the groups file appears once.

Proved by t/integration/290: fourteen requests (no cookie; a member cookie; disabled,
removed and revoked accounts; a broken session store; a trusted proxy user with and
without a cookie; a trusted peer naming nobody; forged `X-Remote-User` from a trusted
and an untrusted peer, with and without a cookie; an untrusted peer sending the
proxy's headers; an address-limited group) through the real wrapper and the real
data endpoint give one identity, equal to the base tree's recorded answers, each by
one call to `request_session`. t/unit/auth/68 pins the function, the helper and the
`$STORE_FAULT` reset. t/unit/processor/71 and t/lint/38 ask their produce-or-clear
question of `write_identity_env`, and t/lint/268 holds the wrapper, the data endpoint
and `request_session` to the accessor.

# Related

[[SM1082]] (the plan; C2 is this), [[SM1169]] (C1), [[SM1144]] (T0), [[SM297]]
(identity as a value), [[SM294]], [[SM411]], [[SM1129]], [[SM1130]], [[SM1131]],
[[SM1137]], [[SM1140]], [[SM1159]], [[SM1160]], [[SM760]], [[SM973]].
