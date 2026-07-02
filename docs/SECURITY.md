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
Denial of service | A flood of CGI forks, or an unbounded upload / render, exhausting the host | Login rate limiting (per-IP window); upload size gate; PUT streamed in bounded chunks; checked writes fail closed on ENOSPC (review D5) | No global concurrency cap (relies on the web server / MPM); capacity test is a held pre-launch item
Elevation of privilege | A token/WebDAV partner reaching manager-only actions or another account's files | Token clients are confined to the control-API subset + `%need` capability map; never operators; per-file ACLs bind them (SM074); manager bypass is cookie-only | ASVS V4 met; the capability model is groups-only + explicit (ADR 0003), removing implicit manager status
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
