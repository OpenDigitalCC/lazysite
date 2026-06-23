# lazysite — seven-dimension review

Date: 2026-06-23 · Branch `claude/hestia-install-fixes` = `main` @ `8642ed9` (building 0.3.38)
Reviewer: Claude (manual run; `projkit` not yet built). Evidence: full suite, perl -c,
perlcritic, cloc, the strict SBOM gate, a secrets grep (no gitleaks on host), and three
adversarial correctness/security passes over the large modules.

Status key: GREEN (pass) · WARN · RED (must fix before a clean signoff).

| # | Dimension | Status |
|---|-----------|--------|
| 1 | Code quality | GREEN (with debt) |
| 2 | Test coverage | GREEN count / WARN measured |
| 3 | Performance | WARN (no baseline) |
| 4 | Documentation | GREEN content / WARN taxonomy |
| 5 | Security | RED (several real findings) |
| 6 | Correctness & groundedness | GREEN groundedness / findings overlap D5 |
| 7 | Policy compliance | RED pending regime + artefacts |

---

## 1. Code quality — GREEN (with debt)

- **perl -c: all clean** across the five CGIs, `tools/*.pl`, `plugins/*.pl`.
- **Size:** non-test Perl ≈ 15,471 LOC. `lazysite-manager-api.pl` **4,273**, `lazysite-processor.pl` 3,104, `lazysite-dav.pl` 1,496, `lazysite-auth.pl` 1,017. The no-shared-modules convention (each CGI self-contained) is deliberate but drives single-file size — `manager-api` is large enough that complexity is a maintenance risk.
- **perlcritic:** no shared `.perlcriticrc`; default policy set reports 1,324 @ sev3 and 318 @ sev4–5. The "serious" set is dominated by **style**, not bugs: `RequireFinalReturn` 119, `RequireEncodingWithUTF8Layer` 90, `ProhibitExplicitReturnUndef` 53 (= 262/318).
- `perltidy` available; the suite has a `t/lint` level.

