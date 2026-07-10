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

## STRIDE assessment

```datatable
columns: Category | Top threat for lazysite | Control (and where) | Residual / ASVS
widths: 2.6cm | X | X | 3.4cm
bold: 1
tone: medium
text: 2 3
---
Spoofing | Forged `X-Remote-User` / `X-Remote-Groups` headers from the client, impersonating an operator | Two-signal trust gate + mandatory edge stripping (`apply_trust_gate`; security.md "Auth proxy trust model"); cookie is HMAC-signed | Depends on correct vhost config - the single highest-consequence operator obligation; verified by lazysite-check --check-dav and the vhost template shipping the RequestHeader unset lines
Tampering | Hostile `layout.tt` / page executing arbitrary Perl through Template Toolkit | TT runs with `EVAL_PERL=0`; layout authoring gated by manage_layouts + webdav; content vs layout capability split (SM082) | ASVS V5: a layouts-capable partner is inside the trust boundary by design - scoped by capability, not sandboxed
Repudiation | An action taken with no attributable record | Append-only audit trail (who/what/target/origin/outcome), incl. denied attempts; login/logout audited | Audit read gated by the `audit` capability; ASVS V7 logging met; time is server clock
Information disclosure | Auth secrets or raw logs readable off the docroot; visitor PII in stats | Secrets under `lazysite/auth/` (Apache-denied, 0660); stats export is aggregated + IP-anonymised; raw-log download removed (0.5.29); error surface synthesised | TOTP seeds are stored recoverable (documented at-rest note, security.md) - accepted at L1, an L2 gap to close with an at-rest key
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
