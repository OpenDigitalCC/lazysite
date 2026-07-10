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