**Remediation:** adopt a tuned shared `.perlcriticrc` (the framework's intent) and decide the `return undef` convention site-wide; consider extracting the manager-api action handlers into smaller files even within the self-contained convention.

## 2. Test coverage — GREEN (count) / WARN (measured)

- **1,259 tests, 94 files, suite green in 124s.** Five-level taxonomy: unit 73 / integration 9 / journey 5 / smoke 1 / lint 1 / tools 4. Test:code LOC ≈ 0.72 (11,146 / 15,471) — strong.
- **Measured branch coverage is the gap.** The tests exercise the CGIs as **subprocesses** (`open3`/`open2` with `$^X`), so `Devel::Cover` (which instruments only the parent `prove` process) cannot see most of the real execution path — a coverage run reports `n/a`. The behavioural coverage is genuine (black-box), but there is **no declared line/branch threshold**, which the framework requires.

**Remediation:** propagate `-MDevel::Cover` into the subprocess spawns (or run a parallel in-process `LOAD_ONLY` harness) to produce a real branch number; then declare a floor.

## 3. Performance — WARN

- `docs/architecture/performance.md` exists, and there are real perf notes (token-vs-password verify timing; WebDAV/`lzs:sha256`-on-demand notes). But there is **no declared benchmark baseline** (`scripts/bench` + baseline JSON), which is the dimension's bar.

**Remediation:** add a small benchmark (page render, a DAV PUT, token verify) with a committed baseline so regressions gate.

## 4. Documentation — GREEN (content) / WARN (taxonomy)

- **Strong content:** README, CHANGELOG (commit-ref keyed), `SECURITY.md` (policy), `docs/architecture/{code-quality,performance,security,test-coverage}.md`, `docs/development.md`, `docs/feature-requests/SM070–075`, the four agent briefings (publishing/authoring/layouts/configuration), `reference`, and `installers/hestia/INSTALL-RUNBOOK.md`.
- **Five-audience taxonomy not followed:** MISSING `docs/USER.md`, `docs/DEVELOPER.md`, `docs/IMPLEMENTOR.md`, `docs/OPERATOR.md`, `docs/POLICY.md`, and `COPYRIGHT`. Security content is split (SECURITY.md policy + docs/architecture/security.md model) and now **trails the code**: claim tokens, TOTP, per-file ACLs, the forms carve-out, and the www-data perms model aren't all reflected, and the security model's reliance on the Apache `RequestHeader unset` trust-strip should be stated as a hard deployment requirement (see D5/1a, H2).

**Remediation:** map/rename to the taxonomy; promote the runbook to `OPERATOR.md`; add `POLICY.md`; refresh the security docs for the new surfaces + the trust-strip requirement.

## 5. Security — RED

Foundations are sound — constant-time compares (`const_eq`), CSRF (HMAC, hourly window+grace, method-keyed, token-exempt), cookie/token mutual exclusion, the `%need` capability gate (no aliasing/fallthrough/token-reachable cookie action), traversal/`realpath` guards, CSPRNG (fail-closed), `EVAL_PERL=>0`, the forms-carve-out regex, and SSRF guards. But the rapid recent additions opened real gaps:

**High**
- **D5-H1 / token path inherits operator (manager-api `_is_operator`).** `_is_operator()` returns true for **any token client** when `manager_groups` is unset, and otherwise trusts the client-influenceable `HTTP_X_REMOTE_GROUPS` (mitigated only by the Apache trust-strip, a deployment-doc requirement). A `webdav`-only publishing partner can then `acl-set/get/remove` to **rewrite or clear ownership ACLs on any file**, defeating SM074. *Fix (small): `_is_operator()` hard-returns 0 when `$token_auth`; never consult `X-Remote-Groups` on the token path.*
- **D5-H2 / dav read-side blocklist gap.** `is_blocked` is consulted only on **write**. An unscoped `webdav` account can `GET /dav/cgi-bin/lazysite-*.pl` and read **CGI source** (the blocklist's own `cgi-bin`/`manager` entries imply these were meant unreachable). Scoped partners are unaffected. *Fix: apply `is_blocked` (and the `.pl` rule) on reads too.*

**Medium**
- **D5-H3 / ACL actions don't enforce the dav's full deny-set** — only the narrow `@BLOCKED_PATHS`; `acl-get`/`acl-remove` have no block check, so ACL entries can be set/read for `smtp.conf`, `lazysite.conf`, etc. *Fix: gate all three ACL actions through the dav deny-set + `is_blocked_config`.*
- **`action_read` omits `is_blocked_config`** — a cookie operator can `read` `lazysite/forms/smtp.conf` (plaintext SMTP password), which the dav and `file-download` both deny. *Fix: add `is_blocked_config` to `action_read`.*
- **TOTP seed at rest** — `user-settings.json` (0660, group-readable by www-data) stores the **raw base32 TOTP seed** in cleartext; a web-tier compromise yields every MFA seed. *Fix: encrypt at rest or move to a 0600 file the web tier can't read.*
- **Account clobber via truthiness** — `cmd_account_create`/`cmd_add` test `$users{$user}` (truthy) not `exists`, so they overwrite an existing **passwordless** (token-only/seeded) account and reset its provenance. *Fix: `exists $users{$user}`.*
- **Single-use consume TOCTOU** — claim/pairing-key/recovery-code consumption is read→verify→delete→write with no lock spanning the window; concurrent requests can both pass before either clears (contradicts the SM072 §10 "replay covered" gate). *Fix: flock across the consume cycle.*
- **TOTP replay** — no last-accepted-timestep stored; a captured code is replayable within its window. *Fix: persist and reject `<= last_counter`.*
- **`auth_proxy_trusted: true`** disarms client-spoof protection with no IP allowlist (boolean, silent). *Fix: require a trusted-proxy IP allowlist.*
- **Second include pass over TT output** — a variable-resolved `::: include` is honoured after rendering, widening the file-read surface (docroot-bounded by `realpath`).

**Tooling / supply chain**
- **Strict SBOM gate FAILS:** `Time::Local` is used but missing from `dist/config/sbom-deps.json` (the gate works — it caught real drift). *Fix: declare it + re-run.*
- **No gitleaks on host** (manual grep clean). Install for a real secrets gate.

## 6. Correctness & groundedness — GREEN (groundedness)

- **No hallucinated symbols** found in any pass — every referenced sub/method was verified to exist. perl -c clean. Good groundedness despite the volume of recent change.
- Minor **spec-drift:** a stale comment referencing a non-existent `rotate-auth-secret` action; the SM074 docs describe `.acl` *processor* handling that (correctly) doesn't exist (ACLs govern WebDAV/manager only, per spec).
- The **plausible-but-wrong** findings are the security ones above (truthiness clobber, operator detection, include-over-output) — they compile and pass tests but are wrong; they were found by reading against intent, which is exactly what this dimension is for. The fast recent cadence is the risk factor.

## 7. Policy compliance — RED (pending regime)

- **Regime undetermined** — needed before scoring (it sets floors + required artefacts). lazysite is operator-deployed *and* exposed to external AI partners, so it's past experiment/internal.
- **Strength:** the SBOM machinery (`sbom-deps.json` cross-distro schema + `manifest-to-sbom.pl --strict`) is the framework's named seed — but it **currently fails** (Time::Local).
- **Gaps:** no Declaration of Conformity, no support-period statement, no OpenChain policy docs, no release signing (Sigstore), no `docs/POLICY.md`. **VERSION drift** (file says 0.2.18; latest 0.3.38). Build recipes: RPM/Alpine/OCI **missing** (`installers/docker/` is empty; no `.spec`/`APKBUILD`) — metadata exists, recipes don't.

**Remediation:** declare the regime; fix the SBOM gate + VERSION; add POLICY.md, support-period, DoC path, signing; fill the packaging recipes if those targets are real.

---

## Priority summary

Ranked by (real risk × ease of fix):

1. **manager-api `_is_operator` token bypass (D5-H1)** — tiny fix, prevents a partner rewriting any file's ACL ownership.
2. **dav read-side blocklist gap (D5-H2)** — apply `is_blocked` on read; stops CGI-source disclosure.
3. **`action_read` + ACL actions miss `is_blocked_config` (D5-H3)** — stops manager read of `smtp.conf` password; aligns ACL actions with the dav deny-set.
4. **Account clobber via truthiness** — one-word fix (`exists`), prevents takeover of passwordless accounts.
5. **TOTP seed at rest / TOTP replay / consume-TOCTOU** — MFA + single-use hardening; contradict the SM072 acceptance gates.
6. **SBOM gate failing + VERSION drift** — declare `Time::Local`, bump VERSION; cheap, unblocks a clean supply-chain signoff.
7. **Coverage measurement, perf baseline, docs taxonomy, packaging recipes, regime + policy artefacts** — the framework-conformance backlog.

Items 1–4 are small, real, and security-relevant — the recommended immediate batch.

**Update (same day):** priority items **1–4 are FIXED** (in 0.3.39):
`_is_operator` returns 0 under token auth (1); the dav blocklist applies to reads
(2); `action_read` + the `acl-*` actions enforce `is_blocked_config` (3);
`account-create`/`add` use `exists` (4). Regression tests in
`t/unit/manager/18-security-fixes.t` and `t/unit/dav/12-acl.t`. Suite 1269.
Items 5–7 (TOTP/consume hardening, SBOM gate + VERSION, the conformance backlog)
remain open.
