---
id: SM1181
title: "SM1181: the pool decides who is signed in, and hands the answer to the page as a value"
subtitle: "SM1082 track C2, planned and reviewed before any code. The pool's front door verifies the session with the verifier the auth wrapper calls and renders a signed-in page in the worker, with no exec and no identity header; the manager API loses the wrapper's program; the rest waits for C3."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: the release manager, 2026-10-19 ("Yes, plan + review first"), on SM1082 track C2 and the lab's note lazysite/inbox/2026-10-19-what-lazysite-adds-to-an-odoo-call.md
area: performance
status-note: "SHIPPED, a release of its own (R7): S1 request_session (n675, t/integration/290); S2 the pool never believes the sentinel (n677, 291, 292, 297); S3 signed-in pages in the worker (n684, 293, 294); S4 the manager API one program (n685, 295); S5 the dev server runs Odoo, data, MCP and OAuth direct (n688, 296)."
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

## S2: the reader takes a value, and the pool stops believing the sentinel (n677)

- **`Lazysite::Auth::Identity::request_identity( identity => $value )`** returns that
  identity (`user`, `name`, `email`, a copy of `groups`, and `source` - the value's
  `cookie` or `proxy`, otherwise `direct`) and reads nothing from `%ENV`: no header,
  no sentinel, no address. The groups are returned as held; `request_session` already
  filtered them for the address. An undefined `identity` is the reader as before.
- **`pool => 1`** (R3): the caller is a FastCGI worker. The sentinel from `%ENV` is
  never believed there, and the fixed names are not read either, since in a worker
  only a client produces them. A listed proxy peer is still read under its configured
  names (T4 unchanged).
- **The processor's `our $REQUEST_IDENT`** is declared and set by nothing yet (S3's
  front door will set it). `reset_request_state` clears it at the start of every
  request and `handle_one_request` clears it again after the access record.
  `_request_identity` passes it as `identity` and passes `pool` from the runtime.
  The three `no_password` readers (the 403 and page auth contexts, the admin bar)
  go through `_request_no_password`: the held value's flag; in the pool, nothing
  else; on CGI, `LAZYSITE_AUTH_NO_PASSWORD` as before.
- **`apply_trust_gate`** does not believe `LAZYSITE_AUTH_TRUSTED` in the pool, so a
  forged `X-Remote-User` arriving with the sentinel as a FastCGI parameter is
  stripped and logged as any untrusted header is. On plain CGI nothing changes.
  R4 (a held value strips every identity header) arrives with the value, in S3.
- **`$Lazysite::Auth::Session::STORE_FAULT`** is also cleared by
  `reset_request_state` (t/lint/269 now lists it as `reset`), beside the verifier's
  own clearing from S1.

A deployment whose web server passed `LAZYSITE_AUTH_TRUSTED` to the pool as a
FastCGI parameter, so that its workers took the proxy's or the client's
`X-Remote-*` as a session, now serves those requests as anonymous. No shipped
template does this; a site that wants a proxy's identity in the pool uses
`auth_proxy_trusted` and `auth_proxy_trusted_from` (SM1129).

