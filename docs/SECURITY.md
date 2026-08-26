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
the audit trail.

Trust boundaries (each is where an attacker's input crosses into trusted code):

1. **The public web request** -> the processor / auth wrapper (anonymous
   internet).
2. **The `X-Remote-*` header contract** -> everything downstream trusts it;
   the edge must strip client-supplied copies (the two-signal trust gate).
3. **The WebDAV / control-API / MCP partner** -> a token holder with a bounded
   capability set and per-file ACLs.
4. **Authored content + layouts** -> Template Toolkit evaluates them server
   side.
5. **The manager operator** (cookie) -> bypasses per-file ACLs within the
   manager.
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
Denial of service | A flood of CGI forks, or an unbounded upload / render, exhausting the host; vulnerability-scanner probe floods | Login rate limiting (per-IP window); upload size gate; PUT streamed in bounded chunks; checked writes fail closed on ENOSPC (review D5). SM128: the bad-URL auto-blocker (on by default) refuses an IP after it hits too many scanner-probe paths in a window, enforced in the auth wrapper | No global concurrency cap (relies on the web server / MPM); capacity test is a held pre-launch item; the auto-blocker covers auth-wrapped sites
Elevation of privilege | A token/WebDAV partner reaching manager-only actions or another account's files; a manager account driven remotely | Token clients are confined to the control-API subset + `%need` capability map; never operators; per-file ACLs bind them (SM074); manager bypass is cookie-only. SM127: an account with group-granted manager access (`ui`) is refused outright on the api/mcp transports, and a group may not combine `ui` with `api`/`mcp` - manager access is interactive-only, so a leaked/misissued token on a manager account cannot drive the site | ASVS V4 met; the capability model is groups-only + explicit (ADR 0003), removing implicit manager status
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
