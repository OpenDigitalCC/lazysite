# lazysite - threat model

Structured security assessment for the Commercial regime (eight-dimension
review D6). Method: **STRIDE** over the attack surface, with control
verification framed against **OWASP ASVS L1** (a user-facing service; L2 items
noted where already met). This is the threat-model home; the mechanism-level
narrative it references lives in `docs/architecture/security.md`, and the
vulnerability-disclosure policy in the repo-root `SECURITY.md`.

## Assets and trust boundaries

Assets: account credentials (hashed passwords, `lzs_` tokens, TOTP seeds),
session cookies, site content, form submissions, the per-install HMAC secret,
the audit trail, the Odoo connection user's key and a person's Odoo session
(0.15.5), and, since the visitor log names the signed-in account (0.16.1,
SM1219), account names in the log.

Trust boundaries (each is where an attacker's input crosses into trusted code):

1. **The public web request** -> the processor / auth wrapper (anonymous
   internet).
2. **The `X-Remote-*` header contract** -> everything downstream trusts it;
   the edge must strip client-supplied copies (the two-signal trust gate).
3. **The WebDAV / control-API / MCP partner** -> a token holder with a bounded
   capability set and per-file ACLs.
4. **Authored content + layouts** -> Template Toolkit evaluates them server
   side.
5. **The manager operator** (cookie, a member of the operator group - the
   group carrying the `manager` flag, which setup-sysop makes) -> passes the
   manager's capability gates and per-file ACLs (SM991). `manage_users` is
   user and group management and nothing more: since SM979 a file's rule binds
   it, and since SM991 it passes no other capability gate and cannot change the
   operator's account or the operator group, or revoke the operator's sessions
   or access keys. `local` (the CLI) and an unsecured site pass too; a token
   never does.
6. **The served tree boundary** (SM286, 0.10.8) -> protected content is MOVED
   out of the document root into `<docroot>-lazysite-private`, so the boundary
   is now a filesystem one and not only a decision one. A front end that serves
   a file without asking the engine can no longer reach protected bytes. See
   `architecture/security.md` - "Content outside the served tree".
7. **The front door** (SM293, 0.10.8) -> `lazysite-front.pl` +
   `Lazysite::FrontDoor::route()` may be the single entry point that decides
   which surface handles a request. Where deployed, the routing table becomes
   one point of correctness for every request rather than a rule per URL class.
   See `architecture/security.md` - "The front door".
8. **The scheduled actor** (SM666, 0.13.0-0.13.1) -> a long-lived,
   privilege-dropped process acting on a clock with a capability-holding
   account and NO request. Two gates: the account must hold `run_jobs`, and
   each job faces the ordinary capability gate for the work it does. The job
   set is engine code; no configuration can add one. `daemon_job_user` is a
   delegation - a `manage_config` holder names which `run_jobs` account acts -
   bounded by that closed set.
9. **The pool worker's identity** (SM1181, 0.15.12) -> on the one-rule pool a
   signed-in request is no longer passed between two programs by headers; the
   front door calls `Lazysite::Auth::Session::request_session` and the worker
   holds the answer as a value for that request only. The worker never believes
   `LAZYSITE_AUTH_TRUSTED` from its environment, strips every identity and
   payment header when it holds a value, and clears the value at both ends of the
   request. See `architecture/security.md` - "Who a request is, decided once".
10. **The trusted proxy and the forwarded address** (SM1129-SM1131, 0.15.10;
    SM929, SM1189, SM1194, SM1196, 0.15.11) -> two lists, kept apart:
    `auth_proxy_trusted_from` (whose identity headers are believed, matched
    against the TCP peer) and `trusted_proxies` (whose `X-Forwarded-For` is
    believed about a visitor's address). A front end that passes the client's
    `X-Forwarded-For` through lets any visitor choose their address, so the rollout
    and `lazysite check` name that as a failure. Every address-keyed control and
    every address rule sits behind this boundary.
11. **The address rule** (SM1134, 0.15.10; SM1343, 0.16.5) -> named address profiles
    that pages, folders and groups allow or deny; it narrows what other rules grant
    and never widens it.
12. **The Odoo extension** (SM747, 0.15.5; SM1160, 0.15.10) -> an outbound
    connection to an ERP on the operator's URL, a connection user's key, a person's
    own Odoo session, an anonymous visitor's bounded write path, and (opt-in) the
    person's Odoo login as the site sign-in under an `odoo:<login>` identity.
13. **oomd, the resident OOM** (SM1164, 0.15.10) -> one long-lived process per
    site, opt-in (`odoo_daemon`), supervised by lazysited as the same user, reached
    by a Unix socket in a 0700 directory, holding the connection's key files by label.
14. **The warm-fork parent of the Odoo endpoint** (SM1226, 0.16.1) -> one long-lived
    process per site with a pool conf and the Odoo extension on, supervised by
    lazysited as the request-path user, listening on a 0600 socket in the site's 0700
    `lazysite/run/`. The one-rule pool hands it the endpoint's requests; it holds
    compiled code and nothing else, and forks a fresh child per request.

Not yet code, so not yet boundaries: SM1128's native OIDC relying party and directory
groups (phases 2-3). The visitor log's signed-in account (SM1219) and the maintenance
capability (SM1118), held out of the 0.16.0 stable, are in 0.16.1; see
`architecture/security.md` and the register.

## STRIDE assessment

```datatable
columns: Category | Top threat for lazysite | Control (and where) | Residual / ASVS
widths: 2.6cm | X | X | 3.4cm
bold: 1
tone: medium
text: 2 3
---
Spoofing | Forged `X-Remote-User` / `X-Remote-Groups` headers from the client, impersonating an operator | Two-signal trust gate + mandatory edge stripping (`apply_trust_gate`; security.md "Auth proxy trust model"); cookie is HMAC-signed | Since SM293 step 4 the gate is an ENFORCED APPLICATION CONTROL (`t/lint/38`), so edge stripping is defence in depth rather than the sole control - this was the single highest-consequence operator obligation and is no longer; verified by lazysite-check --check-dav and the vhost template shipping the RequestHeader unset lines
Tampering | Hostile `layout.tt` / page executing arbitrary Perl through Template Toolkit | TT runs with `EVAL_PERL=0`; layout authoring gated by manage_layouts + webdav; content vs layout capability split (SM082) | ASVS V5: a layouts-capable partner is inside the trust boundary by design - scoped by capability, not sandboxed
Repudiation | An action taken with no attributable record | Append-only audit trail (who/what/target/origin/outcome), incl. denied attempts; login/logout audited; shell user management audited too (origin `cli`, invoking OS identity), installs/upgrades as origin `install`; the writer is failure-loud (0664 umask-proof create, self-heal, WARN naming any lost entry) | Audit read gated by the `audit` capability; ASVS V7 logging met; time is server clock
Information disclosure | Protected content served by a front end that never consults the engine (SM248, SM268 H17, SM283 - three incidents, one cause); auth secrets or raw logs readable off the docroot; visitor PII in stats | **Protecting content MOVES it out of the document root** (SM286), so this is structural rather than configurational; the front door makes the routing decisions inside the engine (SM293); secrets under `lazysite/auth/` (Apache-denied, 0660); stats export is aggregated + IP-anonymised; raw-log download removed (0.5.29); error surface synthesised | Sections protected BEFORE 0.10.8 stay in the document root until re-applied - an operator action no upgrade performs. TOTP seeds are stored recoverable (documented at-rest note, security.md) - accepted at L1, an L2 gap to close with an at-rest key
Denial of service | A flood of CGI forks, or an unbounded upload / render, exhausting the host; vulnerability-scanner probe floods | Login rate limiting (per-IP window; an extension, on by default - switched off or unable to run it says NOT in force in the log and in lazysite check, SM798); upload size gate; PUT streamed in bounded chunks; checked writes fail closed on ENOSPC (review D5). SM128: the bad-URL auto-blocker (on by default) refuses an IP after it hits too many scanner-probe paths in a window, enforced in the auth wrapper | No global concurrency cap (relies on the web server / MPM); capacity test is a held pre-launch item; the auto-blocker covers auth-wrapped sites
Elevation of privilege | A token/WebDAV partner reaching manager-only actions or another account's files; a manager account driven remotely | Token clients are confined to the control-API subset + `%need` capability map; never operators; per-file ACLs bind them (SM074); manager bypass is cookie-only. SM127: an account with group-granted manager access (`ui`) is refused outright on the api/mcp transports, and a group may not combine `ui` with `api`/`mcp` - manager access is interactive-only, so a leaked/misissued token on a manager account cannot drive the site | ASVS V4 met; the capability model is groups-only + explicit (ADR 0003), removing implicit manager status
Spoofing | A request's identity decided in a long-lived pool worker: a client's own `X-Remote-User`, or `LAZYSITE_AUTH_TRUSTED` sent as a FastCGI parameter, read as a verified identity; one visitor's identity served to the next (SM1181) | `request_session` is the one function behind the wrapper and the pool; in the pool the sentinel is never believed and a held value makes `apply_trust_gate` strip every identity and payment header; the value is cleared at the start and the end of each request (t/lint/269); `auth/.secret` is read per call and never cached | The split FastCGI templates keep the CGI wrapper for signed-in requests by decision; the security review in the SM1181 filing lists fourteen threats with the test that holds each
Spoofing | A client naming its own address or account through a proxy: identity headers from an unlisted peer; `X-Forwarded-For` passed through by an old front end (SM1129-SM1131, SM1189, SM1194, SM1196) | Identity headers are believed only from `auth_proxy_trusted_from`, which fails closed; one reader honours the configured header names; the proxy's user wins over a cookie; the Hestia rollout compares and replaces an old template and reports a pass-through vhost as a failure; `lazysite check` warns while the trust set is not empty | The private-range default for `trusted_proxies` is believed behind a front end that passes the header through until the vhost is rebuilt; verified by the rollout and by a probe request
Elevation of privilege | Odoo sign-in granting site rights, or an anonymous visitor reaching an ERP through a page (SM747, SM1160) | The Odoo-minted site session grants only the mapped groups, held server-side, and a mapping to any group carrying a capability is refused at save and at load; a public or scheduled write needs `apply: immediate` and is bounded by the connection user's Odoo rights, the bound operation, hourly caps and a visitor-bound token; a session binding never falls back to the connection user; OOM's approval gate stays on | A site session lives at most `odoo_identity_ttl` past the last Odoo check; the connection user's rights are set in Odoo by whoever administers it
Elevation of privilege | A process that outlives a request taking calls without the request's gates (oomd, SM1164) | Opt-in and off by default; started only while every gate holds; the socket directory is 0700 and the config 0600 with credentials as labels; `required` refuses with `daemon-down` where `on` falls back in-process | oomd has no sign-in verb, so sign-in stays in-process
Tampering | A raw or `api:` page served as `text/html` past the ADR 0006 downgrade through a front-matter spelling the renderer read and the downgrade did not (SM1213) | One reading of `api:` and `raw:` in the renderer, the manager and the downgrade's peek; an empty key takes its own line only | Closed in 0.15.15; no gated page opened (t/integration/305)
Information disclosure | A page or a group's rights reaching an address the operator excluded (SM1134) | Named lists decided by one module; deny wins; an unreadable store, an unparseable address and a wrong-kind name each deny; every layer must admit; groups drop out for a refused address | Only as good as the request address: see the trusted-proxy row
Information disclosure | A page held back by a rule keyed by its stem (`/about` stored as `about`) published by a move or a delete that re-keys only the page's own key, its bytes synced back into the document root (SM1257, SM1242, SM1258) | `Acl::fold_page_stem` is the one function every mover and deleter calls (the manager, MCP `move_file` and `rename_page`, the control API, WebDAV MOVE and DELETE): the stem rule moves or goes with the page while no folder of that name exists, and the store sync puts the bytes where the rule says | Closed in 0.16.1; a stem key that is a folder's rule is left alone by design (t/unit/manager/160, t/unit/dav/34)
Information disclosure | A long-lived parent that every Odoo endpoint child is forked from holds a key, a secret or one visitor's request, and every later child inherits it (SM1226) | The parent requires code and runs none of it, reads no configuration or key and never reads a request; a fresh child per request, which exits; the child's environment is the parameters less every identity variable, and the endpoint verifies the cookie itself; `srand` in the child | t/integration/325 reads the parent's memory after signed-in requests and finds no secret, key, cookie signature, token or parameter; t/lint/272 classifies what it holds
Elevation of privilege | A theme archive's symbolic link copied into the served asset mirror, so a public URL under `/lazysite-assets/` named any file the web server can read - the session-signing secret `lazysite/auth/.secret` among them, from which a `manage_themes` holder could mint an operator's session (SM1303) | The theme upload checks every entry before extracting any and refuses a symbolic link, a file type the web server runs and an archive over the upload limit; `lazysite check` warns for every link under `lazysite-assets/` (SM1304) | Closed in 0.16.2; a link planted before then stays until removed, and the secret it may have served until rotated (t/integration/336, t/tools/290)
Information disclosure | A grant confined to a scope answered from the whole docroot by a listing or search that names no path, which the scope check skips; a search quoting lines of a file whose rule the caller does not pass (SM1308) | A confined grant's missing or empty path is its scope roots and every walk starts there (MCP `list_files`, `list_pages`, `search_files`, `delete_page`'s references, `rename_page`'s link rewrite; the manager API's `list` and `pages`); each search hit is asked `_acl_denied`, read_file's question | Closed in 0.16.3 (t/unit/mcp/65, t/unit/manager/415); `audit_site` is confined too and a page's title is listed only to a caller who may read it (SM1311, SM1312; t/unit/mcp/68, t/unit/mcp/69)
Elevation of privilege | A member of a protected area writing a rule on a subfolder that admits a non-member, which replaces the area's rule there by longest match (SM1309) | Writing or moving a rule that admits, to read or write, anyone its enclosing rule does not is refused unless the operator or the enclosing rule's owner does it (`Acl::widening_refusal`, `move_widening_refusal`), on every surface that writes or moves a rule | Closed in 0.16.3 (t/unit/mcp/66, t/unit/dav/36); a carve-out written before then is honoured until removed, and `lazysite check` names each for review (SM1313; t/tools/295)
Denial of service | An upgrade that moves the extensions directory and its key leaving a site's list, or one entry, under the old spelling, so each extension it names reads as off, and silently - the login rate limiter among them (SM1142) | `install.pl`'s one-time `extensions-rename` converts the list and its entries and moves the directory, and is recorded as done only when it ran without a warning; `login-rate-limit-on` runs after it; `lazysite check` names an old-spelling line by number and an old directory left beside the docroot, and says when the limiter is not in force (SM798) | 0.16.4 (t/tools/306, t/journey/06); a line written back by hand reads as off until it is corrected
Elevation of privilege | A theme's source re-mirrored into the served asset mirror on every write to it (SM1335), so a symbolic link or a file type the web server runs that reaches a theme's `assets/` by any means - a shell, a restore, a WebDAV or manager write - is published under `/lazysite-assets/` with no activation, as SM1303's archive link was | `_mirror_theme_assets`, the one writer of every copy, refuses to switch in a copy whose `assets/` holds a symbolic link or a server-run file type (`_mirror_unsafe_entry`, SM1303's two checks; links listed, never followed) and keeps the copy it had; a served copy itself is refused to every writer, the operator included (`served_artifact_refusal`, SM1339) | 0.16.5 (t/unit/manager/430, 432, t/unit/dav/38); the refusal is a log line and a `mirrored: 0` answer, so a source that holds such an entry stops reaching its copies until it is removed
Denial of service | The bad-URL blocker exempting loopback always (SM1321, ruling 83): on a site behind a front end that `trusted_proxies` does not cover, every visitor arrives as 127.0.0.1, so no probe is counted and the blocker is off for everyone | The blocker asks `request_address` under `trusted_proxies` (SM929), so behind a covered front end the exemption is the machine's own checks only; `lazysite check` warns when address rules exist and `trusted_proxies` trusts no front end (SM1141); `bad_url_exempt: none` removes loopback's exemption | 0.16.5 (t/unit/lib/98); the blocker was refusing every visitor on such a site before (T-03), so the change trades a self-inflicted refusal of everyone for no probe counting until `trusted_proxies` is set; the default trusts only the private ranges, not loopback, and a site with no address rules is not warned (UPGRADE.md, the 0.16.5 entry, says to name a front end on the same host)
```

## Five priority entries (from the review)

1. **Forged trust headers** - the top spoofing risk; mitigated only if the
   edge strips `X-Remote-*`. Ship-time obligation, config-verified.
2. **Hostile `layout.tt` = code execution surface** - `EVAL_PERL=0` plus the
   manage_layouts capability boundary; a layouts partner is trusted by design.
3. **Secrets under the docroot** (HMAC secret, TOTP seeds, password hashes) -
   directory denial + mode; TOTP-at-rest is the known L2 gap.
4. **Partner write-boundary bypass** - capability map + per-file ACLs keep a
   token client off manager actions and others' files.
5. **CGI-fork DoS** - rate limiting + size/stream bounds today; a global
   concurrency cap and a capacity test are held pre-launch items.

## ASVS status (L1 baseline)

Met: session management (HMAC cookie, SameSite, HttpOnly, expiry), password
storage (salted sha256-iter, legacy auto-rehash), access control (groups-only
capabilities + per-file ACLs), input validation (path traversal, SSRF, header
injection, open redirect, upload validation - all in security.md), CSRF (HMAC
token on manager writes), security headers, logging.

Open (tracked): TOTP-seed at-rest encryption (L2); a documented pen-test
against this model (held pre-launch, review D6); a dependency CVE check (held,
review D6). See `docs/review/2026-07-01-eight-dimension/` and
`docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`.

## Significant-change assessments

The pentest gate (declared with a dated deferral waiver in
`docs/adr/0007-pentest-deferral.md`) fires ahead of schedule on significant
change unless a recorded assessment finds the change contained. This register
is that record - one dated entry per fired trigger, auditable per the
framework's letter. Verdict "accepted" means: contained, compensating
controls sufficient, no ahead-of-schedule engagement required. Entries for
changes shipped before this register existed are marked retrospective.

### 2026-07-10 (retrospective) - SM070/071/072: WebDAV, theme/layout management, self-service credentials

what changed
: the `/dav` endpoint (Basic over TLS), staged theme/layout authoring with a
  delegated sub-user model and pairing-key -> token lifecycle, claim links,
  TOTP MFA, account expiry - new external interfaces and new authentication
  methods (shipped pre-0.5.x; assessed retrospectively).

threat delta
: Spoofing, Tampering, Elevation of privilege, Information disclosure.

controls
: groups-only capability model (ADR 0001/0003), per-file ACLs, token `%need`
  map, `EVAL_PERL=0` on layouts, rate limits, single-use hashed claims; all
  folded into the STRIDE table above. Batch-1 hardening (bdb4c86): the six
  `:utf8` readers of `user-settings.json` re-paired to `:raw` so the account
  gates (disabled/expired/MFA) cannot fail open on non-ASCII bytes.

residual risk
: a layouts-capable partner is trusted by design; TOTP seeds at rest (L2 gap).

verdict
: accepted.

### 2026-07-10 (retrospective) - SM128: bad-URL auto-blocker (shipped 0.5.41, default on)

what changed
: a new enforcement surface with persistent blocking state on the anonymous
  request path - scanner-probe detection per source IP, 403 at threshold.

threat delta
: Denial of service (mitigation added, plus a new self-DoS surface),
  Tampering (the counter store).

controls
: keyed on `REMOTE_ADDR` only (not client-suppliable headers), list/unblock
  gated on `manage_config`, auto-blocks audited.

residual risk
: store fails open (corrupt counter file disables the blocker - consistent
  with the availability posture); behind a front proxy that leaves
  `REMOTE_ADDR` as the proxy address, a threshold hit blocks all visitors -
  deployment note for non-Hestia fronts.

verdict
: accepted.

### 2026-07-10 (retrospective) - SM136: notify-xmpp (shipped 0.6.2)

what changed
: XMPP notice delivery via `Net::XMPP` - a new dependency with authentication
  logic (the framework-named trigger, verbatim), a new outbound interface, and
  a new stored credential class (the per-site XMPP account password in
  `lazysite/notify-xmpp.conf`).

threat delta
: Information disclosure (credential at rest, notice content in transit),
  Spoofing (the XMPP account).

controls
: credential file WebDAV-denied and web-denied; password never shown back;
  TLS on by default with peer verification (`XML::Stream` 1.24); delivery
  lazy-loaded, best-effort, time-boxed (`alarm 15`); CR/LF stripped from
  notices. Batch-1 fix (bdb4c86): password-carrying extension configs are now
  chmod 0660 on save, and `notify-xmpp.conf` + `forms/smtp.conf` joined the
  `lazysite-check` secrets probe (world-access FAIL, `--fix` repairs).

residual risk
: authenticated outbound egress to the configured XMPP host; `Net::XMPP` in
  the SBOM/CVE surface (declared in `sbom-deps.json`).

verdict
: accepted.

### 2026-07-10 (retrospective) - SM137: SMTP password + staged validation (shipped 0.6.3–0.6.4)

what changed
: a stored SMTP password (new credential class) in `lazysite/forms/smtp.conf`,
  and a manager-driven staged connection check (DNS/TCP/TLS/auth) against the
  saved settings.

threat delta
: Information disclosure (credential at rest), Spoofing/SSRF-shaped probe
  (operator-driven TCP connect to an arbitrary configured host:port).

controls
: `smtp.conf` inside the 02770-checked `forms/` directory, WebDAV-denied by
  name, never returned to the UI; `resolve_password` shared by delivery and
  validation; the Validate action is cookie-only manager-gated, never sends
  mail, is time-boxed, probes plain-first; pinned by
  `t/unit/forms/05-smtp-validate.t`.

residual risk
: the SSRF-shaped validate primitive - acceptable at manager trust, recorded
  here.

verdict
: accepted.

### 2026-07-10 (retrospective) - SM140: first-party access log (shipped 0.6.8–0.6.9)

what changed
: a new data classification processed - visitor behavioural records, written
  anonymised to `lazysite/logs/access-YYYYMMDD.jsonl` and read by the
  analytics/export layer.

threat delta
: Information disclosure (visitor privacy), Repudiation (the log doubles as
  the availability record - see `docs/RELIABILITY.md`).

controls
: anonymise-at-write (keyed HMAC, daily-salted, truncated to 16 hex; the IP
  itself never written); log-injection defence (control chars stripped,
  length-capped, JSON-escaped); 90-day prune; `first_party: off` switch;
  recording can never break serving. Batch-1 fix (bdb4c86): the HMAC now
  keys on a persistent random salt (`lazysite/logs/.access-salt`, 0660),
  closing the empty-`.secret` brute-force corner on never-authed sites.

residual risk
: the anonymised log is group-readable on multi-user hosts (0664 under
  02775) - acceptable given anonymisation.

verdict
: accepted.

### 2026-07-10 - SM142: persistent runtime, dual-mode FastCGI accept loop (shipped 0.7.1)

what changed
: the processor gains a persistent execution mode - a long-lived worker
  servicing the anonymous request path from a FastCGI accept loop, prefork
  via `FCGI::ProcManager` - introducing the cross-request state-bleed risk
  class that per-request CGI made structurally impossible, plus two new
  (lazily required) dependencies.

threat delta
: Information disclosure / Tampering (request state leaking into a later
  request in the same worker), Denial of service (a wedged or leaking
  worker now affects subsequent requests).

controls
: per-request state reset shared by both paths (`handle_one_request`:
  `reset_request_state` + the die-guard; `local %ENV` isolates request
  environment); state isolation across consecutive requests pinned over the
  real FCGI protocol (`t/lib/MiniFcgi.pm`); worker recycling
  (`LAZYSITE_FCGI_MAX_REQUESTS`, default 500); an unhandled render error
  answers a clean 500 and the loop continues; plain-CGI invocation stays
  byte-identical. The auth wrapper is deliberately NOT pooled: the
  trust-header enforcement point keeps its per-request exec design, and in
  the shipped vhost template only cookie-less visitor traffic reaches the
  pool socket - the pool is anonymous by design.

residual risk
: `FCGI`/`FCGI::ProcManager` join the SBOM/CVE surface (declared in
  `sbom-deps.json`); a missed reset in future request-scoped state is the
  standing risk class - mitigated by the shared reset helper and the
  state-isolation test pattern, not eliminated.

verdict
: accepted.

### 2026-07-10 - SM139: packaged distribution - debs, host CLI, root-run integrator (shipped 0.7.2)

what changed
: a new distribution surface: `lazysite-common` + `lazysite-hestia` debs,
  the `lazysite` host CLI, a root-owned host registry and pool-config area
  under `/etc/lazysite/`, the root-started pool launcher
  (`lazysite-pool.pl` via the `lazysite@` systemd template unit), and
  `lazysite-hestia-domain` - a root-run-by-design panel integrator.

threat delta
: Elevation of privilege (root-run integrator; root-started launcher on the
  request path), Tampering (registry entries and pool configs as root-owned
  inputs to privileged code).

controls
: the SM139 principle enforced in code, not convention - `provision` and
  single-site `upgrade` refuse to run as root; `upgrade --all` drops to each
  site's owner via `sudo -n -u` per site; the pool launcher refuses
  `USER=root`, drops privileges before exec and verifies the drop stuck (no
  root remains in the request path); the integrator's root pass is bounded
  to domain layout/ownership, with every site-tree write behind
  `sudo -n -u <panel-user>`. Domain names are validated to the hostname
  alphabet before becoming file names, path components or unit instances;
  `--force-security` is honoured only when the payload manifest declares
  `"security_critical": true`. Invariants pinned by `t/tools/29-cli-fleet.t`
  and `t/tools/30-hestia-pkg.t` (incl. the FallbackResource-to-auth contract
  and the socket convention in the shipped templates).

residual risk
: the integrator and launcher run as root by design (bounded, reviewed
  paths); `/etc/lazysite/` is a root-owned admin surface - a compromised
  root already owns the host; correct `sudo` availability is a host
  dependency (`sudo -n` fails loudly, never prompts).

verdict
: accepted.

### 2026-07-10 - SM141: session registry + revocation (unreleased, on main)

what changed
: an auth-path change: the session cookie payload gains a random session id
  (`user:ts:sid:groups`), login writes an advisory session registry
  (`lazysite/auth/sessions.jsonl`), cookie verification gains a revocation
  check (`lazysite/auth/revoked.json`: sids + per-user `not_before`), and
  three new manager API actions (`sessions-list` / `session-revoke` /
  `user-revoke`) drive the new Sessions page.

threat delta
: Information disclosure (session metadata at rest: user, IP, sanitised UA),
  Tampering (two new files consumed by the auth path), Denial of service
  (a corrupt revocation file on every cookie check), Elevation of privilege
  (the revocation actions themselves).

controls
: signed cookies remain the sole source of authentication truth - the
  registry is advisory listing metadata, never consulted to authenticate;
  revocation is enforced at the single enforcement point (cookie
  verification in the auth wrapper; the processor keeps trusting only the
  wrapper's `X-Remote-*` headers); both files live in the web-denied,
  WebDAV-denied `lazysite/auth/`; the registry is loss-tolerant (a write
  failure never blocks login), UA-sanitised and 24-hour self-pruning; an
  absent `revoked.json` costs one stat and a corrupt one fails open with a
  loud WARN (no lockout, consistent with the availability posture); the
  actions are `manage_users`-gated, cookie-only (not in the token `%need`
  set), and revokes are audited with sid-prefix/username targets;
  `lazysite-check` probes both files alongside the secrets. Tests:
  `t/unit/auth/12-session-registry.t`, `t/unit/manager/24-sessions.t`.

residual risk
: fail-open on a corrupt `revoked.json` trades containment for availability
  (loudly logged); legacy pre-sid cookies cannot be listed or revoked
  individually - only per-user `not_before` or secret rotation reaches them,
  until they age out at 24 h.

verdict
: accepted.

### 2026-07-10 - SM085 phase 1: content history - git execution on the write path (unreleased, on main)

what changed
: an opt-in per-file version history: enabling (`git_history: enabled` +
  `git-init`) puts the docroot under git with the repository at
  `lazysite/git/`, and every content write (manager, WebDAV, MCP, uploads,
  nav/config saves, backup restores) invokes the `git` host binary to
  auto-commit. New attack surface: subprocess execution with
  attacker-influenced arguments (paths, commit messages, usernames) on
  every write; historic content exposure through the new `git-history` /
  `git-show` / `git-restore` actions; and a repository whose future remote
  sync (the git-sync extension follow-up) must never carry a secret.

threat delta
: Elevation of privilege / Tampering (command construction on the write
  path), Information disclosure (a leaked repo would expose the whole
  content history; history reads bypass "the file was edited since"),
  Denial of service (git failures on the save path).

controls
: every git invocation is LIST-FORM exec (`open '-|'` on an argument list -
  no shell anywhere; messages/paths/authors can never be interpreted);
  shas are validated against `/\A[0-9a-f]{7,40}\z/` and paths
  traversal-checked (no `..`/absolute/option-shaped segments) before any
  git call; the author string is stripped to a safe alphabet. GIT_DIR
  lives inside the protected `lazysite/` tree - no `.git` under a served
  path (and the processor/DAV deny lists refuse `/.git` anyway, defence in
  depth). The `info/exclude` written at init keeps secrets and personal
  data out of the history (`lazysite/auth/`, `lazysite/forms/`,
  `notify-xmpp.conf`, logs, the CSRF secret) - asserted literally in
  t/unit/lib/15-git.t and probed by a `lazysite-check` FAIL when
  `lazysite/auth` is not excluded. History reads run behind the same path
  validation, deny lists and per-file ACL read gate as `read`; restore
  routes through `action_save` (locks, ACLs, audit, cache invalidation) -
  no divergent write path. Token gating: reads/restore `manage_content`,
  init `manage_config`; restore and init are audited. All git work is
  eval-guarded: a git failure WARNs and the save proceeds (availability
  posture).

residual risk
: the repo doubles content at rest under `lazysite/git/` (0770, probed);
  a manage_content token may read any non-ACL-restricted file's history,
  which mirrors its live read grant; remote-sync risk is deferred to the
  git-sync extension's own assessment.

verdict
: accepted.

### 2026-07-10 - SM085 phase 1 (sync half): git-sync - egress to an operator-configured remote (unreleased, on main)

what changed
: the `git-sync` extension (opt-in) pushes/pulls the content history to a
  remote the OPERATOR configures, with a stored credential. New surface:
  outbound network connections from the site host to an
  operator-controlled address (git-over-https/ssh egress); a long-lived
  access token at rest in `lazysite/git-sync.conf`; a pull path that
  rewrites the worktree from remote-supplied content outside the normal
  save path; and a request-supplied action parameter (the
  keep_mine/take_theirs choice) reaching a child process.

threat delta
: Information disclosure (the token; the history leaving the host;
  SSRF-shaped abuse of the remote address), Tampering (remote-supplied
  content applied to the worktree; argument injection through the URL or
  branch), Repudiation (sync outcomes must be attributable).

controls
: remote address shape-validated before any git call - `https://host/path`
  (no userinfo), `git@host:path` or `ssh://` only; `javascript:`, `file:`,
  other schemes, option-shaped strings and shell metacharacters refused;
  branch name regex-validated. The token is never on a command line (no
  `ps` exposure), never in the stored remote URL or git config, and not in
  the askpass helper either: it travels in the process environment
  (same-uid visibility only) and git reads it via a transient 0700
  `GIT_ASKPASS` helper under the never-served `lazysite/git/`, removed
  after every action; `GIT_TERMINAL_PROMPT=0` + ssh BatchMode fail closed.
  `git-sync.conf` is 0660 (password-field rule) and on the never-versioned
  exclude list (init + self-heal before every sync + a `lazysite-check`
  SECURITY FAIL), so the pushed history cannot carry it - and the phase-1
  exclude list already keeps every other secret out of what egresses. The
  choice parameter is validated against the descriptor's declared ids in
  the manager AND re-validated in the extension; all git execution stays
  list-form via `Lazysite::Git::run_git`. Pull applies only fast-forwards
  or explicit `-X ours/theirs` merges, each behind a prerestore safety
  snapshot; a failed merge is aborted (worktree unchanged). Push never
  forces. Outcomes are audited (`extension-action git-sync (push|pull
  choice)`) and logged; raw git stderr goes to the server log, never to
  the operator response.

residual risk
: egress destination is operator-chosen by design (an operator could sync
  the content tree to any reachable git host - equivalent to their
  existing download rights); the token is recoverable by anything running
  as the site uid while an action runs; content pulled from the remote is
  trusted as operator content (same standing as a WebDAV write; the
  processor's normal escaping applies at render).

verdict
: accepted.

### 2026-07-18 - SM165: domain-owned access-control model (0.7.26)

what changed
: access confinement moved from a per-user/per-group `dav_scope` to a
  domain-owned model - each domain names `allowed_groups` (who may manage it)
  and `locked_users` (accounts confined to it), resolved through
  `Lazysite::Auth::DomainAccess` and the shared `resolve_user_scopes` (domain
  access intersected with the sub-user ceiling up the `created_by` chain). A
  new authorisation surface enforced on the manager UI, control-API token, MCP
  and WebDAV.

threat delta
: Elevation of privilege, Information disclosure.

controls
: a `DENY_ALL_SCOPE` sentinel so a locked user with no allowed domain is
  denied everywhere (never silently unconfined); scope intersection up the
  created_by chain so a sub-user can never out-reach its creator; enforcement
  code unchanged (only the SOURCE of `dav_scopes` moved). Verified by
  reproduction and `t/unit/lib/20-domain-access.t` (deny-all, empty allow-list,
  lock-narrowing, disjoint-intersection -> deny-all).

residual risk
: operators define the domain->group mapping; a misconfiguration is an
  operator error, not an engine bypass.

verdict
: accepted.

### 2026-07-18 - SM175: content history follows renames (0.7.26)

what changed
: git-backed content history now records renames as first-class moves (a
  `Lazysite-Renamed-From` commit trailer) and walks an incarnation-bounded
  lineage, so history follows a move but a delete truly ends the thread (a
  later file at the same path cannot inherit the deleted one's timeline). Adds
  `commit_move` on the git write path.

threat delta
: Information disclosure (history leakage across a delete/recreate).

controls
: the lineage walk follows explicit trailers (not git's `--follow` heuristic,
  which was shown to leak across delete/recreate) with a cycle guard and clean
  limit handling; the git write path keeps the existing `EVAL_PERL=0` /
  checked-write posture; the `18-git-guarantee` HOOK_RE covers `commit_move`.

residual risk
: none beyond the existing content-history trust model (an operator with
  content access already sees all versions).

verdict
: accepted.

### 2026-07-18 - SM179: multilingual language sets + engine i18n (0.7.27-0.7.28)

what changed
: a new content-partner-controllable input surface - a page's front-matter
  `lang:`, per-host `lang`/`lang_group` conf/`domain-set` keys, per-language
  content roots, `json:` content-root resolution, layout `strings/<lang>.json`,
  an engine i18n layer (`lazysite/i18n/<lang>.json`), and the `lang-status`
  control-API action.

threat delta
: Tampering (stored XSS / header injection), Information disclosure, path
  traversal.

controls
: `Lazysite::I18n` fails closed to English on any miss and never affects an
  auth decision; the i18n/lang file paths are lang-code validated (no
  traversal); `json:`/content-root resolution stays confined under the docroot
  (SM151); the 404 fallback HTML-escapes the request URI; `lang`/`lang_group`
  are validated at `domain-set`/`domain-add` and CR/LF-guarded (F6.11);
  `lang-status` is a read-only report gated on `manage_content`. FIXED during
  this assessment (F6.10, serious): the front-matter `lang:` flowed unescaped
  into `<html lang>` and `Content-Language` - now sanitised at the render point
  to a bare tag (`s/[^A-Za-z-]//g`), with regression test
  `t/integration/26-lang-injection.t`.

residual risk
: none identified after the F6.10 fix; the cross-host page cache is host-keyed
  (no cross-host poisoning).

verdict
: accepted (contingent on the F6.10 fix, which shipped in this cut).

### 2026-07-18 - raw/api script-capable content_type refusal (0.8.0)

what changed
: mechanical enforcement of ADR 0006. A `raw:`/`api:` page is served
  verbatim, with no layout and no output escaping, but a content author could
  set `content_type: text/html` (or `application/xhtml+xml`, `image/svg+xml`)
  and thereby have arbitrary page content executed as script in every
  visitor's browser - a stored-XSS vector that a `manage_content`-only
  delegate (who cannot author layouts) could reach. ADR 0006 had stated this
  was "enforced editorially, not mechanically"; a live-authoring review showed
  editorial-only is insufficient once content authorship is delegated.

threat delta
: Tampering (stored XSS) via the content-authoring surface, under the
  content/layout capability split (SM082).

controls
: at serve time (`peek_content_type`, the single content-type choke point for
  both the process and cache-serve paths) a raw/api page declaring a
  script-capable type is downgraded to `text/plain; charset=utf-8` and the
  attempt is logged (WARN). Combined with the `X-Content-Type-Options:
  nosniff` header the response already carries, the browser cannot execute or
  MIME-sniff the body back to HTML. Safe data artifacts (JSON, CSV, XML,
  plain text, images, PDF) are unaffected. Regression test
  `t/integration/27-raw-content-type.t`; authoring docs (raw-mode, frontmatter,
  ai-briefing-authoring) rewritten to use data examples and to state the
  refusal. Genuine HTML/SVG belongs in a layout (which escapes content) or a
  static file served by the web server.

residual risk
: none identified; HTML still reaches visitors only via a layout (escaped) or
  a web-server-served static file, neither of which passes through raw/api.

verdict
: accepted; closes the last serious finding from the 0.8.0 eight-dimension
  audit's security dimension (D6).

### 2026-07-19 - adversarial security-testing breadth pass (0.8.0)

what changed
: a breadth pass over the manager / MCP / control-API / WebDAV authorization
  surface before certifying the stable line. Motivated by the trust-gate gap
  (a sibling CGI consumed an identity header the processor gated) - the concern
  being that per-action negative tests leave structural gaps no single test
  guards. Two hardening fixes and a set of guarantee + negative tests.

threat delta
: Elevation of privilege (an ungated action, a channel-divergent capability
  gate, a write-guard bypass, a dropped dav_scope, a confused-deputy delegate,
  a crafted-backup auth overwrite), Tampering (path traversal), Denial of
  service (a fail-closed rate limiter).

controls
: fixes - backup restore now excludes `./lazysite` on extraction (a crafted
  content tarball cannot overwrite the auth/config namespace to escalate);
  `session-revoke`/`user-revoke`/`key-revoke` are forced to POST so the
  method-keyed CSRF gate covers them by construction. Structural guarantee
  tests (fail the build on drift): `14-capability-gate-guarantee` (token
  default-deny; every action classified/gated; cookie<->token capability
  parity), `15-write-guard-parity` (every write channel routes through the path
  guard), `16-scope-enforcement-guarantee` (dav_scope enforced on every
  channel). Negative tests: `40-subuser-escalation` (delegate confused-deputy
  confinement), `42-path-traversal-sweep` (every path-taking action), and
  `04-login-rate-failopen` (the rate limiter fails open, not closed). The
  existing trust-gate (`13`) and forged-identity (`39`) tests remain.

residual risk
: deferred as a 0.8.1 fast-follow (not gating this cut): a cross-site token
  parity test (tokens verify per-docroot, so cross-site is already structurally
  blocked) and an SSRF review of the `domain-check`/preview fetch paths. No
  open finding.

verdict
: accepted; the manager/API authorization surface now has structural backstops
  against the whole class the trust-gate gap belonged to.

### 2026-07-19 - 0.8.1 fast-follow: SSRF guard, tenant-token isolation, SM127 fix

what changed
: the two 0.8.1 items deferred above, plus a control-API/MCP regression the
  0.8.0 upgrade surfaced.

threat delta
: Server-Side Request Forgery (domain-check outbound probes), tenant
  cross-talk (a token used against another site), and an availability/usability
  regression on the token path (introspection + agent accounts wrongly refused).

controls
: (1) SSRF - `domain_check` (manage_domains) opens outbound TLS + HTTPS
  connections to a caller-influenced host. It now refuses the probes unless
  EVERY resolved address is public (`_ip_is_public`: blocks loopback, RFC1918,
  169.254/16 incl. the cloud metadata endpoint, CGNAT 100.64/10, IPv6
  ULA/link-local, v4-mapped equivalents, unspecified/reserved). Keying on the
  RESOLVED IPs closes the DNS-rebinding path and IP-literal/`localhost` hosts
  alike (both pass `_valid_host`). `domain-preview` shells the processor
  server-side and makes no outbound request. Test
  `t/unit/manager/44-domain-check-ssrf.t` (network-free via the resolve/tls/
  fetch hooks) asserts no connection is attempted for any internal range and
  that a public host is still probed. (2) Tenant isolation - a token is a
  credential in one site's per-docroot auth store, so it cannot authenticate
  against another site's docroot; pinned end-to-end by
  `t/unit/manager/45-cross-site-token.t`. (3) SM127 fix - see the commit; the
  manager-UI-remote gate now blocks only accounts that can ACTUALLY use the
  interactive UI (`manager_ui && ui`) and never blocks introspection, restoring
  the documented capability-based token contract for agent accounts.

residual risk
: none identified. The SSRF guard blocks by default; a self-hosted install
  whose legitimate domains resolve to RFC1918 would see domain-check refuse the
  reachability probes - acceptable (that deployment does not use public DNS/TLS
  checks), and revisitable behind a config opt-out if a real deployment needs it.

verdict
: accepted.

### 2026-08-11 - SM279: the retired group `dav_scope` is refused and reported

what changed
: the SM165 migration above moved confinement to the domain-owned model in
  0.7.26 and did not withdraw the mechanism it replaced. `group-set GROUP
  dav_scope PATH`, the per-account redirect that pointed at it, and
  `partner-create --scope` all kept accepting a value that
  `resolve_user_scopes` had stopped reading. Every release from 0.7.26 to
  0.10.6 stored those values and enforced none of them. The writers now
  refuse (clearing a stale value is still allowed), the dead resolvers
  `group_scopes` / `group_home_domain` and their module-free processor copies
  are deleted, and `lazysite-check` reports any group still carrying the field
  as a FAIL.

threat delta
: Elevation of privilege - specifically, a confinement an operator believes
  is in force and which is not. No enforcement path changed; nothing that was
  confined becomes unconfined.

controls
: refusal at the writer rather than a deprecation notice, so the false
  affordance cannot be exercised at all; `partner-create --scope` refused
  BEFORE the account is created, so a partner is never half-provisioned by a
  flag that would do nothing; the check reports and `--fix` deliberately does
  NOT clear, because the stale value is the only remaining evidence that
  somebody relied on it and clearing it would destroy that evidence while
  leaving the account unconfined. Verified by
  `t/unit/users/26-group-scope-retired.t`, every assertion confirmed failing
  against the pre-fix tools.

residual risk
: any site that set a group `dav_scope` between 0.7.26 and this release has an
  account that is not confined as intended, and this release detects that
  rather than repairing it - repair is an operator decision about which domain
  the group should own. `t/unit/manager/30-dav-scope.t` lost its
  `group_scopes` block: it had been testing dead code since 0.7.26 and reading
  as coverage.

verdict
: accepted.

### 2026-08-13 - SM286/SM293: protected content leaves the document root, and the front door

what changed
: two changes to the same question - where restricted content lives, and what
  decides whether a request reaches the engine. Both shipped in 0.10.7-0.10.8
  and both fire a trigger in `docs/adr/0007-pentest-deferral.md`.

  **New processing of restricted data (SM286).** Protecting a path now MOVES
  its content out of the served tree into a private store beside the docroot,
  `dirname(docroot)/basename(docroot)-lazysite-private`. Previously the content
  stayed in the document root and was protected by an access decision the
  engine made on request; now the engine is the only thing that can reach the
  bytes at all. The store is named for the docroot so two sites under one
  parent can never share one, and `Lazysite::Private` holds an invariant that
  content is in exactly one tree - the failure direction is "not moved", never
  "in both".

  **New external interface (SM293 step 5).** `lazysite-front.pl` is a new CGI
  surface. A front end is pointed at it and it makes every routing decision the
  vhost templates used to make - which URLs reach which surface, what is
  wrapped by the auth wrapper, what is refused outright - via the pure function
  `Lazysite::FrontDoor::route()`. SM293 steps 2-4 also allow the engine tree to
  move outside the docroot, generate the registries on request rather than from
  disk, and gate the trust headers in the application rather than relying on
  the front end to strip them.

threat delta
: Information disclosure, primarily, and in the reducing direction. The
  arrangement being removed is the one behind SM248, SM268 H17 and SM283: a
  front end serving a file the engine never sees, so no access rule the engine
  holds can apply. Moving the bytes out of the served tree makes that
  structurally impossible rather than configurationally avoidable. Elevation of
  privilege is unchanged - the ACL model, the capability model and the group
  resolution are untouched by both changes.

  The new surfaces this creates: a directory outside the docroot that the CGI
  identity must be able to create and write; and a single entry point whose
  routing table, if wrong, is wrong for every request rather than for one rule.

controls
: the store's location is derived, never configured, so it cannot be pointed
  somewhere unintended; `resolve_for_write` checks the public ancestor first so
  a store container cannot be mistaken for a gate; `lazysite check` reports
  whether the store exists and is writable, naming the directory, its owner and
  its mode, and speaks only on a site that actually protects something.
  `Lazysite::FrontDoor::route()` is a pure function with no I/O beyond
  existence tests, so the whole routing table is unit-tested directly
  (`t/unit/lib/21`) - which the vhost templates never could be - and driven
  through real Apache in `t/integration/49`. `t/lint/39` asserts the module and
  the shipped templates agree, so the migration cannot quietly change behaviour
  while claiming to preserve it. `t/lint/38` makes the trust-header gate an
  enforced application control rather than a front-end configuration
  requirement.

residual risk
: **A defect in the move path was live in 0.10.8 and is the reason this entry
  is not simply "accepted" (see the verdict).** `File::Path::make_path` croaks
  rather than returning false, so the guard following it was unreachable and a
  protect call died after storing the ACL and before moving the content or
  writing the audit line - leaving content stored-as-protected, still served,
  and absent from the trail. Filed as SM296, fixed on
  `claude/sm296-acl-set-crash`.

  Separately and by design: **every section protected BEFORE 0.10.8 stays in
  the document root** until its rule is re-applied, because the move happens on
  the act of protecting. Measured on an upgraded site, 19 of 25 extensions were
  still served byte-identically to an anonymous request. This is an operator
  action that no package upgrade delivers.

  The front door is CGI-only in 0.10.8; SM294 adds the pooled path and SM297
  records the auth-spine change that would remove the remaining fork.

verdict
: **accepted with a condition.** The architectural direction reduces the threat
  it addresses and is assessed as contained. The condition is SM296: until that
  fix ships and the affected sections are re-applied, a site that protected
  content on 0.10.8 may be in the state this change exists to prevent. Assessed
  as NOT requiring an ahead-of-schedule third-party engagement, because the
  defect is a local coding error with a known cause and a written fix rather
  than a weakness in the model - but the condition is recorded here so that
  judgement is auditable rather than implied.

### 2026-08-26 - SM570/SM578/SM577/SM593/SM589/SM592/SM618 (0.11.0): confinement stops being a property of how a partner was scoped, and two capabilities admit what they hand over

what changed
: The release assesses **twenty-five versions**, 0.10.10 to 0.11.0, because the
  register's previous entry stopped at 0.10.9 - that gap is itself recorded
  here rather than closed silently. Four changes move the security posture.
  **SM570**: the `acl-get`/`acl-set`/`acl-remove` trio was gated on
  `webdav || manage_content`, so a token holding neither - a zero-capability
  grant - reached them; it is `manage_content` alone now. **SM578/SM577**: the
  site-package verbs skipped their scope check entirely when a caller had no
  `dav_scope`, on the reading that no scope means unconfined. That is true of a
  cookie session and false of a token or MCP grant, so a partner holding
  `manage_domains` and no scope reached every domain's package on the instance
  - a package being a whole site. **SM593**: `manage_data` is an instance
  capability and a table's ACL path carried no domain component, so on a shared
  instance one client's grant read every other client's tables, and
  `Data::Access::may_read` returns true for a `manage_data` caller, so the ACL
  was bypassed rather than merely the listing. **SM589**: the capability floor
  returned `_script` and `config_file` - internal paths - to a caller holding
  nothing. **SM592**, found while writing coverage rather than by report: a
  cross-device collection MOVE out of an unwritable parent emptied the source
  and deleted the copy. **SM618** changes no behaviour and belongs here anyway:
  a capability-row campaign measured `audit` returning the WHOLE instance's
  trail - actor identities and raw source IPv4 addresses, including the
  operator's own manager, command-line and install sessions - under a partner
  token holding that one capability, and `manage_forms` returning live
  submission bodies (name, email, phone, message, submitter IP) under the grant
  an operator gives an agent to WIRE UP a form. Both titles described only the
  benign half. The operator's ruling is that both reaches STAND, `audit` on
  `purge`'s SM577 precedent; the titles now state them.

threat delta
: **Information disclosure moves most, and moves down.** Three separate routes
  by which one tenant of a shared instance reached another tenant's material -
  packages, data tables, and the ACL trio - are closed. **Elevation of
  privilege** is unchanged in mechanism but the capability model gained
  vocabulary: `manage_briefs`, `housekeeping` and `purge` as grants of their
  own, an exposure axis distinct from destructiveness, and groups that declare
  whether they are assignable. Each is a narrowing. **Loss of integrity**
  improves by one measured case (SM592). **Denial of service** is unchanged; no
  new long-lived execution path was added in this range. Against the movement
  down, SM618 records **no change in exposure and a change in what is known
  about it**: two capabilities disclose personal data to a partner token and
  always did. Nothing was closed, so nothing may be counted as closed - what
  changed is that an operator granting them can now read that fact before
  granting rather than after. A register that logged only the narrowings would
  make this release look better than it is.

controls
: Confinement is derived from the caller's own grant through one function per
  surface rather than per verb - SM578's field pass found two of four package
  verbs still carrying their own copy of the old test, which is why the four
  now ask one. The refusal for another domain's table is byte-identical to the
  refusal for a table that does not exist, so an instance cannot be enumerated
  by guessing names. `t/lint/87` requires the four surfaces to agree on every
  operation; `t/lint/86` refuses a channel used as an authority. For SM618 the
  DECLARATION is the control, because the reach is sanctioned: an instance-wide
  capability that says so is the model `purge` set, and `t/unit/manager/122`
  pins it for `audit` and `manage_forms` as `t/unit/manager/114` already did
  for `purge` - the three are coupled deliberately and change together.

residual risk
: **SM593's central guarantee is now field-verified, and this entry's previous
  text saying otherwise is superseded rather than deleted.** The operator issued
  a domain-scoped credential (`dav_scopes` = `sites/edge3`) on 2026-08-26 - the
  first non-`/` scope any measurement on this instance had held - and two
  throwaway tables identical but for their `domain:` field were read from it.
  The out-of-scope table was absent from the listing, and its refusal by name
  was word-for-word identical to the refusal for a table that does not exist,
  differing only in the echoed name. The property the controls paragraph claims
  from the source is therefore observed in behaviour: an instance cannot be
  enumerated by guessing table names. **A table
  naming no domain remains reachable by any `manage_data` holder** - deliberate,
  so an instance carrying live tables loses nothing on upgrade, and it means
  the protection is opt-in until an operator migrates. `lazysite-check` lists
  what is unmigrated. **The audit trail remains instance-wide and carries raw
  source IPs** - accepted, declared, and the largest single disclosure a
  one-capability partner token can obtain on this estate. It is recorded as
  residual rather than resolved because the declaration changed and the reach
  did not. **SM602** records that the full-system backup is written
  inside the docroot it backs up, so the declared RPO does not hold for
  docroot loss.

### 2026-08-14 - SM294/SM301 (0.10.9): a forked relay in the worker, and one more control-API action

what changed
: **SM294** lets the FastCGI pool worker be the site's front door. Requests it
  cannot answer as itself - another CGI surface, or anything needing the auth
  wrapper - are RELAYED to a forked child with the request body on a pipe.
  That is a new execution path inside a long-lived, privilege-dropped worker.
  **SM301** adds `regenerate-registries` to the control API; it clears
  generated registries and is the twin of an MCP tool that has existed since
  SM264.

threat delta
: Denial of service is the one that moves, and it moves in a direction worth
  naming: a worker blocked forever on a wedged child serves NOTHING else, so
  one hung request would take a site down. Elevation of privilege is unchanged
  - the child inherits the worker's already-dropped identity and the auth
  wrapper's contract is untouched, which is why SM297 (identity as a value) was
  deliberately NOT taken here. SM301 adds no new capability: the action is
  gated by `manage_content`, which the callers already hold on another channel.

controls
: a `RELAY_TIMEOUT` (120s, configurable) after which the child is TERMed then
  KILLed and the worker answers 504, so a wedged surface cannot take the site;
  `local $SIG{CHLD} = 'DEFAULT'` so FCGI::ProcManager's reaper cannot consume
  the exit status and leave `waitpid` blocking; `IO::Select` pumping both
  directions so a large body cannot deadlock against a large response; the
  relay target constrained to `lazysite-[a-z-]+\.pl` within a resolved cgi-bin,
  with an `-f` check, so no path outside it is reachable. Off entirely unless
  `FRONT_DOOR=1`. For SM301, the same implementation serves both channels so
  they cannot answer differently, and it is skip-listed from the audit
  alongside `cache-invalidate` - it removes generated artefacts and audits must
  not drown in operational noise.

residual risk
: the fork costs a process on relayed requests, which is the same cost those
  requests already pay under CGI - so a site with an ACL store pays it per
  static file (SM223 routes those through the wrapper). That is the measured
  argument for SM297 rather than a regression. The pooled front door is opt-in
  and unused by default, so the exposure of this path on the fleet is currently
  nil.

verdict
: accepted. No ahead-of-schedule third-party engagement required: the new path
  is a fork within an existing trust boundary, bounded by a timeout, and adds
  no new identity, capability or external interface.

### 2026-09-05 - SM666/SM755 (0.13.0-0.13.1): a scheduled actor without a request

what changed
: **SM666 phase 1** adds a per-site persistent runtime: a supervisor
  (`tools/lazysited.pl`, `lazysited@.service`) and under it a scheduler that
  runs engine maintenance on a clock - the statistics rollup and the expired
  session sweep in 0.13.1 - as a lazysite ACCOUNT, with no request behind it.
  It ships as an ADR 0009 extension, born disabled, where disabled means the
  process never starts. **SM755**, from the 0.13.1 eight-dimension review
  (`docs/review/0.13.1-daemon/`), corrected the supervisor's restart path
  before the service reached a host.

threat delta
: A new long-lived process, privilege-dropped like the pool, that acts
  WITHOUT a request - so the request-path controls (the two-signal trust gate,
  the `X-Remote-*` contract, per-request capability resolution) do not apply
  to it by construction and something else must. Elevation of privilege is the
  question that moves: a timer that can call anything is a second write plane
  wearing a clock. Denial of service moves too: a process restarted for ever
  is a fork every two seconds per misconfigured site, and two supervisors on
  one docroot would run the same jobs against the same files. No new external
  interface, no listener, no egress (phase 1 by decision), no new
  authentication method.

controls
: the identity gate fails closed in every direction - no account, a `system:`
  identity refused by name, an account lacking `run_jobs`, an account lacking
  the job's own capability (`analytics`, `manage_users`) - and a refusal does
  not consume the schedule slot. The job set is a closed table in engine code;
  `t/unit/daemon/02` writes a job into the daemon's config and asserts the set
  is unchanged. `needs` per job is read by `t/unit/daemon/05` from the manager
  API's own gate table, so a job cannot need less than the manager charges for
  the same work. Every subprocess is list-form; the actor travels in
  `LAZYSITE_ACTING_USER` as the API sends it. The privilege drop is the
  pool's, verbatim, with a check that both real and effective uid left 0, and
  root without `--user` is refused. SM755: exits counted with backoff and a
  ceiling (FAILED, once, with a state file), the enabled gate re-read every
  10 s so disabling the extension stops the runtime, one supervisor per docroot
  by advisory lock, an orphan adopted only with pid AND kernel start-time
  proof, a 30 s stop deadline then KILL, a torn run record logged. The unit
  carries the SEC-2026-07 sandbox set (`NoNewPrivileges`, `ProtectSystem=full`,
  `PrivateTmp`, `PrivateDevices`, `RestrictSUIDSGID`, `ProtectKernelTunables`,
  `ProtectControlGroups`). The sessions sweep REMOVES personal data (IP, UA on
  expired registry rows) on a clock; the run record carries counts, not
  contents.

residual risk
: the daemon has not yet run on a real host under the unit; the privilege
  drop is proved in its unprivileged branch and by the pool's precedent
  (`docs/review/0.13.1-daemon/dimension-5`, F5.8). `daemon_job_user` lets a
  `manage_config` holder point the scheduler at any existing `run_jobs`
  account, including a person's; the consequences are bounded by the closed
  job set, and the extension's config note says a purpose account is preferred
  and why. Memory at rest is ~10 MB PSS per instance, two processes; a
  300-site host pays ~3 GB.

verdict
: accepted. No ahead-of-schedule third-party engagement required: no new
  external interface, authentication method or dependency; the new actor acts
  through the existing capability model with a second gate in front of it.
  Trigger review at phase 2 (the local socket), which IS a new interface.

### 2026-10-06 - SM924/SM925/SM928/SM929/SM938 (0.15.2): submission content can leave the site, and three new actions reach it

Signed off by the release manager 2026-10-06, in their words: "notify - yes it
may via xmpp, as email does. it is likely more contained than email."

what changed
: **SM928**: a submission notice can carry the submitted fields - over XMPP and
  in the bell - when, and only when, the form says `notify: full`; on `on`, the
  default, the notice stays one line. **SM938 D4/D5**: two control-API/MCP
  actions and a manager page - `form-notify-save` / `set_form_notify` (writes a
  form's `notify:`, gated `manage_forms`) and `form-submission` /
  `read_form_submission` (reads one stored submission by store and row id, gated
  `read_submissions`), with `/manager/submission` showing it. **SM924**:
  deleting submissions over the API is a capability of its own,
  `delete_submissions`, off by default, with no MCP twin. **SM925 X2**: the XMPP
  endpoint is found from the domain's SRV record through `Net::DNS` - a new
  dependency, lazy-loaded only when the XMPP extension is enabled. **SM929**: the
  one reader that consulted `X-Forwarded-For` stops believing it.

threat delta
: Information disclosure is the question that moves: with `notify: full`,
  submitted personal data leaves the site to a third-party XMPP server and a
  phone, where before only the form's name did - new processing of restricted
  data, which is a named trigger. The new read action exposes nothing the
  submissions table did not, but it is an addressable URL carrying a store path
  and an id, so confinement has to hold for a crafted one. `delete_submissions`
  lets a token destroy personal data, which no token could before. `Net::DNS`
  is a dependency with no authentication logic and adds an outbound DNS query to
  the host's configured resolver. SM929 removes a spoofing path rather than
  adding one.

controls
: `notify: full` is per form and opt-in, set by a `manage_forms` holder; the
  shipped default is unchanged, so an upgrade emits nothing new. Fields in a
  notice are truncated, and the XMPP transport is TLS with peer verification by
  default (the SM136 entry). `form-submission` goes through the same
  `_submissions_path` confinement as the table - a store outside the configured
  submission directories is refused, which `t/unit/forms/34` asserts with a real
  file outside them - and the page renders values with `textContent` only.
  `delete_submissions` is held by no group after an upgrade, is named for what
  it permits (any submission on the site), and the manager's own delete is
  unchanged. Every new action is classified in the gate, audit and git
  guarantees (lints 14, 98; t/unit/lib/16, 18), and the MCP/API parity lint
  pins both twins.

residual risk
: a site that enables `notify: full` sends personal data to whoever operates
  its XMPP account - the same exposure an email handler has always had, over a
  transport that is encrypted by default. The form docs now say so (closed
  with this entry); nothing records the choice beyond the form's own conf. The SRV lookup trusts
  the resolver the host is configured with.

verdict
: accepted. The restricted-data trigger fired (SM928) and is contained: the data
  flow is the one email delivery of a submission has always been, by the release
  manager's ruling likely more contained than email, opt-in per form with an
  unchanged default and an encrypted transport. The new actions sit behind
  existing, narrower-than-admin capabilities with the table's confinement. No
  ahead-of-schedule third-party engagement required.

### 2026-10-20 - SM1042/SM1043 (0.15.5): a member changes their own password and sets up their own two-factor

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: **SM1043**: `/account`, a system page in the site's own layout (`account_page:
  disabled` withdraws it), and the `me-*` actions - a member reads and changes only
  their own account, ends their own sessions, and signs out everywhere. **SM1042**:
  a member enrols, confirms, disables and regenerates recovery codes for their own
  two-factor (`me-2fa-enrol`, `-confirm`, `-disable`, `me-recovery-codes`); manager
  enrolment is removed in the same release, so a manager can only reset a member's
  two-factor and never sees a secret or a recovery code. Ruled by the release manager
  2026-10-12 ("Self-enrol only"; "Accept, build phase 1").

threat delta
: A new interface that changes credentials, so Spoofing and Elevation of privilege
  are the questions: a stolen session that holds the password could swap the
  authenticator, and a manager door that enrols two-factor can read the secret.
  Repudiation moves too: a credential change needs an attributable record.

controls
: The actions are declared `self`, cookie-only and CSRF-gated; an access key or a
  token is refused. Each sensitive request re-authenticates with the current password
  and counts against the sign-in rate limiter, by address and by account (five in five
  minutes, "share the sign-in limit"); six guesses from six addresses close the
  account's bucket. `me-2fa-enrol` is refused while two-factor is on; disabling needs
  the password and a current code or one recovery code; a changed credential ends the
  account's other sessions (SM1040). A body naming another account changes nothing; another
  account's session id is indistinguishable from a made-up one. The audit trail records
  every change, wrong-password attempts included, and carries no password. The manager
  API refuses `mfa-enroll`, `-confirm`, `-recovery-regenerate`, `-verify` and
  `totp-code`, and the users tool refuses the enrolment verbs to any actor that is not
  the account. t/unit/account/01-05, sabotaged one control at a time.

residual risk
: The TOTP seed is still stored at rest (the L2 gap in the STRIDE table). The
  `me-sign-out-everywhere` action ends the current session too, as ruled.

verdict
: accepted, confirmed by the release manager on 2026-10-21. The new interface only reaches the caller's own account, behind
  re-authentication, the shared rate limit and an audit row; the manager lost a
  capability rather than gaining one. No ahead-of-schedule third-party engagement
  required.

### 2026-10-20 - SM1019/SM1020 (0.15.5): a notification rule over a form event

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: A `notify` handler type queues a rule over a form event, and the engine job
  `notify-outbox` sends each recipient once, by email and the per-member bell.
  Recipients may be addresses stored in a table, owners' accounts, fixed addresses or
  the submitter (ruled in SM1010, 2026-10-12). Authoring needs a new capability,
  `manage_notifications`.

threat delta
: Information disclosure: the event's visible fields reach recipients the submitter
  did not name, which is new processing of restricted data. Denial of service: a rule
  can mail many people.

controls
: `manage_notifications` is off by default, held by the manager groups only. The
  grammar is checked at save (every fixed address is exactly one address, SM1017; every
  table declared and every column present). The queue entry carries the event's
  visible fields, bounded, and never files. A quarantined submission queues nothing.
  Sending is once per recipient under a hashed ledger, capped per recipient
  (`per_recipient_hour`, default 3), leaves the actor out unless `notify_actor`, and
  writes one audit row per recipient; messages carry an unsubscribe link and a
  `List-Unsubscribe` header unless the rule turns it off. t/unit/notify/01-05.

residual risk
: The handler actions' door (`manage_forms`, `manage_data` or `manage_connectors`) is
  unchanged, so a group holding `manage_notifications` alone cannot reach the handler
  page; whether to widen it is an open question in the SM1019 filing.

verdict
: accepted, confirmed by the release manager on 2026-10-21. Recipients and their sources were ruled by the release manager;
  authoring is capability-gated and off by default; the data flow is the one a form
  mail handler has always had, with a per-recipient cap and an unsubscribe. No
  ahead-of-schedule third-party engagement required.

### 2026-10-20 - SM747 (0.15.5 onward): the Odoo extension

Assessment drafted by the developer agent; the release manager confirms.

what changed
: `extensions/odoo.pl` (born disabled) and the page endpoint `lazysite-odoo.pl`. A
  connection user (a site Odoo account, its key stored like a connector secret) runs
  named operations for pages, MCP and backend work; a public or scheduled binding may
  apply a write unattended when it declares `apply: immediate` (ruled Q1, 2026-10-12;
  an e-commerce basket becomes a quotation); a person may sign in to Odoo through a
  page and run `credential: session` bindings as themselves (slices B, C, D, 0.15.5);
  MCP uses the connection user or a per-grant account (slice E). Ruled X4: the
  extension's outbound HTTP is mode 2 inside SM579's policy.

threat delta
: Four of ADR 0007's triggers fire. A new external interface (an outbound connection
  to an ERP on the operator's URL, a page endpoint, MCP tools); a new authentication
  method (a person's own Odoo session, kept in a signed cookie); a new dependency with
  authentication logic (OOM, delivered as `libodoo-oom-perl` and vendored as a pinned
  snapshot for the tests, whose session transport takes the password); and new
  processing of restricted data (ERP records rendered into pages). Spoofing, Tampering,
  Elevation of privilege and Information disclosure are all in play: an anonymous
  write path into an ERP is the sharpest thing the extension adds.

controls
: The filing's engine controls on every public apply: the mode gate
  (`Lazysite::Egress::may_invoke`: who, the extension switch, OOM's presence and
  version, the connection); per-visitor and per-binding hourly caps taken before the call,
  where a count that cannot be taken refuses; a CSRF token bound to a 256-bit
  server-minted visitor key (`HttpOnly; SameSite=Strict`, signed); input checked against
  the operation's declared parameters, with `fixed:` and the visitor parameter
  unoverridable; a plan owned by the key or account that made it and confirmed only by
  it; an audit record naming a hash of the visitor key and the IP. Transport: `https://`
  to any host, `http://` to loopback only, no credentials in the URL; the key is a 0600
  file never returned or logged. The person's password is in one POST to OOM's session
  transport and in no URL, cookie, log or record; the cookies are signed under the
  extension's own secret, `lzs_odoo_session` is `HttpOnly; SameSite=Strict` and scoped to
  the endpoint, and the identity cookie authorises nothing. A session binding never
  falls back to the connection user. OOM's approval gate stays on. A page render never
  runs a write and never renders a visitor's binding. t/lint/240 keeps Odoo knowledge out
  of lazysite; every guard was broken on purpose and its test went red (t/unit/odoo/01-31).

residual risk
: The connection user's rights are set in Odoo by whoever administers Odoo; lazysite
  narrows nothing Odoo allows. No third-party test has covered the endpoint or its public
  write path. The binding and operation declarations are still read from OOM's registry
  in the request's process. Idle time-out for a person's Odoo session is not built.

verdict
: accepted, contingent on the first third-party engagement required by ADR 0007 before
  2026-12-31 taking the Odoo endpoint and its public write path in scope. The triggers
  fired and the engine controls are specific, tested and sabotaged. Accepted by the
  release manager on 2026-10-20 ("accept").

### 2026-10-20 - SM1160 (0.15.10): the person's Odoo login is the site sign-in

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: On a site that sets `odoo_site_signin: on` (default off), a successful Odoo sign-in
  (the password and, where Odoo asks, the authenticator code) is the site sign-in. The
  identity is `odoo:<login>`; no lazysite account is made. Ruled 2026-10-18; SM1157
  put Odoo's own two-factor code in the dialog.

threat delta
: A new authentication method. Spoofing and Elevation of privilege: a forged or stolen
  cookie, a forged header, a group mapping that grants manager rights, and a site
  session that outlives the Odoo session.

controls
: The session is the wrapper's own cookie and registry (`auth/sessions.jsonl`), so the
  one verifier chain every surface calls applies. The cookie's user field is
  `odoo=<login>` percent-encoded and its group field is empty and ignored (SEC-2026-07
  M5); the mapped groups are held in the server-side record, which is the authority: no
  record, or one for another user, is no session. A local account name cannot contain `=`
  or `:`, so `odoo:<login>` cannot be shadowed. `odoo_group_map` is asked of Odoo as the
  person (`core.has_groups`, no administrator right) and a target that carries any
  capability is refused at save and at load, by name. A record older than
  `odoo_identity_ttl` (default 900 s) grants nothing until `?csrf=1` asks Odoo once and
  renews it; sign-out ends both sessions and each ends the other. An unsecured site
  refuses the session. A forged `X-Remote-User: odoo:x` is stripped by the existing
  gates. Attempts share the site's limiter. t/unit/odoo/63, 64, sabotaged.

residual risk
: A site session keeps what it had for at most `odoo_identity_ttl` after Odoo changes
  (the operator-set bound the ruling asks for). A reader idle on one page past that is
  sent to the sign-in page by the next restricted link. The wrapper's own logout ends the
  site session and leaves the Odoo session cookie until the next `?csrf=1`. Idle time-out
  is not built, as ruled.

verdict
: accepted, confirmed by the release manager on 2026-10-21. The trigger fired and is contained: no capability can be reached
  through the door, the cookie carries no authority of its own, and the bound on a stale
  session is stated and operator-set. No ahead-of-schedule third-party engagement required
  beyond the one ADR 0007 already requires.

### 2026-10-20 - SM1164/SM1207 (0.15.10, 0.15.14): oomd, a resident OOM

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: With `odoo_daemon` set to `on` or `required` (default `off`), lazysited supervises one
  `oomd` per site and the Odoo extension sends its calls through it over a Unix socket,
  falling back to the in-process path on `on`. SM1207 verified that a pack's custom
  change applies through it. Sign-in, sign-out and the two-factor step stay in-process.

threat delta
: A new long-lived process and a new local interface (the 2026-09-05 entry marked a
  local socket as a new interface). Elevation of privilege: a process that acts without
  the request's gates; Information disclosure: a socket that carries the person's
  session id and a config that names key files.

controls
: Off by default; the supervisor lists oomd only while the Odoo extension is enabled, a
  connection loads, `odoo_daemon` is on and oomd is installed, re-read every 5 s, so with
  any gate closed no process exists. It runs as the user lazysited runs as (SM760). The
  config `lazysite/odoo/oomd.conf` is written 0600 through a temporary file under umask
  077, names credentials only as labels of key files and carries no key. The socket is
  `lazysite/run/oomd.sock` when that path is under 104 bytes, otherwise under
  `/tmp/oomd-<uid>/`, a directory the service creates 0700. The person's session id is in
  the request to the daemon and in no file (the test greps the whole site). The client
  is always `fallback => 0`; `required` refuses with `daemon-down`. A leftover oomd of the
  same socket is told to stop before a new one starts. t/unit/odoo/60-62, 79,
  t/unit/daemon/14.

residual risk
: Not yet exercised on a real host: the tests run the vendored `bin/oomd` against OOM's
  fake Odoo, not `/usr/bin/oomd`, a real Odoo's latency (D5) or the supervisor under
  `lazysited@<domain>` and systemd; the same-user arrangement is the supervisor's,
  unchanged.

verdict
: accepted, confirmed by the release manager on 2026-10-21. Opt-in, off by default, the same user and privilege drop as the
  scheduler, no key in any file it reads, and every gate closing stops it. Trigger review
  of the production unit when a host first runs it.

### 2026-10-20 - SM1129-SM1131, SM929, SM1189, SM1194, SM1196 (0.15.10-0.15.11): a proxy is believed only from its address

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: SM1129: `auth_proxy_trusted_from` (a CIDR list matched against the TCP peer,
  failing closed) gates the identity headers. SM1130: a proxy's user wins over a cookie.
  SM1131: one reader honours the configured header names everywhere. SM1189: an address
  rule of the wrong form or kind is named and denies. SM1194 and SM1196: the 0.15.10
  edge walk (F-6) found a pre-SM929 vhost passing the client's `X-Forwarded-For`
  through, so Hestia's template is refreshed on rollout and a pass-through vhost is a
  failure. `auth_proxy_trusted` was enabled on no site (release manager, 2026-10-17).
  SM1128's phases 2-3 (a native OIDC relying party, directory groups) have no code.

threat delta
: No trigger of ADR 0007's four fired: no new interface, method, dependency or data. The
  trust contract of an existing flag changed, which is a Spoofing question, and F-6 was a
  Spoofing finding: every address-keyed control (the sign-in rate limit, the bad-URL
  blocker, the form handler's limit, every address rule) took the visitor's word behind an
  old front end.

controls
: The identity headers are believed only from a listed peer and from any other are
  stripped as with the flag off; an empty or unparseable list believes nobody; the reader
  asks `proxy_identity` and a client can never make a configured name count; t/lint/267
  and 268 hold the arrangement. The rollout reports a pass-through vhost as a failure
  (exit 2) on every site not set to `trusted_proxies: none`, refreshes Hestia's copy of
  each template (keeping a `.bak-TIMESTAMP`), and names the domains to rebuild; `lazysite
  check` warns whenever the trust set is not empty. t/integration/263-265, t/tools/185,
  186, t/unit/lib/205.

residual risk
: A site behind an old front end is spoofable until its vhost is rebuilt from the
  refreshed template; the private-range default for `trusted_proxies` stays and only
  `none` trusts nothing. The `.deb` does not install the templates into Hestia's tree, so
  the copy after an upgrade is a documented step the domain tool checks.

verdict
: accepted, confirmed by the release manager on 2026-10-21. No trigger fired; recorded because identity and address trust
  changed. The F-6 exposure is closed by the rollout where the rollout is run. When SM1128
  phase 2 is built it fires the new-authentication-method trigger and, with its JWT
  verifier, the new-dependency one, and is assessed then.

### 2026-10-20 - SM1134 (SM1138-SM1141, 0.15.10): access limited by the visitor's address

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: Named allow and deny address lists in `lazysite/auth/address-lists.json`, applied to
  pages and folders (`addresses`, `addresses_deny` in front matter and `acls.json`), to
  groups (a group does not count from a refused address), and to sign-in (SM1159); a
  template test `visitor.in_list` that exposes membership only. Ruled in full 2026-10-17.

threat delta
: No trigger fired. Information disclosure and Elevation of privilege are the
  questions a new access rule raises: a rule that fails open, an inner rule that opens
  what an outer one limits, and a group's rights reaching an address the operator
  excluded.

controls
: One module answers (`Lazysite::Auth::AddressLists::decide`): deny wins; an unreadable
  store, an unparseable address and a wrong-kind name deny; a name the store does not
  hold in an allow slot admits nobody. Every layer that names a list must admit, so an
  inner rule cannot open an outer limit, and the address is asked before the who-may-read
  rule, so `auth: none` cannot lift it. Enforced in the processor, WebDAV, the manager
  API and MCP. A group dropped for an address loses its capabilities, page access and
  operator status and everything reached through it by nesting. The template test
  exposes no address, and a render that asked is never cached. A list a rule names cannot
  be deleted without `--force`. t/unit/auth/63-64, t/integration/266, 280, 281, 285.

residual risk
: A page limited only by its front matter binds where it is served; the manager's and
  WebDAV's file reads decide from `acls.json` alone, so the rule goes in `acls.json`
  (`acl-set`) to cover every door. The address is only as good as `trusted_proxies`
  (see the entry above). An IPv4-mapped address is an IPv6 address to the matcher. A
  layout changed from a shell, outside the engine, is seen only when something else
  stales the page.

verdict
: accepted, confirmed by the release manager on 2026-10-21. Nothing in it widens access; the failure direction of every
  fault is a refusal.

### 2026-10-20 - SM1181 (0.15.12): who a request is, decided once

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: On the one-rule pool a signed-in request is rendered in the pool worker with the
  identity as a value (`request_session`), where it used to cross two programs by
  identity headers; the manager API is one program; the dev server runs the four
  surfaces that verify their own caller direct. Ruled 2026-10-19 ("Yes, plan + review
  first"; "All as proposed"); the review ran before any code.

threat delta
: No trigger fired. Spoofing and Information disclosure are the questions: a long-lived
  worker that decides identity can hand one visitor's identity to the next, and a
  header or a FastCGI parameter must never be read as one.

controls
: The security review in the filing (T1-T14) names the threat, the protection and the
  test for each. In the pool the sentinel is never believed from the environment and a
  held value makes `apply_trust_gate` strip every identity and payment header; the value
  is cleared at both ends of a request and a die leaves nothing for the next
  (t/integration/290-297, two requests through one worker among them); `auth/.secret`
  is read per call and never cached; the front door runs the bad-URL guard on every
  request, closing T13; t/lint/38, 13, 267, 268 and 269 are extended, not relaxed.

residual risk
: The split FastCGI templates keep signed-in requests on the CGI wrapper by decision
  (R8), so they gain nothing and lose nothing. MCP, DAV, OAuth and the wrapper's own
  actions keep their own credentials and are not moved.

verdict
: accepted, confirmed by the release manager on 2026-10-21. No new interface, method, dependency or data; the review preceded
  the code and every threat has a test that was broken on purpose.

### 2026-10-20 - SM1213 (0.15.15): an empty front-matter key reads as empty

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21.

what changed
: The page front matter's scalar reader ran over the newline after an empty key, so
  `title:` took the next line and that key was lost. The same readers in the renderer,
  the manager's `page_form` and `raw_html_page_refusal` now read a value from its own
  line, and the ADR 0006 downgrade reads `api:` and `raw:` as the render does.

threat delta
: Tampering. No gated page opened: every reader that decides who gets a page reads the
  front matter line by line (t/integration/305, before and after). The reader did let a
  raw page be served as `text/html` past the downgrade in four spellings (`api:` above
  `true`, `api: "true"`, `raw: 'true'`, a quoted `"text/html"`), each measured before the
  fix. A Markdown page's `<script>` already reaches the browser through the layout; the
  bypass added a whole response with no layout around it.

controls
: One reading of the keys in the renderer, the manager and the downgrade's peek. The
  downgrade stays the mechanical enforcement of ADR 0006 recorded in the 2026-07-18
  entry above.

residual risk
: None identified beyond the 2026-07-18 entry's.

verdict
: accepted, confirmed by the release manager on 2026-10-21. No trigger fired; recorded because it closed a bypass of a boundary
  this register names.

### 2026-10-20 - SM1219, SM1118 (held for 0.16.1; not in the 0.16.0 stable): the visitor log's accounts and the maintenance capability

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-21 ("Confirm now"). Both are
shipped on held branches (n705, n706), written here ahead of their release so the entry
exists when they land. They are in 0.16.1 if they land, and not in the 0.16.0
stable.

what changed
: **SM1219** (ruled #339, 2026-10-20): the access record gains `u`, the account the engine
  verified, read with the `analytics` capability, a domain-confined caller seeing only its
  own domains' accounts, kept as long as the rest of the log, shown per account in the
  manager. **SM1118** (ruled #338, 2026-10-20): a switch sends page requests by 302 to a
  page that answers 503; the new capability `maintenance_access`, held by the operator
  group and assignable, gets through; MCP, the control API, WebDAV, the data endpoint and
  posted forms follow the same capability.

threat delta
: SM1219 fires new-processing-of-restricted-data: account names in a log are personal
  data. SM1118 fires none: it adds a capability and a way to refuse requests.

controls
: SM1219 reads the account from the one identity reader at the end of the request, only
  for source `cookie` (including the pool's held value) or `proxy`, never the raw
  `X-Remote-User`, so a forged header records nobody; the default analytics reply carries
  no account name; the capability text now says visits per signed-in account are shown to
  it. SM1118 sits in the processor's `main()`, so it holds on CGI, the split templates and
  the pool; a switch-on needs the capability on the account doing it (no self-lockout); a
  form posted during maintenance stores nothing. t/integration/310-312, 315-320.

residual risk
: SM1219: per-account figures are read from the raw log, so they reach back
  `retention_days`, and telling the people who sign in is the operator's duty (SM1010
  principle). SM1118: a file the web server serves by name never reaches the engine and is
  not redirected; the OAuth and Odoo endpoints are not gated; a site with no accounts is
  closed to everyone while the switch is on.

verdict
: accepted, confirmed by the release manager on 2026-10-21 ("Confirm now"). Both remain held for 0.16.1 and are not in the 0.16.0 code.

landed
: Both landed on main after the 0.16.0 stable and are in 0.16.1, as assessed above (walk
  of 2026-10-23, SM1269). Since the entry, SM1241 adopts every shipped bundle on an
  existing site, which is how `cap-maintenance` reaches one; see the 2026-10-23 entry for
  the bundle record (SM1262).

### 2026-10-21 - SM975, SM976, SM979-SM982, SM991-SM993, SM1057, SM1092 (0.15.3-0.15.7), SM1234 (0.15.16): gate-tightening fixes and a release with no code change

Decision of the release manager, 2026-10-21, at the 0.16.0 stable sign-off.

what changed
: The fixes in 0.15.3 to 0.15.7 that tightened existing gates (SM975, SM976,
  SM979-SM982, SM991-SM993, SM1057, SM1092, the set listed in
  `docs/compliance/OBLIGATIONS.md` under "Walked for 0.16.0"). 0.15.16 (SM1234)
  carries no code change.

threat delta
: None. Each narrowed a gate that already existed and added no interface, method,
  dependency or data.

controls
: The existing gates, narrowed; nothing new was added to control.

residual risk
: None identified beyond the entries above.

verdict
: accepted. No trigger fired for the 0.15.3-0.15.7 fixes, and none fires for 0.15.16,
  which has no code change. Decision of the release manager, 2026-10-21.

### 2026-10-23 - SM1226 (0.16.1): the Odoo endpoint runs warm-forked

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-23.

what changed
: On a site with a pool conf and the Odoo extension on (never on a plain-CGI site),
  lazysited supervises an `odoo-endpoint` service: a parent that has compiled
  `lazysite-odoo.pl` and the `Lazysite::` modules it names, listens on
  `lazysite/run/odoo-endpoint.sock` (0600, in the site's 0700 `lazysite/run/`) and forks
  a fresh child per request, which runs the endpoint as the CGI does and exits. The
  one-rule pool hands it the endpoint's requests, and the split FastCGI templates (nginx
  and Apache `vhost-fcgi`, Hestia's fcgi templates) send `/cgi-bin/lazysite-odoo.pl` to
  the pool. With no parent listening the pool runs the CGI.

threat delta
: A new long-lived process and a new local interface, the oomd entry's shape: the
  new-external-interface trigger fires in the sense the 2026-09-05 entry gave a local
  socket. Information disclosure and Spoofing are the questions: a parent that held a
  key or a visitor's request would hand it to every child, a forged identity could
  enter a child by its parameters, and a request could reach a child no gate saw.

controls
: The filing's W1-W7, each with its test. The parent requires code and runs none of it,
  reads no configuration or key and never reads a request (t/lint/272; t/integration/325
  reads its memory after signed-in requests and finds no session secret, connection key,
  cookie signature, token or visitor parameter). A fresh child per request, which exits;
  `srand` in the child. The child's environment is the parameters less the sentinel,
  sid, flag and every trust header, and the endpoint verifies the cookie itself, so a
  forged `X-Remote-User` is nobody (t/unit/daemon/15, t/integration/325). The program
  starts by exec, never as a fork of the supervisor, so it holds nothing the supervisor
  read; it exits when its code changes on disk or it is re-parented, and removes its
  socket. The web server reaches only the pool's socket, so the parent's socket stays the
  request-path user's (SM760). A request the parent has taken is never re-run.

residual risk
: Every gate of the endpoint is the CGI's own and runs in the child, unchanged; what is
  new is the process, which the tests hold to holding nothing. A site on a pre-SM1226
  split template keeps a parent nobody calls until its vhost is regenerated. Not yet run
  under `lazysited@<domain>` and systemd on a production host.

verdict
: accepted, confirmed by the release manager on 2026-10-23. The trigger fires on a local socket and is contained: the
  socket is the request-path user's alone, the parent holds compiled code and nothing a
  request or a configuration carries, and the endpoint's own gates run unchanged in each
  child. No ahead-of-schedule third-party engagement beyond the one ADR 0007 already
  requires, which takes the Odoo endpoint in scope (the SM747 entry).

### 2026-10-23 - SM1257, SM1242, SM1258 (0.16.1): a page's stem rule moves and goes with the page

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-23.

what changed
: A rule set on `/about` is stored as `about` and governs `about.md` (SM268 H14). Every
  mover re-keyed only the page's own key, so a moved page left its draft rule behind,
  was served to anyone at its new path, and the store sync put its bytes back in the
  document root, where a front end serves them too (SM1257). Deleting a page left the
  stem rule for the next page written there (SM1242, SM1258 for WebDAV DELETE). One
  shared function, `Lazysite::Auth::Acl::fold_page_stem`, now folds the stem rule into
  the page's key before the manager's move, MCP `move_file` and `rename_page`, the
  control API's move and WebDAV MOVE, and drops it on every delete, while no folder of
  that name exists. SM1242 also makes `set_permissions` report what the rules decide
  after the save (`draft_note` for a draft), rather than only the page's own record.

threat delta
: Information disclosure. A held-back page was published by an ordinary move, and its
  bytes crossed the served-tree boundary (boundary 6) back into the document root. No
  trigger of ADR 0007's four fired: no interface, method, dependency or data was added.

controls
: One function behind every mover and deleter, so the surfaces cannot answer
  differently; a stem key that is a folder's rule is left alone; folding takes the
  stem's value only for a mode the page's own key does not carry, so no rule is widened.
  t/unit/manager/160 and t/unit/dav/34 each fail with the change reverted: the page is
  published and its bytes land in the document root.

residual risk
: A page moved by a shell, outside the engine, is not seen. A page drafted through its
  stem and moved before 0.16.1 was published at its new path and stays published: no
  rule follows it, so neither the upgrade nor the SM1238 dry run names it, and the rule
  left at its old stem holds back only a page written there later.

verdict
: accepted, confirmed by the release manager on 2026-10-23. No trigger fired; recorded because it closed a bypass of a
  boundary this register names, as the SM1213 entry was. The remediation record ADR 0007
  asks for stays for the certified release (`docs/compliance/OBLIGATIONS.md`).

### 2026-10-23 - SM1223-SM1225, SM1244, SM1247, SM1248, SM1261 (0.16.1): the Odoo extension's options and OOM 0.42

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-23.

what changed
: SM1223: a page's `Idempotency-Key` (8 to 128 characters) is hashed with the binding and
  the caller into OOM's `idem`, so a repeat answers the first plan or result. SM1224: a
  rows key an operation declares with its own `max` (up to 1,048,576) is capped there; a
  JSON body over 64 KB names its binding and is held to that binding's budget (20 MB at
  most). SM1225: a binding with `answer: download` answers a GET with the document its
  report holds, `Cache-Control: private, no-store`, capped by `download_max_kb` (default
  10 MB) and refused over it. SM1244: `lazysite check` warns below OOM 0.38, which can
  resend a write whose answer timed out. SM1247: the vendored test snapshot moves from
  OOM 0.38 to 0.42; SM1248 adopts oomd's config `namespaces` and its `reload` verb, so a
  pack change no longer restarts oomd. SM1261: a confirm whose daemon run is gone answers
  `not-found`, naming no path.

threat delta
: No trigger fired. OOM is the SM747 entry's dependency at a newer version, reached
  through the same interfaces; the `reload` verb is a request on oomd's existing socket;
  a report is ERP data the extension already processes, answered as a file rather than as
  JSON. Denial of service (a larger declared value), Spoofing (a key that replays another
  caller's write) and Information disclosure (a cached or oversized document) are the
  questions.

controls
: The idempotency key is hashed with the binding and who sent it, so nobody collides
  with or replays another person. A declared `max` raises only that key's cap, and the
  body is held to its binding's budget. A download runs the binding's gate, callers, rate
  caps and both paths unchanged, carries a safe file name and `no-store`, and is refused
  over its cap, never cut short. Each change of OOM 0.39 to 0.42 was checked against
  lazysite (SM1247), and every Odoo test passes on the new snapshot unchanged (t/lint/207,
  261). The OOM version warning names the file the site loads.

residual risk
: An operator who raises `download_max_kb` or declares a large `max` raises what one
  call may cost. A host still on OOM 0.37 or earlier can make a write twice until it is
  upgraded; the check says so and does not refuse.

verdict
: accepted, confirmed by the release manager on 2026-10-23. No trigger fired; recorded because the extension's inputs, outputs
  and dependency version moved.

### 2026-10-23 - SM1233 (0.16.1): a Docker Compose package

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-23.

what changed
: `installers/docker/` ships in the tarball: one container running nginx, the one-rule
  FastCGI pool and lazysited, the engine in the image and the site in three volumes (the
  docroot, `lazysite/`, the private store), built locally from the unpacked release with
  `docker compose build`. No registry image and no Odoo. The first start runs `install.pl`
  into the empty volumes; the first account is `setup-sysop`.

threat delta
: A new product form, the SM139 entry's question in a container. No trigger fired: the
  container serves the engine's existing HTTP surface through the shipped one-rule
  template, adds no authentication method, and carries the debs' own dependencies.
  Elevation of privilege and Information disclosure are the questions: what the
  container runs as, what it publishes, and whether the private store stays outside the
  served tree.

controls
: The processes run as `www-data`; compose drops all capabilities and publishes the port
  on loopback by default. The vhost is made by `sed` from
  `installers/nginx/vhost-one-rule-pool.conf.example`, so the rule (with its trust-header
  blanking) is written in one place. The private store is its own volume, the docroot's
  sibling, where `install.pl` and the engine put it. Every install path is `install.pl`.
  t/tools/210 holds the compose file, the Dockerfile's `sed` on the real template and the
  entrypoint's decisions.

residual risk
: The container serves plain HTTP on 8080; TLS is the front end's, and so is HSTS (sent
  only over TLS). Built and run once by hand; the test runs without Docker. An operator
  who publishes the port beyond loopback without a TLS front end serves sign-in in clear.

verdict
: accepted, confirmed by the release manager on 2026-10-23. No trigger fired; recorded because it is a new way the product is
  distributed and run.

### 2026-10-23 - SM1240, SM1241, SM1262, SM1263, SM1266, SM1221, SM1235-SM1239, SM1249, SM1265, SM1256, SM1259, SM1260 (0.16.1): access, rollout and channel changes with no trigger

Assessment drafted by the developer agent; confirmed by the release manager on 2026-10-23.

what changed
: SM1240: the sign-in rate counter `auth/.login-rate.db` is created 0660 in the auth
  directory's group under any umask (two sites had it owned by the site user, so the
  www-data CGI could not open it and allowed every attempt). SM1241: every shipped bundle
  is adopted on an existing site, only when absent, only for the shipped roles present,
  never rewriting an edited group; SM1262 records the bundles a site has had in
  `auth/bundles-adopted.json`, so a deleted bundle stays deleted and an unreadable record
  adopts nothing. SM1263: MCP `remove_permissions`, the twin of `acl-remove`, under
  `manage_content` with the owner refusal and the `acl-remove` audit action. SM1266: a
  page may ask `<feature>: self` for any feature Permissions-Policy denies, as SM1174
  allowed the camera. SM1221: a signed-out manager API call answers 401. SM1235-SM1239,
  SM1249, SM1265: the Hestia rollout reports and repairs (the ACL dry run as the site's
  own user, `--rebuild-exposed`, a root `--fix` creating an empty private store in SM313's
  shape, 2770). SM1256, SM1259, SM1260: the certified channel is accepted where ADR 0010
  says it is.

threat delta
: None of ADR 0007's four triggers fired. SM1240 closed a sign-in limiter that had failed
  open (Denial of service, against guessing). SM1241 grants capabilities on upgrade, an
  Elevation of privilege question. SM1266 loosens a security header for one page, an
  Information disclosure question (a camera, microphone or location reaching the page's
  script). SM1263 is one more tool on an existing capability, as SM301 was one more
  action.

controls
: SM1240: the limiter still fails open when it cannot open the counter (SM798), and the
  auth log says so on each attempt and `lazysite check` reports it; a counter the process owns that lost group access gets it
  back. SM1241: only the shipped nesting, only to shipped roles a site already has, only
  on a site that has the bundle layer; SM1262's record is fail-closed. SM1263: the same
  function as the control API, so the same gate, refusal and audit. SM1266: the value
  `self` and nothing else, front matter only, honoured over https only, that page alone;
  `payment` and `browsing-topics` cannot be asked for; a page that asks for nothing sends
  the header it sent before; the validator reports an unknown or unreadable value. The
  rollout changes run in the root-run integrator SM139 bounded, and a site-tree write
  stays the site user's.

residual risk
: SM1266: an author who can save a page can give that page's scripts a device feature;
  the site-level allow list is later. SM1241: the shipped roles an existing site has
  gain the shipped bundles' capabilities on upgrade, as a new install's have them.

verdict
: accepted, confirmed by the release manager on 2026-10-23. No trigger fired; recorded because access, a sign-in control and a
  security header moved.

### 2026-10-23 - SM1303 (0.16.2): a theme archive's symbolic link reached the served asset mirror

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-05 (ruling 65). Ruling 41 as revised (2026-10-23): with the exposure able to disclose the session-signing secret, so that a `manage_themes` holder could forge an operator's session, this is a security release. Ruling 41b: the archive checks and the planted-link warning (SM1304) land alone on main and are cut as 0.16.2, marked `security_critical` (`tools/release.sh --security-critical`, SM1305) and pushed fleet-wide with `lazysite upgrade --all --force-security`, which reaches stable sites too (on a Hestia host, the updater's `--force-security`, SM1307). Ruling 44 (2026-10-23): no exploitation of SM1303 is known, so there is no CRA Article 14 notification and no advisory; the release notes carry it.

what changed
: The manager's Upload Theme (`theme-upload`, `Manager::Themes::action_theme_upload`)
  extracted a theme zip and copied it, with `cp -r`, under each layout and its `assets/`
  folder into `/lazysite-assets/LAYOUT/THEME/` in the document root. A zip member that
  is a symbolic link (what `zip --symlinks` writes) was extracted as a link and copied
  into the mirror as one, so a public URL under `/lazysite-assets/` named any file the
  link pointed at. Shown, not assumed: with the old code t/integration/336's archive left
  `lazysite-assets/default/linky/passwd` pointing at `/etc/passwd`. Every entry is now
  checked before any is extracted, and a symbolic link refuses the whole archive
  (`blocked`). The same function also applies the site's upload limit and refuses a file
  type the web server runs (`@DANGEROUS_EXT`), as WebDAV and MCP `upload_file` already
  did under a theme. `lazysite check` warns for every symbolic link under
  `lazysite-assets/`, naming it and its target, and never removes one (SM1304).

affected versions
: Every release, 0.1.0 (2026-04-21) to 0.16.1. The upload has copied with `cp -r`
  since the manager's first theme support (2026-04-18), extracting with `unzip` and,
  from the D017 remediation before 0.1.0 was tagged, Archive::Zip; both extract links.
  The fix is in 0.16.2.

who could do it
: A signed-in manager holding `manage_themes`, the capability the action has needed
  since SEC-2026-07 (0.7.19). Before 0.7.19 the cookie path was not capability-gated,
  so any signed-in manager account. Not reachable with a token (the action is
  cookie-only) or anonymously - though once a link was planted, anyone could fetch what
  it pointed at.

threat delta
: Information disclosure, and through it elevation of privilege. Whatever the web
  server's user can read, served to anyone at a public URL, where the front end follows
  symbolic links (Apache with `FollowSymLinks`, nginx by default). On a lazysite host
  that includes the engine tree beside or inside the docroot - `lazysite/auth/` is
  group-readable by the web user, so the auth secret `lazysite/auth/.secret`, the
  account and group stores - and the site's configuration, its form submissions and any
  file of the host the web user may read. A session cookie is an HMAC under that
  secret, so whoever read it could mint a session for any account, the operator's
  included. The holder of `manage_themes` is trusted with how every page looks, not
  with those files or that account, so this crossed the served-tree boundary
  (boundary 6) from inside. No trigger of ADR 0007's four fired: no interface, method,
  dependency or data was added by the fix.

controls
: The member check runs before extraction (`isSymbolicLink`, then `@DANGEROUS_EXT`),
  so nothing reaches the staging directory or the mirror. t/integration/336 drives the
  manager's own upload as a signed-in person and fails with the change reverted (the
  link is in the mirror). t/tools/290 holds the check to naming every link, with its
  target and the remedy, to removing none, and `lazysite repair` to counting such a
  site as needing a human.

residual risk
: A link already planted by an upload before 0.16.2 stays in the mirror until an
  operator removes it; the upgrade's own health check names it (SM1304, ruling 42), and
  ruling 43 takes no host-wide sweep before the release. A secret it may have served
  stays valid until rotated: the manager's Sessions page, "Log out all users"
  (`rotate-auth-secret`), writes a new one and ends every session and preview cookie.

verdict
: accepted, confirmed by the release manager on 2026-11-05. Recorded because it closed a
  bypass of a boundary this register names, as the SM1213 and SM1257 entries were. The
  remediation record ADR 0007 asks for stays for the certified release
  (`docs/compliance/OBLIGATIONS.md`).

### 2026-11-04 - SM1308, SM1309, SM1311-SM1313 (0.16.3): a confined agent reached outside its scope, and a member could widen an area's rule

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-05 (ruling 65). Ruling 94 (2026-11-05): no exploitation of SM1308 or SM1309 is known, so there is no CRA Article 14 notification and no advisory; the 0.16.3 release notes carry what was exposed and what to do. Both were reported on 2026-10-27 by a site building a protected, agent-first intranet (gaps G3 and G4), verified against the source in the inbox triage of 2026-11-04 (T-01, T-02), and ruled on the same day (rulings 47 and 46): both are fixed in 0.16.3, the edge batch, with this entry. No exploitation outside the reporter's own test site is known. 0.16.3 is cut as an edge release, not marked security-critical, so the fixes reach each site by its own update channel.

what changed
: SM1308 (T-01). MCP's scope pass checks each path argument a tool declares and skips
  one that is absent or empty, so a grant confined to a scope, refused `/` when it named
  it, was answered from the whole document root when it named nothing: `list_files`
  defaulted to `/`, `search_files` walked the docroot, `list_pages` (which takes no path)
  walked it too, as did `delete_page`'s reference list and `rename_page`'s link rewrite,
  which saved pages outside the scope. The manager API's `pages` took no path, and its
  `list` with an empty path listed the docroot. And `search_files` quoted lines of any file
  it walked, with no per-file rule asked, where `read_file` refuses a file whose read list
  or address rule the caller does not pass. Shown, not assumed: the reporter's agent found
  a line of a page outside its area and was listed 108 site pages, and with the fix
  reverted t/unit/mcp/65 and t/unit/manager/415 reproduce each. A confined grant's missing
  or empty path is now its scope roots, every one of those walks starts there, and the
  search asks each file read_file's question (`_acl_denied`) before it quotes it.
  Rulings 59 and 60 close the two walks left: `audit_site` audits a confined grant's scope
  and lists a link outside it as outside the scope, never as broken (SM1311), and
  `list_pages` asks a page's rule before it lists the title (SM1312).
: SM1309 (T-02). A mode's list is decided by the longest match, so a rule on a subfolder
  replaces the enclosing rule there rather than narrowing it, and anyone with write access
  to a path may write its first rule. A member of a protected area, or the member's agent,
  therefore opened a subfolder to a non-member with one `set_permissions` call, and the
  non-member read its pages (the reporter measured 403, then 200). Longest match stays, so
  an operator can still carve a wider audience out of a private site (SM287, SM223).
  Writing a rule that admits, to read or to write, anyone the enclosing rule does not is
  now refused unless the operator or the enclosing rule's owner writes it, naming the
  enclosing rule; a move that would carry such a rule inside the area is refused the same
  way, since a move carries the rules under it to the target (within ruling 46, ruling
  64). `lazysite check` names each stored rule of that kind for the operator to review,
  and changes nothing (SM1313, ruling 61).

affected versions
: SM1308: 0.7.19 (2026-07-16), when MCP and the control API began confining a partner to
  its scope (SEC-2026-07 M2, SM155), to 0.16.2. Before 0.7.19 nothing confined a partner,
  so there was no scope to reach outside. The search's missing per-file check is older:
  `search_files` shipped in 0.4.11 (2026-06-25) and has quoted files under a read rule
  since then. From 0.10.8 (SM286) such a file is moved out of the document root, so after
  that it is reached only where content stayed in the docroot: a section protected before
  0.10.8 and not re-applied, or a rule carrying only address lists (SM1134, 0.15.10),
  which moves nothing.
: SM1309: 0.10.5 (2026-08-09), when a folder rule began to govern its section by longest
  match (SM181, SM223; on the manager, MCP and WebDAV from SM268 H3 in the same release),
  to 0.16.2. The move route is from 0.10.19 on WebDAV (CF-2) and 0.10.32 on the manager
  (SM518), inside that range.
: Both are fixed in 0.16.3.

who could do it
: SM1308: an MCP grant holding `mcp` and `manage_content` and confined to a scope (a token
  or OAuth partner whose account's group a domain names in `allowed_groups`); on the manager
  API, a signed-in editor or a token so confined, through `pages` (`manage_content` or
  `manage_nav`) and, for a cookie session, `list` with an empty path. It could read the
  names, titles and text of pages outside its scope, other domains' among them, and, through
  `rename_page`'s link rewrite, change the links in them. The search's per-file half reached
  any `manage_content` grant, confined or not, for the files described above. Not
  anonymous, and not a write beyond the link rewrite.
: SM1309: an account that may write a path inside a protected area: a member of the
  area's write list (or, with no write list, anyone with `manage_content` there), through
  the manager, the control API, MCP `set_permissions`, `lazysite acl set` as that account,
  or a move over the manager, MCP or WebDAV. The audience it could add is any account or
  group, so the area's content reached people its owner had not admitted; with a write
  list, they could change it too. Not anonymous: an anonymous visitor matches no read list.

threat delta
: Information disclosure, and for SM1309 elevation of privilege inside the access model.
  SM1308 crossed the confinement boundary SEC-2026-07 drew between a domain's partner and
  the rest of the instance; SM1309 let a member decide an audience the area's owner
  decides, which the documented "a folder rule gates its section" read as closed. No trigger
  of ADR 0007's four fired: the fixes add no interface, method, dependency or data. The
  refusals are new answers on existing calls (`widens-enclosing-rule`; a confined
  listing's `scope_roots`).

controls
: SM1308: `_walk_roots` (the grant's scope roots, nested ones dropped) for every MCP walk;
  `Files::action_list_scope_roots`, the one answer to a confined listing that names no
  folder on both doors; `outside_all_scopes` asked again of every search candidate; and
  `Acl::_acl_denied` at each file's first matching line, before the match is counted.
  t/unit/mcp/65 and t/unit/manager/415 fail with the change reverted.
: SM1309: `Acl::widening_refusal` (the enclosing rule by the readers' own walk with the
  path's key taken out; only principals the path's present rule does not already admit;
  nesting and case as the readers read them), asked by `Files::action_acl_set`, which
  every rule writer calls, before it writes or answers a dry run; and
  `Acl::move_widening_refusal`, asked by `Files::action_move` and WebDAV MOVE before
  anything moves. t/unit/mcp/66 and t/unit/dav/36 fail with the change reverted.

residual risk
: SM1308: protected content is not searched at all (T-15, 0.16.4).
: SM1309: a carve-out a member wrote before 0.16.3 is honoured until an operator removes
  it. The check is on writing; `lazysite check` names each such rule as a WARN and changes
  nothing, and `lazysite repair` leaves it for a person (SM1313). A group's membership is
  read when the rule is written, so a group a carve-out names admits whoever joins it
  later, as it always has. A site package restore (`site_apply`) writes its rules as
  packaged; it is an operator's act and is not checked (ruling 62).

verdict
: accepted, confirmed by the release manager on 2026-11-05. Recorded because each
  closed a bypass of a boundary this register names (confinement; the access rule), as the
  SM1257 and SM1303 entries were. The 0.16.3 notes tell an operator to read the check's
  new warning and review each rule it names (ruling 61).

### 2026-11-05 - SM1270, SM1272, SM1273, SM1275-SM1280, SM1283-SM1286, SM1290, SM1291, SM1294, SM1295, SM1299, SM1310, SM1314, SM1315 (0.16.3): access, serving, Odoo and release-path changes with no trigger

Assessment drafted by the developer agent at the 0.16.3 compliance walk; confirmed by the release manager on 2026-11-05 (ruling 93). The rest of 0.16.3 is styling, wording and tests and moves no control: SM1274 (Dismiss all), SM1288 and SM1289 (stylesheets), SM1296 (get_permissions names the rule that governs a page; it reads and changes nothing), SM1297 (an empty `maintenance` means off, as absent did), SM1298 (one warning wording), SM1301, SM1302 (test harness) and SM1316 (the updater's command written with one stage).

what changed
: Access. SM1270: the control API `acl-remove` with no path or an empty one, which
  removed the site-wide rule, is refused on every channel and in
  `Files::action_acl_remove`; `path=/` removes it (ruling 17). SM1272, SM1273: `lazysite
  repair` runs the users tool's top-up (`group-reach`) for each manager group, so a
  capability a release added is granted there and then, where it was granted on the next
  use of the users tool (SM645); a declined one stays declined (ruling 25). SM1310: MCP
  `replace_text` saves with the modification time it read, so a page changed under it is
  refused as a conflict. SM1294: `permissions_policy_allow`, an optional ceiling on the
  browser features a page may ask for (ruling 29).
: Serving. SM1284: the `/docs` manual ships in the engine tree
  (`{LAZYSITE}/templates/docs/`) and serves at `/docs/` whenever the site has no page of
  its own there; access rules over `docs/` govern it by the path it serves at, and it
  stays out of the site's search, sitemap, feeds and `llms.txt` unless
  `engine_docs_public: true`. The upgrade removes each docroot copy whose checksum still
  matches the install state, with its cached renders, and keeps an edited one (rulings 27,
  32, 34, 35). SM1283: the render path's content-root confinement accepts a source the
  system-page fallback itself chose when its real path is under one of the engine's page
  trees; every other source is confined as before. SM1285: a new site has no starter pages
  unless `--starter` asks (ruling 33); SM1286: `lazysite starter --remove-unmodified`
  removes the unmodified ones, as the site user, never as root, audited, never an edited
  page or one the site needs (ruling 34). SM1295, SM1299: `/odoo-signin`, a system page
  for a site whose sign-in is the Odoo login (SM1160), present only while
  `odoo_site_signin` is on, reachable in maintenance as `/login` is, returning to `?next=`
  only when it is a path on the site (rulings 36-39).
: Themes over MCP. SM1291: MCP `install_theme` (`manage_themes`) installs a theme zip
  through `Manager::Themes::action_theme_upload`, the function the manager's Upload Theme
  calls, so the theme upload, cookie-only until now, is reachable with a token. SM1290: MCP
  `preview_page` takes `theme` (`manage_themes` or `manage_layouts`, with
  `manage_content`) and renders with an installed theme that is not active, writing
  nothing.
: Odoo. SM1275-SM1279: a run that ended unknown is read back and resumed, and a change no
  read can tell is settled by its maker or a holder of `settle_odoo_writes`, a capability
  the Odoo extension declares (every operator group holds it, an older site's by the SM645
  top-up); the manager, the control API and MCP list, settle and dismiss such runs, and an
  open one is kept until it is settled or dismissed (rulings 10a-10c). SM1280: a binding's
  `address_profile` gives its operation 1 or 0, whether the call came from inside a named
  address list, never the address (rulings 3, 58).
: Release path. SM1314: `release.sh build --security-critical` refuses without `--final`
  (or `--certified`). SM1315: the deploy hook (`tools/lazysite-deploy.sh`) reads the
  `release-manifest.json` inside the tarball it deploys and passes the Hestia updater
  `--force-security` when the manifest declares `security_critical` (ruling 45).

threat delta
: None of ADR 0007's four triggers fired: no new interface (`install_theme`, the
  `odoo-*` run actions and `/odoo-signin` are actions and a page on existing surfaces, as
  SM301 and SM1263 were), no new sign-in method (`/odoo-signin` is a page in front of
  SM1160's), no new dependency and no new restricted data (SM1280 passes one bit and
  never the address). The questions are these. SM1291: the code path SM1303 exposed
  becomes reachable by a token (Elevation of privilege, through what an upload can place
  in the served tree). SM1283, SM1284: content served from outside the document root, on a
  path an access rule governs, and the upgrade deleting files in the docroot (Information
  disclosure; Tampering). SM1299: a sign-in page that redirects (Spoofing, through an open
  redirect). SM1276: a new capability that decides whether an ERP write happened
  (Tampering, of the record of what Odoo was sent). SM1273: capabilities granted inside a
  repair (Elevation of privilege). SM1315: a field of the deployed release widening which
  sites the deploy reaches.

controls
: SM1291: the upload's checks are the function's, so the token path has every refusal the
  manager's has, 0.16.2's among them (no symbolic link, no file type the web server runs,
  the site's upload limit, no absolute or `..` entry), and nothing is activated; the audit
  row is `theme-upload`'s and `delete_theme` reaches only what the caller installed (SM262).
  t/unit/mcp/61. SM1283: the exception is for a source the fallback chose, resolved with
  `realpath` (t/integration/340). SM1284: the engine's page is named by the path it serves
  at, so a rule, address list, draft section or section theme over `docs/` holds it; the
  site's own page wins; the upgrade removes only a copy whose checksum matches what it
  installed, and `lazysite check` names an edited copy that shadows the engine's
  (t/tools/280, t/unit/processor/160). SM1286 runs as the site user and refuses root.
  SM1299: `Lazysite::Util::sanitise_next`, the one check behind `/login` and
  `/odoo-signin`, now also refuses a `//` anywhere in the path. SM1276: the capability is
  grantable only where the extension is installed; a dismissal sends nothing to Odoo; each
  decision is one call record and one audit line naming the run; a visitor never resumes a
  public binding's run. SM1273: the top-up is SM645's, on an operator's explicit
  `repair`, and grants nothing a group declined (SM685 stands). SM1315: the deploy hook
  already runs, as root, whatever release it finds in its dist directory; the key is read
  from that same tarball, a missing, false or unreadable manifest adds nothing, and the
  hook still deploys only a strictly higher version. SM1314 makes a security release a
  stable cut, so the standard deploy reaches every site and no push is left to a hand.

residual risk
: SM1291: a token holding `manage_themes` can now install a theme's CSS and fonts site-wide
  as the manager's upload could, which is what the capability grants. SM1284: a site that
  relied on deleting `docs/` to hide the manual now serves the engine's copy; access rules
  over `docs/` still govern it. SM1276: a holder of `settle_odoo_writes` can record a write
  as made that was not, or the reverse; OOM reads each change back first, and only a change
  no read can tell reaches a person. SM1315: whoever can place a tarball in the watcher's
  dist directory decides what is deployed, as before.

verdict
: accepted, confirmed by the release manager on 2026-11-05. No trigger fired;
  recorded because access, the served tree, the theme upload's reach, an Odoo control and
  the deploy path moved, as the 0.16.1 entry of 2026-10-23 recorded its own.

### 2026-11-06 - SM1142 (0.16.4): one name for extensions, on disk, in lazysite.conf and on the wire

Assessment drafted by the developer agent at the 0.16.4 compliance walk; confirmed by the release manager on 2026-11-06 (ruling 127). 0.16.4 is SM1142 alone (ruling 63), cut as an edge release, not marked security-critical. Ruling 95: the response keys move with the rest of the wire (`extensions` on extension-list and whoami, `capability_extension` on groups-read), a breaking change for an external reader, recorded in the CHANGELOG and UPGRADE.md.

what changed
: On disk. The engine's extensions ship in `extensions/` beside the docroot (deb:
  `/usr/share/lazysite/extensions`), and every lookup of an extension's script asks one
  resolver, `Lazysite::Extensions::locate` (t/lint/306 refuses another). A site's
  `lazysite.conf` lists the enabled ones as `- extensions/<file>.pl` under
  `extensions:`, the only spelling a reader accepts.
: The upgrade step. `install.pl`'s one-time `extensions-rename` moves each entry left in
  the old directory beside the docroot into `extensions/` (a copy of a shipped file the
  site edited is kept beside the release's, under a suffix naming the old directory),
  rewrites the conf's list and its
  entries so every extension that was on stays on, re-points a cgi-bin symbolic link into
  the old directory at the moved file, rewrites a start page stored as the old Extensions
  page, removes the emptied old directory, and lists what it did in the upgrade summary
  under `Extensions:`. It is recorded as done in the install state only when it ran
  without a warning, so a step that warned runs again on the next upgrade. On HestiaCP
  the root-run deploy (`lazysite-hestia-deploy.sh`) makes `extensions/` and gives it and
  the old directory to the site user before the install, and removes the old directory
  with `rmdir` after it.
: On the wire. The actions, the parameter and whoami's switch in the old spelling
  are refused with `not-found`, naming the `extension-*` spelling, before
  authentication. The responses name `extensions` (extension-list, whoami) and
  `capability_extension` (groups-read) (ruling 95). An audit row for the seven extension
  actions records `extension-*` where it recorded the old spelling, SM831's
  `spelling=deprecated` flag goes with the spelling, and the runner's refusal of a
  disabled extension logs as `extension-gate`. The manager pages are
  `/manager/extensions` and `/manager/extension-config`; the old addresses are not kept.
  MCP's tool names, arguments and responses are unchanged; its descriptions say
  extension.
: `lazysite check` names, by line, a list or an entry in the old spelling written
  back by hand, and an old directory left beside the docroot.

threat delta
: None of ADR 0007's four triggers fired: no new interface (actions, parameters and
  pages are renamed, none added), no new sign-in method, no new dependency and no new
  restricted data. The questions are these. The step moves files and re-points links in
  every site's tree, on HestiaCP after a root-run `chown` (Tampering; Elevation of
  privilege, through a link planted in the old directory or a link re-pointed out of the
  site). The conf rewrite decides which extensions run, the login rate limiter among them
  (Denial of service, against guessing, if the limiter read as off). The audit's action
  names change (Repudiation: a reader filtering the old names stops matching). The
  old-spelling refusal answers before authentication (Information disclosure).

controls
: The step refuses to run unless its two directories resolve to the old directory's
  name and `.../extensions`, skips an old directory that is itself a symbolic link, moves each
  entry with `rename` (a link is moved as a link, never followed), and never overwrites:
  an entry whose kept-copy name is taken too is left in place and named. It
  re-points only a
  cgi-bin link whose target is a file in the old directory, and only at a regular file of that name
  in `extensions/`. The conf and the start-page store are rewritten through
  `_replace_conf`, a temporary file renamed over the original with its mode and group,
  as the other conf conversions are. The root-run `chown -R` is the one the deploy
  already ran on the old directory with the docroot, `lib/` and `tools/` (it does not
  follow links); the removal is `rmdir`, which removes only an empty directory. The rate
  limiter's entry is converted with the rest, `login-rate-limit-on` runs after the step,
  and `lazysite check` says when the limiter is not in force (SM798) as well as naming
  an old-spelling line. The refusal says how an action is spelled and nothing about the
  site. t/tools/306 (the step), t/tools/307 (the Hestia deploy's order and its
  removal), t/unit/manager/168 (the refusals), t/journey/06 (a pre-rename site upgraded
  in place: the sign-in CGI's rate limiter, the data gate, the runtime's start gate, the
  notifier and the registry see what they saw before); t/lint/306, t/lint/307.

residual risk
: A reference the upgrade cannot see stays the operator's: a crontab or pipe naming the
  old directory's `stats.pl` or `form-smtp.pl` stops running (a form's mail pipe stops
  sending), a script on the old spelling is refused, a reader of the old response keys
  reads nothing, and an audit filter on the old action names matches no row written
  from 0.16.4. UPGRADE.md and the 0.16.4 notes list all four. An
  old-spelling entry line written back by hand under `extensions:` reads as off in the manager and as on in
  the notifier and the processor nav, which match an entry by its file name (older than
  the rename and not widened by it); `lazysite check` names the line. A step that warned
  leaves its files in the old directory, run by nothing, until the next upgrade.

verdict
: accepted, confirmed by the release manager on 2026-11-06. No trigger fired;
  recorded because the upgrade moves files and links in every site's tree (on HestiaCP
  after a root-run step), decides which extensions stay on, the login rate limiter among
  them, and changes what an external reader and the audit trail see (ruling 95).

### 2026-11-05 - SM1324 (0.16.5): a protected folder keeps a history, by choice

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 127). Ruling
50 (T-16) made history for a protected folder an opt-in. It creates a second copy of
protected content, so it is recorded here.

what changed
: A folder rule may carry `history: true`. The folder's versions are kept in a second git
  repository whose work tree is the private store, with its own object store, at
  `<store>/lazysite/git` (02770, as the store). The public repository never holds them,
  so a git-sync remote never receives them. Off by default: a site with no such rule never
  creates the repository.

who can do it
: whoever may set the folder's rule (`Files::action_acl_set`: the operator, or the rule's
  owner), on the manager, the control API, MCP and the CLI.

who can read it
: whoever may read the file. Every history reader resolves its target through
  `_git_target`, which applies the file's read rule; a restore goes through `action_save`
  and its write rule; the overview filters each path by the read rule (SM683 step one).

data and privacy
: a second copy of protected content, kept for as long as the repository is kept. A
  folder's flag covers the rules nested in it unless one says `history: false` (ruling
  100), so a nested folder an owner did not think about is copied too unless it says
  otherwise. Clearing the flag or removing the rule keeps what was recorded; only the
  operator deletes it, with `lazysite acl purge-history` (ruling 99), which rewrites the
  folder out of the history and prunes its objects, and is audited. It is in a site
  backup, as the store is, and a backup taken before a purge still holds it. The public repository still holds a
  file's versions from before its folder was protected (SM683's third step, open).

residual risk
: the repository's permissions are set when it is made and are not probed by
  `lazysite check`.

verdict
: accepted, confirmed by the release manager on 2026-11-06 (ruling 125): the
  new-processing-of-restricted-data trigger the walk records below is contained.

walked
: At the 0.16.5 compliance walk (2026-11-06), against the code on the stack's tip: the
  repository is made 02770 inside the private store (`Lazysite::ProtectedHistory`), the
  purge is the operator's and audited, and `lazysite check`'s mode probe covers the
  docroot's `lazysite/git`, not this one, as the residual risk says. ADR 0007's
  new-processing-of-restricted-data trigger fires: protected content gains a second
  store, kept for as long as the repository is, as SM286's move of where protected
  content lives fired it. The entry above is that trigger's assessment; the release
  manager confirms it with the verdict. No other trigger fires: the `history` key is a
  new value on the existing rule writers, and the readers are the existing history
  actions.

### 2026-11-05 - SM1325 (0.16.5): a site can audit the AI reads of its content

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 127). Ruling
50 (T-17) made an audit of successful AI reads a per-site opt-in. It adds personal data to
the trail, so it is recorded here.

what changed
: `audit_reads: on` in lazysite.conf records each successful MCP `read_file`, `read_page`,
  `view_version` and `preview_page`, and a token's control-API `git-show`, as one `ok` row
  (time, account, path, address, origin) in `logs/audit-reads.log`, beside the trail
  (ruling 97). Off by default; any value
  but on is off. A signed-in person's reads and WebDAV are not recorded.

who can switch it
: an account or token holding `manage_config` AND `audit_switch` (the Config page,
  `config-set`), the gate of the trail's own switch (ruling 96); and whoever edits
  lazysite.conf on the host. The switch itself is on the change trail.

data and privacy
: the trail gains which account read which file, and when, and from which address. That
  is about agents' accounts, and it names protected paths to whoever may read the audit
  (the Audit page's AI reads view, scoped as the trail is). It is kept and rotated as the
  trail is (the logrotate stanza covers `logs/*.log`: weekly, eight kept, where installed),
  and forwarded to syslog if `forward_audit` is on.

residual risk
: volume, bounded by rotation only. The reads have their own file and view, so they do
  not push a change off the change view.

verdict
: accepted, confirmed by the release manager on 2026-11-06 (ruling 125): the trigger
  the walk records below is contained. Added at the 0.16.5
  compliance walk: the entry as filed carried no verdict.

walked
: At the 0.16.5 compliance walk (2026-11-06), against the code on the stack's tip: the
  rows go to `logs/audit-reads.log` (`Lazysite::Audit`), and the Config page's switch
  needs `manage_config` and `audit_switch` together (`Manager::Config`). ADR 0007's
  new-processing-of-restricted-data trigger fires: which account read which protected
  path, when and from which address, is personal data added to a log, as SM1219's account
  names in the visitor log fired it (2026-10-20). The entry above is that trigger's
  assessment. No other trigger fires: the switch is a new key on the existing Config
  page and `config-set`, and the view is a filter on the existing Audit page. Telling the
  people whose agents' reads are recorded is the operator's, as SM1219's notice is
  (OBLIGATIONS.md, the operate-side row added at this walk).

### 2026-11-05 - SM1332-SM1334 (0.16.5): a domain grant adds, the primary can be granted, and a group can pin

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 127).

what changed
: Ruling 78. The primary site is a grantable row in the domain list (the bare
  `allowed_groups:` line in `lazysite.conf`). A grant there adds the scope `/` (the
  docroot, `DomainAccess::PRIMARY_SCOPE`) to its members; grants add, so an account keeps
  the other domains it is granted. An account granted nothing keeps the primary, as
  before. `caller_may_reach_domain` reads `/` as the primary only; the content checks read
  it as the whole docroot, as they read an unbound account's empty list.
: SM1333: the primary's row is written through `domain-set` with host `(default)`
  (control API, MCP `domain_set`, `lazysite-domains.pl`, the Domains page), access
  keys only; a secondary row no longer displays the primary's access as inherited.
: SM1334: a domain's `locked_groups` pins every member of the groups it names, as
  `locked_users` pins an account; a pin on the primary confines to the primary; a
  request's scopes are held inside the account's whole, so a group its address leaves
  out cannot lift a pin.

threat delta
: Elevation of privilege is the question: a scope that by path contains every domain's
  content root, read as such by the domain rule, would reach every domain. It does not:
  the domain rule sets it apart (t/unit/manager/425 holds beta.test out of reach of a
  caller granted alpha and the primary), and the sub-user ceiling lets it meet only
  itself. Reach widens only through an explicit grant on the primary's row, and only to
  what an unbound account already had there - the primary's content, which by path is the
  whole docroot as it always was for an unbound account, and the primary's
  instance-wide settings (SM976 R1, for a caller not confined to other domains). Nothing
  widens at upgrade: no primary row named a group before (t/unit/lib/210). No trigger of
  ADR 0007's four fires: no interface, method, dependency or data is added; the row is a
  new value for an existing key, written through the existing `domain-set`.
: SM1334 only narrows: a pin removes domains and never adds one, and it closes a
  widening the group pin would otherwise have opened (a request's group left out by its
  address taking the pin with it; t/unit/lib/211).

controls
: One resolver (`DomainAccess::effective_scopes`, with the processor's rooting copy held
  to it by t/unit/processor/175) and one domain rule (`caller_may_reach_domain`, asked by
  every host-addressed action, t/lint/218). Writing the primary's row needs what writing
  any domain's access does: `manage_domains` and `manage_users`, and a confined caller
  reaches the row only when it already reaches the primary.

residual risk
: An account granted the primary reaches the primary's content as an unbound account
  does, and by path that holds the other domains' folders (sites/...). This is today's
  unbound reach, carried over; whether the primary's content should exclude the other
  domains' roots was put to the release manager: ruling 126 (2026-11-06), it will, for
  granted and unbound accounts alike, in 0.16.6.

verdict
: accepted, confirmed by the release manager on 2026-11-06.

walked
: At the 0.16.5 compliance walk (2026-11-06): no trigger fires, as the entry finds. The
  question in the residual risk (whether the primary's content should exclude the other
  domains' roots) was carried to the 0.16.5 "what a person must confirm" list in
  OBLIGATIONS.md and ruled there (126).

### 2026-11-05 - SM1343-SM1345 (0.16.5): an address rule's allow or deny moves from the list to the use

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 127).

what changed
: The release manager's request of 24 October 2026 (rulings 56-58, 105-108). SM1134's
  named address lists each carried a kind (allow or deny) fixed at creation; they are now
  address profiles with no kind, in `lazysite/auth/address-profiles.json`. Whether a
  profile allows or denies is the slot the rule names it in (`addresses` /
  `addresses_deny`, the manager's and sign-in's `_deny` keys, a session binding's), so one
  profile may be allowed by one rule and denied by another. SM1189's "wrong kind" refusal
  (a rule naming a list in the other slot refused everyone) goes with the kind. The names
  are renamed outright (actions, MCP tool, CLI, store, page, the template test
  `visitor.in_profile` / `visitor.in_any_profile`); an old action, tool or command is
  refused naming the new one, and a `kind` sent is refused by name. The upgrade converts
  the store once (same names and entries; the old file kept as
  `address-lists.json.converted`) and rewrites the site's template calls, reporting each
  file. The Files card and the Groups page choose Allow or Deny per profile.

threat delta
: A control's semantics change: what a stored name means is now decided by where it is
  used, not by the record it names. Elevation of privilege is the question: a rule whose
  effect widens with no edit to the rule. Every rule a save could write already named its
  list in the slot its kind meant, so for those nothing changes. A rule in the other slot
  (a hand edit only) refused every visitor before and now applies in its slot - it can
  widen. And a store left unconverted, read as empty, would let every deny rule block
  nobody.

controls
: `Lazysite::Auth::AddressProfiles::decide` is still the one answer: deny wins, every layer
  must admit, a faulted store denies wherever a profile is named, a name the store does not
  hold admits nobody where it is allowed. A site with `address-lists.json` and no profile
  store is a fault (`unconverted`), not an empty store: every rule naming a profile
  refuses, and the writer will not start a profile store beside it. The conversion never
  overwrites a profile store, leaves an undecodable old store in place (still refusing),
  and is re-tried until it finishes. `lazysite check` names every rule whose slot differs
  from its old list's kind (read from the kept `.converted` file, ruling 106) and every
  template call left under the old names (which are now false). Writes stay the operator's
  and cookie-only; a profile a rule names is not deleted without a second confirmation.
  t/unit/auth/63, t/integration/144, 145, 266, t/unit/tools/85, t/tools/315, t/lint/320.

residual risk
: A hand-edited wrong-slot rule widens at the upgrade until the operator acts on the
  check's warning; the 0.16.5 notes tell operators to run `lazysite check` after
  upgrading. A template call written back under an old name is false (fails closed for a
  block shown only inside a profile, open for one hidden from it) until the check's
  warning is acted on. The template rewrite edits files outside content history.

verdict
: accepted, confirmed by the release manager on 2026-11-06. Recorded because the
  meaning of an access control's stored value changes (the kind moves from the profile to
  the use), and the upgrade can widen a hand-edited rule; the check names each, and every
  fault on the way fails closed.

walked
: At the 0.16.5 compliance walk (2026-11-06), against the code on the stack's tip: the
  conversion keeps the old store as `address-lists.json.converted` and renames the
  template calls in the pages, layouts, themes, templates and private store
  (`install.pl`), `lazysite check` names an unconverted store, each wrong-slot rule and
  each old call, and the old action, tool and command names are refused naming the new
  ones (`ControlApi::Actions`, the users tool). No trigger fires: the actions, tool and
  page are renamed, none added, and no data is added. SM1321's `bad_url_exempt` (the
  2026-11-06 entry) names profiles too, membership only.

### 2026-11-06 - SM1335, SM1336, SM1339 (0.16.5): a theme's served copies follow its source, and are not written

Assessment drafted by the developer agent at the 0.16.5 compliance walk; confirmed by the release manager on 2026-11-06 (ruling 127; ruling 81; rulings 109-112, 120).

what changed
: SM1335. A write to a theme's source, on any surface (the manager's save, upload,
  delete, move and copy, WebDAV PUT, DELETE, MOVE and COPY, MCP `create_theme`, theme
  delete), re-mirrors that theme to every host's copy, the docroot's and each content
  root's (`Themes::follow_source_write`), or removes the copies when the source is gone,
  and drops the cached renders that link it. Before, a copy was written at activation,
  apply, domain-add and creation only. One theme per write, never the site's.