Proved by t/unit/auth/69: with `%ENV` tied, every key looked at is recorded and a
forged operator is planted in it. A held cookie, proxy or anonymous value, and one
made by `request_session`, are returned with no key read. A bare request in the pool
with the sentinel is nobody, and a proxy peer is still read. t/integration/291 sends
`LAZYSITE_AUTH_TRUSTED=1` and `X-Remote-User: operator` to a page that needs a
sign-in. Through a pool worker, front door on and off, twice per worker, the request
is sent to sign in and the header is logged as ignored. The same request on plain
CGI still opens the page. t/integration/292 (288's harness) holds a value in one
request and checks it is gone afterwards: the next request is anonymous, another
account sees only itself, a request that died leaves nothing behind, and a value
still held when a request starts is cleared before `main()` runs.

The lints (T14). t/lint/38 reads every root `*.pl` and every module under `lib/` and
`plugins/` by glob, with the processor's parts as before, instead of its fixed six
scripts. `lazysite-data.pl` joins the wrapper as a producer. The identity reader is
held to gating but not to deleting, since it hands nothing on. The proxy gate may be
spelled `proxy_identity` (SM1129). t/lint/268 adds a sweep of every file for the
sentinel: only the accessor, the data endpoint and the two trust gates name it. That
sweep reads the front door's part and Session.pm, which is where the pool's identity
will be decided. It also checks that the processor's gate and the accessor do not
believe the sentinel in the pool, and that `_request_identity` passes
`$REQUEST_IDENT` and the runtime. t/lint/269 classifies `$REQUEST_IDENT` as `reset`.

## S3: a signed-in page is rendered in the worker (n684)

Under `FRONT_DOOR` (the one-rule pool), a request `_front_route` marks `wrapped` with
surface `processor` - a page with a session cookie, a `/manager/` page, a static or
legacy page on a site with an ACL store - is no longer relayed through the auth
wrapper. `_front_session` (lazysite-processor/front-door.pm) calls `request_session`
once, with the request's Cookie header and the render path's `_proxy_identity()`, logs
the outcome, and holds the value in `$REQUEST_IDENT`; `main()` then renders in the
worker. No fork, no exec, no header written. A failure holds an anonymous value
carrying the reason, so a wrapped request never falls back to its own headers.

- **What stays relayed.** The manager API (S4), `/cgi-bin/lazysite-processor.pl`, every
  other surface, and a wrapped request whose query names one of the wrapper's own
  actions (`logout`, `unsubscribe`, and on POST `login`, `claim`, `exchange`, `rotate`,
  `forgot`; `_front_wrapper_action` matches them as the wrapper does), so signing in
  and out is the wrapper's as before.
- **R4.** While a value is held, `apply_trust_gate` does not believe the sentinel on
  either runtime: every fixed and custom identity and payment header a client sent is
  stripped and logged. A listed proxy peer still returns before the strip (SM1129; its
  headers are the proxy's, and a value it gave was read from them), so T4 is as it
  was.
- **R5.** The front door runs `Lazysite::BadUrl::guard` on every request it does not
  hand to the wrapper (the wrapper guards those itself, so no probe counts twice),
  with the wrapper's keys, the visitor address under `trusted_proxies` (SM929) and the
  same block store and audit row; a blocked address gets a 403 from the worker. T13
  is closed: an anonymous probe now counts, and a blocked address is refused on every
  pooled request.
- **T11.** The wrapper's log lines moved to
  `Lazysite::Auth::Session::session_log_line`, which the wrapper and the front door
  both call, so the two log the same line at the same level (SM1099). The front door
  reads the site's `log_level` as the wrapper does. No cookie value is a field.
- **R8.** The split `vhost-fcgi` templates are unchanged. Their carve-out sends a
  signed-in request to the CGI wrapper and they run no front door, so S3 reaches only
  the one-rule pool.
- `Lazysite::Auth::Session` and `Lazysite::BadUrl` join `@POOL_PRELOAD`, so the parent
  loads them and t/lint/269 reads their file-scope variables. The verifier's time is
  the request's `identity` phase (SM1144).

**T5: each check the wrapper made, and where it happens now in the pool**

```datatable
columns: Check | Before S3 (relayed) | S3 (in the worker)
widths: 4.2cm | 4.6cm | X
---
Bad-URL guard (SM128) | the wrapper's top level | `_front_bad_url`, the same `Lazysite::BadUrl::guard`, on every request not handed to the wrapper (R5)
A trusted proxy's user wins (SM1130, SM1131) | `request_session` in the wrapper | `request_session` in the front door, with `_proxy_identity()`
Signature, shape, expiry | the verifier, through the wrapper | the verifier, through `request_session`
Removed account (SM1070) | the verifier (`_account_state`) | the same
Disabled account (SM071) | the verifier (`account_disabled`) | the same
Revoked sid, sign-out everywhere, the kept session (SM141, SM1040) | the verifier (`session_revoked`) | the same
A store that cannot be read (SM1024) | the verifier, failing closed | the same; `$STORE_FAULT` reset per request (S2)
Fresh groups (SEC-2026-07 M5) | the verifier's `load_user_groups` | the same
Groups refused for the address (SM1140) | `request_session` | the same
Odoo site sign-in, its record and `odoo_identity_ttl` (SM1160) | the verifier, never stale-ok | the same (T8)
SM794: name, email and payment cleared | `write_identity_env` | `apply_trust_gate` strips every client identity and payment header while a value is held (R4)
Odoo display name, sid, passwordless flag | written as headers | read from the value (S2's readers)
Self-exec refusal (SEC-2026-07 H7) | the wrapper | nothing is exec'd
Log lines and their levels (SM1099) | the wrapper | `session_log_line`, for both
Login rate limit (SM1043), sign-in by address (SM1159), account gates | the wrapper's sign-in | unchanged: sign-in is the wrapper's, and its `?action=` requests are relayed to it
CSRF | the manager API and the verifier's token | unchanged (the API is still wrapped until S4)
`refuse_manager` (SM1140), `ui` (SM1135) | the processor's manager entry, from headers | the same, from the value
```

**Found on the base tree.** A wrapped request with no cookie (an ACL static), sent
with `LAZYSITE_AUTH_TRUSTED=1` as a FastCGI parameter and a forged `X-Remote-User`,
was served to the forged user. The wrapper found no cookie and wrote nothing, and the
processor it exec'd ran as plain CGI, where it believes the sentinel. S2 closed this in
the worker but not in the relayed child. S3 closes it for pages. The manager API still
has this shape through its relay until S4, whose child deletes the sentinel before it
writes the contract. As T3 says, only the web server's configuration can send the
parameter.

Proved by t/integration/293, using one pool worker with the front door on. The
cgi-bin's wrapper is a shim that records each run, so "in the worker" is read from
what ran.

- T1: alice, an anonymous visitor, bob and alice again each see only themselves, and
  the wrapper never runs.
- An ACL static is decided from the value.
- T2: forged `X-Remote-User`, `X-Lazysite-*`, the sentinel and the sid sent as
  parameters. With no cookie the request is anonymous, on a page miss and on an ACL
  static. With bob's cookie it is bob, the forged header is stripped and logged, a
  forged payment header does not open a paid page, and a forged groups header grants
  nothing.
- T5: a disabled, a removed and a revoked account, and a revocations store that
  cannot be read, each stop at the next pooled request. A group-gated page is refused
  to a non-member and served once he is added. The manager entry refuses an account
  without `ui`.
- T7: a request that dies after the value is held is answered 500, and the next
  request is anonymous.
- T11: no line at the default level, a WARN for a forged signature, the DEBUG lines
  under `log_level: DEBUG`, and no cookie value in the log.
- The wrapper's own `?action=logout` and the manager API still reach the wrapper, and
  the API gets its contract.
- R5: three signed-in probes block an address and its next signed-in page is refused.
  Anonymous probes count too. Two probes handed to the wrapper are counted once each.
- SM1160: an `odoo:` session sees its mapped group's page and grants nothing once its
  record is older than `odoo_identity_ttl`.

Against the S2 tree, 293 fails on the forged-parameter ACL static above and on every
"in the worker", R4, T11 and anonymous-probe assertion. t/integration/294 shows R4 where the sentinel is believed (one process on
the CGI path, 288's harness): with a value held, the sentinel and a forged
`X-Remote-User` and `X-Payment-Verified` give the value's identity, a 402 and both log
lines; with no value held the same request is the wrapper's contract. t/unit/auth/70
pins `session_log_line` to the wrapper's lines from before the move. t/lint/38 asks
its question of the wrapper's one-line write. t/lint/268 holds the front door to
`request_session` and the gate to not believing the sentinel while a value is held.

The bench, `tools/bench-surfaces.sh --n 10 --surface page,page-signed-in --with-pool`
(one CPU, nice 19), with S2 and S3 run alternately, two rounds each, on the shared
host at a load average of 9 to 11. `page-signed-in` through the pool took a median of
201 and 276 ms on S2 and 42 and 27 ms on S3. Its `identity` phase went from 7.9-9.7 ms
to 0.7 ms, and the `load` phase (the two programs' start-up, 131-175 ms) is gone. What
remains is the render, 24-35 ms, as on CGI. The anonymous `page` through the pool was
1.3-2.4 ms on S2 and 3.9-12.0 ms on S3; the two S3 rounds differ threefold, so at
this load the bench cannot separate the two. Measured directly (2,000 calls, one CPU,
nice 19, the same load), what R5 adds to it - reading a 41-line lazysite.conf and
running the guard for a path that is not a probe - is 0.13 ms a request.

## S4: the manager API is one program (n685)

Under `FRONT_DOOR` (the one-rule pool), a request for
`/cgi-bin/lazysite-manager-api.pl` was relayed through the auth wrapper: fork, exec
`lazysite-auth.pl`, which verified the cookie, wrote the identity headers and exec'd
the API. The front door now decides the request as S3 does for a page:
`_front_session` calls `request_session` once, logs the wrapper's line and holds the
value. It then relays to the API directly. In the forked child, never in the worker,
`Lazysite::Auth::Identity::clear_identity_env` deletes what the FastCGI parameters
carried (the sentinel, `LAZYSITE_AUTH_SID`, `LAZYSITE_AUTH_NO_PASSWORD` and the six
trust headers). `write_identity_env`, the writer the wrapper calls (S1), then writes
the contract from the value, and the child execs the API. The worker's time so far is
handed across the exec as the wrapper handed its own (`Lazysite::Timing::handover`,
SM1144). One program instead of two.

- **What the API checks stays in the API**: its trust gate, CSRF, the `ui` channel
  gate, the capability gates, `refuse_manager` and the token path. They run as they
  did behind the wrapper, on the same contract.
- **A trusted proxy's value** (SM1130) keeps the proxy's headers. The wrapper passed
  them on as sent and the API reads them under `proxy_identity`, so the child clears
  only the three flags for it (T4). The filing's design names the six headers
  without that case, and this follows T4 ("t/integration/263 ... unchanged").
- **Still the wrapper's**: a request on the API's address that names one of the
  wrapper's own `?action=` requests (`_front_wrapper_action`, as in S3), and
  `/cgi-bin/lazysite-processor.pl`.
- **R5**: the wrapper no longer guards the API's requests, so the front door's
  `_front_bad_url` now guards them.
- Plain CGI and the split `vhost-fcgi` templates are unchanged (R8).

**The gap S3 found is closed.** On the S3 tree, a manager API request sent
`LAZYSITE_AUTH_TRUSTED=1` as a FastCGI parameter with `X-Remote-User: boss` and no
cookie was answered as `boss`. With a member's cookie, the forged
`LAZYSITE_AUTH_NO_PASSWORD` reached the API. Both now reach the API as nothing: the
anonymous refusal in the first case, and the member's own contract in the second.

Proved by t/integration/295, using one pool worker with the front door on. The
cgi-bin's wrapper is a shim that records each run it serves, and its
`lazysite-manager-api.pl` is a shim that records what it was handed and execs the
real API. So every answer is the real API's, and "one program" is read from what
ran.

- An operator's `whoami`: the wrapper does not run, the API runs once, and it is
  handed the sentinel, the user, the fresh groups and the session's sid.
- An account without `ui` is refused. Disabled, removed and revoked accounts are each
  refused at the next call.
- The forged sentinel, groups, sid, flag and payment header with no cookie get the
  API's anonymous refusal, and the API is handed nothing. With a `ui` member's cookie
  the call is the member's. With an account that has no `ui`, it is refused for
  `ui`. From an unlisted peer the same headers are nobody's.
- CSRF: a cookie POST without the token is a 403 naming CSRF. With the token it is
  served, and another account's token is refused.
- Sessions marks the cookie's sid as "this session". A sid sent as a parameter is
  not marked.
- The wrapper's `?action=logout` on the API's address still reaches the wrapper.
- T4: a listed proxy's `X-Remote-User` reaches the API as the proxy sent it, without
  the wrapper.

Against the S3 tree, 295 fails on every "without the wrapper" assertion, on the
forged-parameter cases and on the unlisted peer. With the child's clear removed, the
forged cases and T4 fail. With `write_identity_env` removed, the operator's call and
every signed-in case after it fail. When the proxy's headers are cleared too, T4
fails. t/unit/auth/68 pins `clear_identity_env`: for no value, an anonymous value or
a cookie value it leaves no identity variable or header. For a proxy value it clears
only the flags. Clearing and then writing gives exactly the value's contract.
t/lint/268 holds the relay child to clearing, then writing from the value, before it
execs. t/integration/293's relay assertion now expects the API to run without the
wrapper.

The suites the filing names (t/unit/manager/09, 10, 13, 16, 18, 24, 29, 39, 40, 43,
45, 48, 51, 138, 159, 220, 226-228) stand in for the wrapper on the CGI path and are
unchanged and green. Their pool-side behaviours (sign-in, `ui`, the account checks,
CSRF, Sessions, a forged identity) are what 295 repeats through the pool.

The bench, `tools/bench-surfaces.sh --with-pool --surface manager` (one CPU, nice 19),
with S3 and S4 run alternately, two rounds at `--n 10` and two at `--n 20`, on the
shared host at a load average of 3.6 to 15. Each run measures the CGI path (wrapped,
two programs) and the pool in the same minute. On S3 the pool's median was 0.98 to
1.07 times the CGI path's (447-1190 ms). On S4 it was 0.67 to 0.92 times (332-910
ms). The `load` and `other` phases account for the drop (at `--n 20`: 180-228 ms and
67-83 ms on S3, 126-159 ms and 39-47 ms on S4). The absolute figures varied twofold
between rounds with the host's load, so the ratio within a run is the figure to
quote.

**Found in passing, not S4's.** `request_session` asks `request_identity` whether a
trusted proxy names a user without `pool => 1`, so in a worker a
`LAZYSITE_AUTH_TRUSTED` FastCGI parameter makes it read the fixed names as a cookie
identity. A listed proxy's user is then passed over and the cookie decides. This
fails closed: an anonymous value, or the cookie's own account. Only the web server's
configuration can send the parameter (T3). Seen while writing 295's T4 case, which
sends no sentinel. Closed in S5.

## S5: the dev server runs the self-verifying surfaces direct (n688, R6)

On a site with accounts, `tools/lazysite-server.pl` ran every `/cgi-bin/lazysite-*.pl`
except the wrapper itself behind `lazysite-auth.pl`. That included the Odoo, data,
MCP and OAuth endpoints, which no shipped front end wraps. Each verifies its own
caller: the Odoo and data endpoints check the session cookie (SM411), MCP its bearer
(SM076), and OAuth its client and grant. None reads what the wrapper writes, because
the data endpoint clears and rewrites it and MCP strips it. So the lab's `?csrf=1`
through the dev server ran two programs where production runs one.

- **`self_verifying`** names the four scripts. `handle_request` runs them direct, as
  it already ran DAV and the form handler. The processor, the manager API and the
  wrapper's own requests are routed as before.
- **The guard.** The wrapper ran `Lazysite::BadUrl::guard` (SM128) for these
  requests before it exec'd them. The dev server now runs the same function itself
  (`dev_bad_url`), under the same condition: a site with accounts, where the wrapper
  ran at all. It takes the wrapper's inputs, which are the request's
  `lazysite.conf` lines and the visitor address under `trusted_proxies` (SM929). A
  blocked address gets a 403 before the endpoint runs. Each request is guarded once,
  by the wrapper or by the dev server, never by both.
- A `?action=` sent to one of the four (`logout`, say) is now the endpoint's, not
  the wrapper's, as on an installed site.

Proved by t/integration/296. The dev server runs from a copy of `tools/` in a
scratch tree whose `lazysite-*.pl` are shims: each records its own name and execs the
real script.

- Each of the four is reached with no wrapper run.
- Each still decides who its caller is. A forged `X-Remote-User` is nobody to the
  Odoo and data endpoints. A session cookie is the account, by the endpoint's own
  check, and a cookie with a bad signature is nobody. The Odoo endpoint refuses a
  sign-out without its visitor token (`kind: csrf`). MCP refuses a tool call
  without a bearer with 401, and an operator's cookie is not a bearer either. OAuth
  refuses an unknown code as `invalid_grant`.
- The page and the manager API still run behind the wrapper.
- Probes sent to these surfaces are each counted once in the shared store. The
  third blocks the address, and later requests from that address to the Odoo and
  OAuth endpoints are refused before the endpoint runs.

Against the S4 tree, 296 fails on every "the wrapper did not run" assertion and on
the guard's "before the endpoint runs". Every assertion about what a surface decides
passes there too, so the surfaces' answers are unchanged. With the guard call
removed, the guard subtest fails. t/integration/59 (all four), 272, 43, t/unit/odoo/63
and t/unit/tools/01-04, 80 and 83 are unchanged and green.

**The bench.** `tools/bench-surfaces.sh` cannot target the dev server: it runs each
CGI itself, and its `odoo` surface stands in for the dev server by running the
wrapper first. So `?csrf=1` was timed through the dev server: the S4 server against
this one, alternated, N=10 a round, server and client pinned together with
`taskset -c 0 nice -n 19`. In the first run (load average 6.5-8.1) the wall-clock
medians were 134 and 307 ms on S4 and 225 and 126 ms on S5, so at this load the
wall clock cannot separate the two. The second run also recorded the CPU used by the
dev server's children. Over three rounds each at a load average of 9.2-9.8, S4 used
157-170 ms of CPU per request and S5 99-106 ms, about 60 ms less: one program's
start-up. The anonymous wall-clock median was 178-244 ms on S4 and 115-145 ms on S5.

**S4's open point, closed.** In a pool worker `request_session` asked
`request_identity` without `pool => 1`, so a `LAZYSITE_AUTH_TRUSTED` FastCGI
parameter made the reader take the fixed names as a wrapper-vouched identity. A
listed proxy's user was then passed over and the cookie decided. That failed closed,
but it broke R3 (the pool never believes the sentinel from `%ENV`) and SM1130's
order. `request_session` now takes `pool => 1` and passes it to `request_identity`.
The front door's `_front_session`, which decides both a page rendered in the worker
(S3) and the manager API it relays (S4), always passes it, so in a worker the
sentinel is never consulted. Plain CGI (the wrapper, the data endpoint) passes
nothing and is unchanged.

Proved by t/integration/297, using one pool worker with the front door on and a site
that lists a proxy. The proxy names `ed`, the cookie is `boss`'s, and the sentinel
arrives as a FastCGI parameter. The page shows `ed`. The real manager API answers
`whoami` as `ed` and is handed the proxy's own header and no sentinel. Without the
parameter (the control) both were already `ed`. Against the S4 tree the page and the
API are both `boss`. Removing the flag from `request_session`, or from the front
door's call, fails the same four assertions. t/lint/268 now holds the front door's
call to `pool => 1` and `request_session` to passing it on.

# Related

[[SM1082]] (the plan; C2 is this), [[SM1169]] (C1), [[SM1144]] (T0), [[SM297]]
(identity as a value), [[SM294]], [[SM411]], [[SM1129]], [[SM1130]], [[SM1131]],
[[SM1137]], [[SM1140]], [[SM1159]], [[SM1160]], [[SM760]], [[SM973]].
