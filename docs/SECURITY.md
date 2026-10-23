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
11. **The address rule** (SM1134, 0.15.10) -> named allow and deny lists that pages,
    folders and groups apply; it narrows what other rules grant and never widens it.
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
  notices. Batch-1 fix (bdb4c86): password-carrying plugin configs are now
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
  sync (the git-sync plugin follow-up) must never carry a secret.

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
  git-sync plugin's own assessment.

verdict
: accepted.

### 2026-07-10 - SM085 phase 1 (sync half): git-sync - egress to an operator-configured remote (unreleased, on main)

what changed
: the `git-sync` plugin (opt-in) pushes/pulls the content history to a
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
  the manager AND re-validated in the plugin; all git execution stays
  list-form via `Lazysite::Git::run_git`. Pull applies only fast-forwards
  or explicit `-X ours/theirs` merges, each behind a prerestore safety
  snapshot; a failed merge is aborted (worktree unchanged). Push never
  forces. Outcomes are audited (`plugin-action git-sync (push|pull
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
  It ships as an ADR 0009 plugin, born disabled, where disabled means the
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
  10 s so disabling the plugin stops the runtime, one supervisor per docroot
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
  job set, and the plugin's config note says a purpose account is preferred
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
: `plugins/odoo.pl` (born disabled) and the page endpoint `lazysite-odoo.pl`. A
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

Assessment drafted by the developer agent; the release manager confirms.

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
: proposed: accepted. The trigger fires on a local socket and is contained: the
  socket is the request-path user's alone, the parent holds compiled code and nothing a
  request or a configuration carries, and the endpoint's own gates run unchanged in each
  child. No ahead-of-schedule third-party engagement beyond the one ADR 0007 already
  requires, which takes the Odoo endpoint in scope (the SM747 entry).

### 2026-10-23 - SM1257, SM1242, SM1258 (0.16.1): a page's stem rule moves and goes with the page

Assessment drafted by the developer agent; the release manager confirms.

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
: proposed: accepted. No trigger fired; recorded because it closed a bypass of a
  boundary this register names, as the SM1213 entry was. The remediation record ADR 0007
  asks for stays for the certified release (`docs/compliance/OBLIGATIONS.md`).

### 2026-10-23 - SM1223-SM1225, SM1244, SM1247, SM1248, SM1261 (0.16.1): the Odoo extension's options and OOM 0.42

Assessment drafted by the developer agent; the release manager confirms.

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
: proposed: accepted. No trigger fired; recorded because the extension's inputs, outputs
  and dependency version moved.

### 2026-10-23 - SM1233 (0.16.1): a Docker Compose package

Assessment drafted by the developer agent; the release manager confirms.

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
: proposed: accepted. No trigger fired; recorded because it is a new way the product is
  distributed and run.

### 2026-10-23 - SM1240, SM1241, SM1262, SM1263, SM1266, SM1221, SM1235-SM1239, SM1249, SM1265, SM1256, SM1259, SM1260 (0.16.1): access, rollout and channel changes with no trigger

Assessment drafted by the developer agent; the release manager confirms.

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
: proposed: accepted. No trigger fired; recorded because access, a sign-in control and a
  security header moved.