: SM1336. An installed theme (Upload Theme, MCP `install_theme`) and a copied theme
  (`theme-copy`, `copy_theme`) have their copies written by the same writer,
  `_mirror_theme_assets`, with the tokens and the fingerprint (SM830), where they were
  built by hand from `assets/` or from the docroot's copy.
: SM1339. A write into a host's `/lazysite-assets/<layout>/<theme>/`, the layout folder or
  `lazysite-assets` itself is refused for every caller, the operator included, naming
  the source to write instead (`served_artifact_refusal`, the SM976 F1 rule the choke
  point and WebDAV share). Reading a copy, copying out of one and removing the copy of a
  theme no longer installed are not refused. The theme and the layout a secondary domain
  serves as its own are read-only on every surface, as the primary's are
  (`active_artifact_refusal`, `Common::domain_active_artifacts`; rulings 109, 120).
  `list_files` and the Files page mark each copy `served_copy`. `theme-copy` and
  `copy_theme` take the theme by its path as well as by its name.

threat delta
: None of ADR 0007's four triggers fired: no new interface (the refusals and the
  `served_copy` mark are on existing actions; the theme's path is a new spelling of an
  existing argument), no new sign-in method, no new dependency and no new restricted data
  (a theme's assets are public by design). The question is SM1303's: what reaches the
  served asset mirror (boundary 6). Before, a theme's source reached a copy only at an
  activation or an upload, both checked; now every source write reaches every copy with
  no activation, so whatever lands in a theme's `assets/` - by a manager or WebDAV write,
  a restore or a shell - is published under `/lazysite-assets/` at the next write
  (Elevation of privilege, through a symbolic link to the session secret, as in SM1303;
  Tampering, through a server-run file). The refusal on the copies narrows: no writer,
  the operator included, edits a published copy directly.

controls
: `_mirror_theme_assets` is the one writer of every copy, and refuses to switch in a copy
  whose `assets/` holds a symbolic link or a file type the web server would run
  (`_mirror_unsafe_entry`: SM1303's two archive checks, links listed and never followed),
  keeping the copy it had and logging the entry. The copy is built in a staging directory
  and swapped in, as before. A write to a source needs what it did: the theme's layout
  capability and the path's own reach; a secondary domain's active theme and layout are
  refused to every caller, so a domain's served look changes only by copy, edit and
  activate with `host`. t/unit/manager/430, 431, 432, t/unit/dav/38, t/unit/mcp/73,
  t/integration/116.

residual risk
: A theme's source holding a link or a server-run file stops reaching its copies, and
  says so in the log and the write's answer, until it is removed. An edit to a theme
  reaches every visitor of every page that uses it at once, with no activation step to
  review it. A copy planted before 0.16.2 stays until `lazysite check` names it and the
  operator removes it (SM1304; OBLIGATIONS.md).

verdict
: accepted, confirmed by the release manager on 2026-11-06. No trigger fired;
  recorded because the path into the served asset mirror (SM1303's) now runs on every
  theme write, and a served copy is refused to the operator.

### 2026-11-06 - SM1321, SM1322, SM1327, SM1328, SM1340, SM1341, SM1347, SM1365 (0.16.5): access, sign-in, serving and Odoo changes with no trigger

Assessment drafted by the developer agent at the 0.16.5 compliance walk; confirmed by the release manager on 2026-11-06 (ruling 127). The rest of 0.16.5 moves no control: SM1330 and SM1346 are the test harness and the pinned OOM snapshot in `t/vendor/oom` (0.42 to 0.44, never installed; lazysite's code is unchanged by it, ruling 82), and SM1342 is the manual's anchors. The other changes of 0.16.5 have their own entries: SM1324 and SM1325 (2026-11-05, each firing new-processing-of-restricted-data, recorded at this walk), SM1332-SM1334 and SM1343-SM1345 (2026-11-05), SM1335, SM1336 and SM1339 (2026-11-06).

what changed
: SM1321, the bad-URL blocker (rulings 48, 83, 84). A path that resolves to a regular file
  under the docroot is never counted as a probe (`Lazysite::BadUrl::site_has_file`: the
  path less its query, percent-decoded once, plain segments `lstat`'d from the docroot
  down; a `.` or `..`, a symbolic link on the way, a dot name, the engine tree, a NUL or a
  backslash is not the site's file). Loopback (127.0.0.0/8, ::1) is always exempt, never
  counted or refused, a block on file included; `bad_url_exempt` names address profiles
  whose addresses are exempt too, and the value `none` removes loopback's exemption. The
  Config page refuses an address, an unknown profile, or `none` beside names.
: SM1322, `/login` (rulings 49, 85). `lazysite-auth.pl?action=session` (GET) answers only
  `signed_in` yes or no for the request's own cookie, from
  `Lazysite::Auth::Session::request_session`, the verdict every surface asks; `no-store`,
  logged as a session line, and a no clears the display marker. The chrome script asks
  it on a page carrying `data-ls-auth-check`. "Sign in as someone else" is the sign-out
  with `then=signin`, landing on the sign-in page with `next` through `sanitise_next`.
: SM1327, MCP `write_file` (ruling 51). An optional `base_mtime` makes a write conditional
  on the version read: stale, or for a file gone, nothing is written and the answer is a
  conflict. `rename_page`'s alias and link rewrite save with the time they read.
: SM1328, the Odoo name (ruling 52). `odoo_display_name` in the Odoo extension's
  settings is said by the sign-in dialog, `/odoo-signin`, `/login`'s link, the browser
  helper's messages, the page endpoint's errors and the Unknown Odoo writes panel; one
  reader, `Lazysite::Odoo::Name`, and the helper script carries it as an attribute.
: SM1340, the design guide (rulings 79, 114). `design_guide: /path`, and
  `alias.<host>.design_guide` for a domain, put a link at the head of `/docs/layouts` and
  `/docs/ai-briefing-layouts`; only a same-site path counts (the processor's copy of
  `sanitise_next`'s rule), written through `url_safe`.
: SM1341, the AI docs (rulings 80, 113, 115). Connect an AI assistant
  (`/docs/ai-connector-setup`) becomes public, carrying the endpoints, the connection
  modes and how a client authenticates (pairing key, access token, checking access), with
  placeholders only; `.well-known/ai-partner` lists it. The tools reference stays
  signed-in.
: SM1347, Odoo results (rulings 103, 104). A write Odoo did not keep names its fields
  (`not_kept`), never the values asked or found, with a note the helper draws as text;
  `refused/access` and `refused/missing` each have their own sentence.
: SM1365, the ACL 403. A signed-in visitor refused by an `auth/acls.json` read list who
  opens a page gets the site's 403 page, naming the list's groups (never a user on it), as
  the front-matter group gate does; a file keeps the short 403.

threat delta
: None of ADR 0007's four triggers fired: no new interface (`action=session` is an action
  on the existing sign-in CGI, as `/odoo-signin` was a page on existing surfaces (SM1299); `base_mtime`,
  `bad_url_exempt`, `odoo_display_name` and `design_guide` are a parameter and keys on
  existing surfaces), no new sign-in method (the session check asks the existing
  verdict), no new dependency and no new restricted data. The questions are these.
  SM1321: an exemption on a guard (Denial of service: the blocker counts nothing from an
  exempt address, and behind a front end `trusted_proxies` does not cover, every visitor
  is loopback; a STRIDE row records it), and a path resolved against the disk from a
  request (Information disclosure, by probing which files exist). SM1322: an
  unauthenticated endpoint about a session (Information disclosure, Spoofing). SM1328,
  SM1340: a site-set value written into pages and scripts (Tampering, by markup in the
  value; Spoofing, by an open redirect through the link). SM1341: how a client
  authenticates, readable before sign-in (Information disclosure). SM1365: the 403 page
  names groups (Information disclosure). SM1347: what an ERP write held reaching a page
  (Information disclosure). SM1327 reduces Tampering: a lost update between two writers.

controls
: SM1321: the file test changes only whether a hit is counted, never what is served, and
  answers the same as a fetch of the path would; the exemption is asked only for an
  address on file or a probe about to be counted, of the address `request_address` gives
  under `trusted_proxies` (SM929); profile names only, validated at save, and
  `lazysite check` names an unknown one (t/unit/lib/98, t/integration/296). SM1322: the
  answer is one bit about the requester's own cookie, never why; nothing is set but the
  marker's clearing, and the HttpOnly cookie is left to the endpoints that own it
  (t/unit/auth/74). SM1328: the name is set by a holder of the extension's settings and is
  escaped where it is written (t/unit/odoo/121, t/unit/processor/172). SM1340: a full URL,
  `//`, a backslash or any character outside a path's is no guide at all
  (t/unit/processor/180). SM1341: the page carries placeholders only, held by
  t/lint/311, and describes the engine's own mechanisms, which ship in every release's
  source; no site's addresses, accounts or credentials are on it. SM1365: the groups are the ones the front-matter gate's 403 already names for a
  page; users on the list are never named; draft sections keep their 404 and anonymous
  requests the bounce to sign in (t/integration/345). SM1347: field names only
  (t/unit/odoo/122-124). SM1327: t/unit/mcp/70.

residual risk
: SM1321: a site behind a front end on the same host with `trusted_proxies` unset (the
  default trusts the private ranges, not loopback) counts no probe until it is set (the
  STRIDE row); `lazysite check` warns about it only where address rules are in use, so
  UPGRADE.md says to name such a front end. A probe can learn whether a path is a real file by whether it is counted,
  which a fetch of the path already tells it. SM1341: a site that kept the setup steps
  private by the signed-in manual now publishes them; an access rule over `docs/` or a
  page of the site's own at that path governs it (SM1284). SM1365: a signed-in visitor
  refused a folder learns the names of the groups that may read it, as a front-matter
  gate already told them. SM1322: the answer is uncached and per request, so it is one
  more request a page makes while the marker is set.

verdict
: accepted, confirmed by the release manager on 2026-11-06. No trigger fired;
  recorded because a guard's exemption, the sign-in page's check, a page's public status
  and what a refusal names moved, as the 0.16.3 entry of 2026-11-05 recorded its own.

### 2026-11-06 - SM1369 X0, X1 (0.16.6): an extension's own code can be loaded into a core process

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 134).
Ruling 55; the design is the extension-hooks proposal, whose security model (G-1 to
G-10, and what an extension can never do) these slices begin to build.

what changed
: X0. `t/lint/321` fails a new core line that names Odoo (`odoo`, `OOM`, `oomd`; ruling
  136 counts Odoo's names only, not every extension's script name); the lines there today
  are an allow-list that may only shrink. No behaviour changes.
: X1. An extension's `owns` may declare `hooks` (a mapping) and `requires` (extension
  ids). `Lazysite::Extensions::Hooks` validates both. The manager writes
  `lazysite/extensions.index.json` from the enabled extensions' descriptors on enable,
  disable and save, and `install.pl` does it on every upgrade and reinstall, as the
  site user. `Hooks::call_hook` loads an indexed function from the extension's payload
  lib (`extensions/<stem>/lib`, put on `@INC` by `Lazysite::Extensions::add_payload_lib`)
  and calls it in the calling process. Enabling an extension whose `requires` names one
  that is off is refused by name. In this release no hook kind is live: every
  declaration of one is refused, naming the slice that builds it, and no core code calls
  `call_hook`.

threat delta
: ADR 0007's new-external-interface trigger fires. Until now an extension ran only as
  a separate process (`--describe`, its declared actions); X1 builds an interface
  through which an extension's own Perl runs inside a core process - the manager, and
  from later slices the request path - with that process's rights, its open handles and
  its memory. Nothing reaches it in 0.16.6 (no live kind, no caller), but the interface
  is built here, and each later slice adds only a caller, so the assessment is recorded
  now rather than at the first caller. The other three triggers do not fire: no sign-in
  method (H-1 is X4), no new dependency (Cwd, JSON::PP and Time::HiRes are core and
  declared), no restricted data. The questions are these. Elevation of privilege and
  Tampering: an extension's code running as core, or code that is not the extension's
  (core's, a system module's, a planted file's) run under its name. Denial of service:
  a hook that dies or hangs in a core process. Spoofing: a disabled extension's index
  entry, or a dependency switched off, still being honoured. Tampering: the index file
  itself, between the write and the read.

controls
: The declaration is validated before anything is indexed: unknown hooks and hooks not
  yet built are refused by name, a function is a fully qualified name never in
  `main::`, `CORE::` or `UNIVERSAL::` and never `import`, `DESTROY` or a phase block.
  Only the extension's own code runs: each module a declaration names must be a regular
  file in its payload lib, which is a real directory at each step (a link is refused),
  and must not resolve anywhere else on `@INC`, checked at the build and again at the
  call, with a module already loaded from elsewhere refused; the payload lib is appended
  to `@INC`, never prepended, so it cannot replace core's modules. Only what the index
  lists runs: `call_hook` refuses a function the indexed declaration does not name. Off
  means off (G-1): the extension and every extension it requires must be in
  `lazysite.conf` at the call, read fresh, never cached; the payload lib must be the one
  the index was built from, so an edited index runs nothing. A hook that dies is a
  failure with its reason, never an exception into core (G-9). The index is written
  atomically by the manager, and the build runs extension code only as `--describe`,
  out of process, as before (G-10). t/unit/extensions/70 (the validator),
  t/unit/extensions/71 (the build and the loader, including a stale index after a
  disable, a shadowing module, a linked payload, a dying hook and an unmet `requires`),
  t/tools/330 (the upgrade step), t/lint/125 (the call's enabled-list reader), t/lint/321.

residual risk
: In process the hooks are a contract, not a sandbox (the proposal's "What the model
  does not claim"): an extension is Perl running as the site user and, once a caller
  exists, could do in core's process anything core can. Trust comes from what is
  installed, and ADR 0009 keeps third-party extensions out of tree aside until a signing
  story exists; that boundary is unchanged and is what holds this. A hook that loops is
  not bounded by `call_hook`; each slice that adds a caller decides that caller's
  budget. A long-lived process (a pool worker, from later slices) keeps a payload lib on
  `@INC` and a module loaded once it has run a hook, and two extensions cannot ship a
  module of the same name (the second is refused as found elsewhere). Whoever can write
  `lazysite/` can write the index, as they can already write `lazysite.conf` and
  `handlers.conf`; the call-time checks bound what an edited index can name to an
  enabled extension's own payload.

verdict
: accepted, confirmed by the release manager on 2026-11-06 (ruling 134): the trigger
  fires and the change is contained for 0.16.6, because no hook kind is live and nothing
  calls the loader. The first slice that makes a kind live (X2) adds a caller to this interface
  and should be assessed against this entry, in its own.

### 2026-11-06 - SM1370 (0.16.6): a token follows its account's grant

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 140).

what changed
: Ruling 121. Measured, before any change: no token door fixes a capability into a
  credential. The pairing exchange (`cmd_token_exchange`) replaces the account's
  credential and sets its expiry; an lzs_ token verifies through
  `Auth::Verify::verify_credential`, which resolves `caps_for` from the group store at that
  request (manager API `%token_caps` and MCP `verify_bearer`, per request); an OAuth access
  token maps to a partner, resolved through `partner-caps` at each MCP call, and a refresh
  mints no capability; WebDAV asks `caps_for` once per CGI process. What changes is
  reporting: both whoamis carry a `grant` block (`Capabilities::whoami_roles`) saying the
  grant is the account's at each request, and the layouts briefing stops advising a token
  rotation.

threat delta
: Elevation of privilege is the question: a token holding more than its account now holds,
  after a grant is taken away. It does not, on any door, and did not before
  (t/unit/manager/460 subtests 1-3 pass on b7f178856): a removed grant is refused on the
  token's next request over the control API, MCP bearer and MCP OAuth, and a token confined
  to one domain is refused another's page, read and write, after the account gains four
  capabilities. The `grant` block is a fixed sentence about the engine, no account data. No
  trigger of ADR 0007's four fires: no interface, method, dependency or data is added.

controls
: One resolver (`caps_for`, ADR 0001), asked per request by every door; t/unit/manager/460
  pins each door in each direction, so a capability cache or a snapshot in a credential
  fails there.

residual risk
: An MCP client keeps the tool list it fetched at connect: after a grant is removed it may
  still show a tool, which the server refuses (the call is refused and audited, -32002);
  after a grant is added it may not show the tool until it lists again. The server declares
  `listChanged: false` and has no push channel, so the remedy is the client's (the whoami
  note and the docs). There is no per-token narrowing in this release; what narrows a token
  is its account's domain scope and address rule (SM1140), both per request.

verdict
: accepted, confirmed by the release manager on 2026-11-06. No trigger fired; recorded
  because ruling 121 is an access-control rule and this is where it is shown to hold.

### 2026-11-06 - SM1371 (0.16.6): agent roles, the role summary, the extension offer, and a form's config

Assessment drafted by the developer agent; confirmed by the release manager on 2026-11-06 (ruling 140).

what changed
: Ruling 122. Four assignable groups ship in the seed, each over MCP with one job's
  capabilities on the record: `content-agent` (`manage_content`, `manage_nav`,
  `manage_forms`), `data-agent` (`manage_data`, `write_data`, `manage_briefs`),
  `forms-reader` (`read_submissions`), `analytics-agent` (`analytics`). An existing site
  with the shipped role layer adopts each absent one once, with no members, recorded in
  `bundles-adopted.json` (`_adopt_agent_roles`).
: `Auth::Settings::role_summary`: the account's direct assignable groups that grant
  something, less its own `role-<account>` group, and the capabilities it holds that none
  of them grants (`beyond`), reported by both whoamis and by `users-page` to the Users page.
: The Groups page's capability map (`channel-services`) carries each owning extension's
  `script`; ticking a grant whose extension is off asks to enable it, through
  `extension-enable`.
: `manage_forms` reads and writes `lazysite/forms/<name>.conf` through MCP `read_file` /
  `write_file` and the manager's `read` / `save`, as over WebDAV since 0.8.1: the carve-out
  gate requires it (`carveout_requirement`, `form_conf_name`), and the choke point asks it
  again from `Manager::Files::$CALLER_CAPS`; a write meets WebDAV's rules (UTF-8, targets
  naming existing handlers only, the form in the caller's reach, handlers it may use).

threat delta
: Elevation of privilege is the question for each part.
: The roles: a shipped group is a grant waiting for a member. Adoption adds no member, so
  no account's capabilities change at the upgrade (t/unit/users/70); putting an account in
  a role is the existing `group-add`, with SM195's conferral ceiling (a delegate confers
  only what it may). No role carries `ui`, `api`, `webdav`, design, settings, people,
  audit or purge.
: The role summary and the map's `script`: read-only, shown to callers who already see the
  account's settings (users-page) or their own grant (whoami); the script path is the one
  the Extensions page already lists.
: The extension offer: the enable stays a separate request that needs `manage_config`
  (`cookie_cap` on `extension-enable`) and is audited as a mutating action; a grant never
  enables anything by itself. A Groups-page user without `manage_config` is refused the
  enable as before.
: The form config: this widens what `manage_forms` reaches on two doors to what it
  already reached on the third. A form's config names which handlers a form dispatches to,
  and `manage_forms` already writes it through `bind_form`, `set_form_uploads`,
  `set_form_notify` and `form-targets-save`; the raw write meets the same binding rules,
  so it reaches no handler, destination or form those verbs refuse. Credentials
  (`smtp.conf`), handler definitions (`handlers.conf`) and the schedule stay refused
  (t/unit/manager/461). Undef caps (an unsecured site, where the gate is skipped) refuse.
: No trigger of ADR 0007's four fires: no new interface (two blocks on whoami, a field on
  an existing response, existing actions), no new sign-in method, no new dependency, no new
  restricted data.

controls
: Groups-only resolution (ADR 0003, `caps_for`), the adoption rules of SM1241/SM1262
  reused, the carve-out definition shared by both dispatchers (SM268 H4) and answered again
  at the choke point, `Handlers::form_conf_problems` and `handler_bind_refusal` as on the
  other doors. Tests: t/unit/users/70, t/unit/manager/460 (subtest 4), 461, 462.

residual risk
: A site that granted `manage_forms` to an account it would not trust with a form's raw
  config gains nothing it could not already do through the binding verbs, but the raw file
  is now one more way to do it; UPGRADE.md says to check who holds `manage_forms`. An
  operator who puts an agent in `data-agent` gives it `manage_briefs` with the data
  capabilities (a choice recorded in the filing). The four roles appear on every site with
  the shipped role layer; an operator who does not want them deletes them once.

verdict
: accepted, confirmed by the release manager on 2026-11-06. No trigger fired; recorded
  because shipped grants, a capability's reach on two doors and the Groups page's enable
  path moved.

### 2026-11-06 - SM1373 (0.16.6): an extension's settings read answers only its own keys

Assessment drafted by the developer agent, for the release manager's confirmation.

what changed
: `extension-read` (`Lazysite::Manager::Extensions::action_extension_read`) answered
  every `key: value` pair in an extension's `config_file`. For the two extensions whose
  file is `lazysite/lazysite.conf` (bad-url-blocker, log) that was the site's whole main
  config; for one with its own file, any key its schema does not name. Only the
  extension's own `type: password` fields were dropped. The answer is now the keys the
  extension's `config_schema` or `config_keys` names, whatever its file, with password
  fields still dropped.

threat delta
: Information disclosure, narrowed: a read of one extension's settings no longer carries
  site settings and secrets kept in the same file that the extension does not own (a
  credential another extension keeps in `lazysite.conf`, for one). Who may call it is
  unchanged: `extension-read` is absent from the token gate (`%GATE` in
  `Lazysite::ControlApi::Actions`), so no access token, MCP client or partner reaches
  it; it is reachable by a manager cookie session only, with `manage_config` (its
  `cookie_cap`; the dispatcher's cookie check in `lazysite-manager-api.pl` asks it).
  The exposure was to an account trusted with the site's settings, but wider than its
  own door: `config-read`, the Config page's reader, answers a named safe subset of
  `lazysite.conf` with no secrets (SM122), and `extension-read` answered the rest.
  No trigger of ADR 0007's four fires: no interface,
  method, dependency or data is added, and the change removes output.

controls
: One key list, the extension's own declaration, read where the values are chosen;
  t/unit/manager/445 puts a foreign key (and a foreign password-shaped key) beside
  bad-url-blocker's and log's in `lazysite.conf` and a key outside form-smtp's schema in
  its own file, and finds none answered, and the password field still dropped.

residual risk
: An extension that declares a key also kept by another extension in the same file is
  answered it; that is a shared key by the extensions' own declarations. Whoever
  can read `lazysite/lazysite.conf` as a file on the host still reads it whole.

verdict
: accepted (drafted; for the release manager's confirmation). No trigger fired; recorded
  because what a settings read discloses moved.

### 2026-11-06 - SM1374 (0.16.6): a plan Odoo refused shows the visitor only validation text

Assessment drafted by the developer agent, for the release manager's confirmation.

what changed
: An Odoo plan that failed at Odoo answered `apply-incomplete` with "the plan did not
  apply completely - see the counts", and each failed change carried Odoo's message
  through SM1186's filter (`_usage_text`: control characters, a cap, a path, a trace or a
  secret's name withholds it), whatever kind of fault it was. Now the message is shown
  only for a change whose journal entry's OOM category is `validation` (ValidationError,
  UserError), without the "Odoo Server Error:" prefix, and that message is the answer's
  `error`; a refusal raised by the operation itself (kind `refused`, SM1198) keeps its
  sentence; every other failure, and one whose journal cannot be read, is withheld, and
  `error` is a plain sentence for the visitor. The counts stay in `result`, the journal
  and a WARN log line (binding, operation, plan, counts; never a change's text).

threat delta
: Information disclosure, narrowed. An access fault's text names a model and the groups
  that may reach it, a missing record's its id, an unclassified fault anything Odoo's
  server says (a table or column name); the filter's patterns did not catch those, and
  a public binding's visitor received them. No trigger of ADR 0007's four fires: no
  interface, method, dependency or data is added; the change removes output.

controls
: The category is OOM's (`Odoo::Error::fault_category`, from the server's exception
  class), read from the journal OOM kept of the apply, by change; a change with no
  readable category is withheld (fail closed). A shown message still passes the filter.
  t/unit/odoo/125 drives UserError and ValidationError (shown, prefix gone), and
  AccessError, MissingError and an unclassified fault (the plain sentence, and none of
  the text anywhere in the answer), with the shop fixture's fake transport; t/unit/odoo/77
  holds the same through the real oomd.

residual risk
: A validation message is Odoo's text, written for the person who sent the data; one a
  module writes with internals in it reaches the visitor unless the filter catches it.
  A change whose answer never came (`unknown`, SM1218) still carries the transport's
  message through the filter, as before.

verdict
: accepted (drafted; for the release manager's confirmation). No trigger fired; recorded
  because what a refusal tells a visitor moved.
