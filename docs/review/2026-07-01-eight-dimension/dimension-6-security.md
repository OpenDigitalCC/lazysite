---
title: "Dimension 6 - Security - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

REFUSE - every mechanical gate passes when run for real (secrets lint 3/3, strict SBOM gate exit 0 with 204 components, `perlcritic --theme security` clean across all 36 production files), but the framework settles this dimension for a networked, user-facing Commercial project only when a STRIDE/ASVS-structured threat model and a current pentest back the design-time analysis; neither exists, there is no `pentest:` manifest block (no `project.yml` at all), and no CVE check runs against the declared dependencies.

## Method

Assessed at tag `v0.5.35`, commit `de12238`. Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 6 detail and the penetration-testing gate (posture table, `pentest:` manifest block, refusal conditions). Commands run:

- `prove -l t/lint/03-secrets.t` - 3 tests, PASS.
- The SBOM strict gate exactly as `tools/release.sh` lines 205-228 invoke it: `perl tools/build-manifest.pl --staged . --out ./release-manifest.json --version 0.5.35 --channel edge` then `perl tools/manifest-to-sbom.pl --strict --manifest ./release-manifest.json --deps ./dist/config/sbom-deps.json --out ./sbom.json --version 0.5.35 --staged .`. Generated files deleted afterwards; `git status --short` confirmed only `docs/review/2026-07-01-eight-dimension/` untracked.
- `command -v gitleaks` - exit 1 (not installed).
- `perlcritic --theme security` over the 7 root `*.pl`, 9 `tools/*.pl`, 6 `plugins/*.pl` and all 15 `lib/Lazysite/**/*.pm` (36 files), completed well inside the 3-minute box.
- Read: `SECURITY.md` (74 lines), `docs/architecture/security.md` (594 lines), `docs/POLICY.md`, `dist/config/sbom-deps.json`, `t/lint/03-secrets.t`, `t/lint/02-perlcritic.t`.
- Absence greps: `STRIDE|ASVS|threat model|pentest|penetration` over `docs/` and root docs; `CVE|debsecan|vulnerab` over `tools/`, `Makefile`, `dist/`; `ls project.yml`.

## Findings

### F6.1 - Committed secrets gate passes; gitleaks absent (WARN)

`t/lint/03-secrets.t` passes (3/3: no hardcoded private key, no cloud access-key id, no assigned secret literal in tracked source). The test's own header is honest about its ceiling: "A floor, not a substitute for gitleaks (install that for a thorough scan)". `command -v gitleaks` returns nothing (exit 1) - the framework names "gitleaks host-wide" as the tool for this check, and it has never run here (working tree or history). Classification: WARN - the floor is real and green, the required scanner is missing.

### F6.2 - Strict SBOM gate passes (PASS)

Run for real in release.sh order: `build-manifest: wrote ./release-manifest.json (174 files)`, exit 0; `manifest-to-sbom: wrote ./sbom.json (204 components)`, exit 0. Output is CycloneDX with per-file SHA-256 hashes and SPDX licence ids. The by-design property holds: an undeclared `use`/`require` fails the release, so the SBOM cannot drift from the code. Generated files were removed after the run; `git status --short` shows only this review directory untracked. Classification: PASS.

### F6.3 - perlcritic security theme clean, but not gated (PASS with a gap)

All 36 production files report `source OK`, overall exit 0. However the committed lint gate (`t/lint/02-perlcritic.t`) runs the project profile at severity 4, not the security theme - today's clean security-theme result is a hand-run fact, not an enforced one. Classification: PASS on the result; the wiring gap feeds recommendation 5.

### F6.4 - No CVE check against declared dependencies (WARN)

The framework requires a "CVE check against declared dependency versions". Nothing in `tools/`, `Makefile` or `tools/release.sh` performs one (grep confirms; `docs/POLICY.md` covers CVD process only). `dist/config/sbom-deps.json` declares 28 modules with deliberately floating versions - coherent with the house rule against pinning, and correct for a Debian-packaged dependency chain, but it means CVE exposure is a property of the host package set and nothing observes it. Every one of the 7 non-core modules carries a `debian_pkg` field (libarchive-zip-perl, libio-socket-ssl-perl, libwww-perl, libtemplate-perl, libtext-multimarkdown-perl, liburi-perl, plus perl itself), so a `debsecan`-based check fits the no-CPAN house rule exactly: extract the `debian_pkg` set from `sbom-deps.json`, run `debsecan --suite <codename> --only-fixed`, and fail (release gate) or alert (operational monitor) on intersection. Classification: WARN.

### F6.5 - No STRIDE/ASVS threat model (REFUSE)

`SECURITY.md` at the root is a CVD policy (reporting channel, scope, response targets) - good, but not a threat model. `docs/architecture/security.md` is a strong 594-line security model (three-layer trust model, cookie/HMAC design, SSRF guard, upload validation, residual-risk and known-constraints sections, the hard header-strip deployment requirement) - but it is narrative, not structured against STRIDE or ASVS; grep for `STRIDE|ASVS` over all docs returns nothing. `docs/POLICY.md` line 14 actively mis-files the threat model as part of the not-selected Commercial-regulated overlay, whereas the framework requires it in `docs/SECURITY.md` "where the regime warrants it" - a user-facing, multi-tenant, operator-deployed Commercial service warrants it. The raw material largely exists; it needs restructuring plus explicit entries. The top 5 entries a STRIDE pass over THIS attack surface (CGI + cookie auth + token auth + WebDAV + MCP + uploads + TT templating) must carry:

1. **Spoofing / Elevation of privilege - forged trust headers.** A client-supplied `X-Remote-User`/`X-Remote-Groups` on any vhost missing the `RequestHeader unset` lines makes the client an operator on the cookie path. Documented as a "hard requirement, not advisory" with defence in depth on the token path only (`_is_operator` returns 0 under token auth) - the single highest-consequence configuration failure and it lives outside the codebase's control.
2. **Tampering / Elevation of privilege - hostile theme or layout.** An uploaded `layout.tt` executes with full Template Toolkit power in the CGI's identity; theme upload (Archive::Zip) plus the SM071 WebDAV layout channel makes template injection equivalent to code execution for anyone holding a theme-capable credential.
3. **Information disclosure - secrets under the docroot.** `lazysite/auth/.secret` (0600), TOTP seeds at rest (documented accepted risk), and `lazysite/forms/submissions/` all live beneath the web root; one web-server misconfiguration exposes them. `tools/lazysite-check.pl` detects this but is optional.
4. **Tampering - partner write-boundary bypass.** WebDAV/manager path traversal and deny-list bypass by AI publishing partners; the canonical deny list is pinned by `t/integration/06-deny-consistency.t` and enforced in `lazysite-dav.pl` - the entry should record the boundary, its test, and the residual (new endpoints must join the canonical list).
5. **Denial of service / Repudiation - CGI amplification and audit integrity.** Process-per-request CGI under upload/MCP/form load with per-endpoint DB_File rate limits (saturation and disk-full via unrotated logs as residuals), paired with an audit log that is append-only by convention (no integrity chaining, no rotation) and the documented 24-hour non-revocable cookie window as accepted risks needing explicit entries.

ASVS Level 1 is the appropriate verification companion for the current posture. Classification: REFUSE - the framework makes an absent method-structured threat model a signoff failure for this regime.

### F6.6 - No pentest gate (REFUSE)

No `project.yml`, no `pentest:` block, no `docs/pentest/`, and the only pentest mentions in `docs/` are the review docs themselves. The framework's posture table puts lazysite at **commercial (operator role)** - it is operator-deployed and hosts customer sites - requiring an **annual pentest plus on significant change**, scope **application + infrastructure + hosting**. The refusal condition is structural: the signoff verifies "`required: yes` present and the last-report within the cadence's window - or a waiver ADR"; none of the three exists. Note also that SM070 (WebDAV endpoint), SM071 (theme/layout channel) and SM072 (MFA/credential lifecycle) are each a `new-external-interface` or `new-authentication-method` significant-change trigger that would have fired had the block existed. Classification: REFUSE.

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies.

1. **Declare the pentest gate and commission the first test.** Add `project.yml` with the framework's block, shaped for this posture:

   ```yaml
   pentest:
     required: yes
     scope: [application, infrastructure, hosting]
     cadence: annual
     significant-change-triggers:
       - new-external-interface
       - new-authentication-method
       - new-hosting-region
       - new-processing-of-restricted-data
     tester-qualifications: [CREST-CRT, OSCP]
     independence: third-party
     last-report: docs/pentest/<date>-report.pdf
     remediation-sla: { critical: 72h, high: 30d, medium: 90d, low: 180d }
     retest-required-for: [critical, high]
   ```

   Declaration effort S; the test itself L (external engagement). Satisfies the pentest gate - one of the two REFUSE triggers.
2. **Author the STRIDE + ASVS L1 threat model** in root `SECURITY.md` (or a section it links), restructuring `docs/architecture/security.md` content and adding the five entries in F6.5, each STRIDE category addressed or marked not-applicable. Effort M - most prose already exists. Satisfies "threat model recorded in docs/SECURITY.md ... structured against the chosen method" - the other REFUSE trigger.
3. **Add a debsecan-based CVE check** keyed off the `debian_pkg` fields in `dist/config/sbom-deps.json`: a small tool (core-Perl, shells to `debsecan`) run in `tools/release.sh` after the SBOM gate and periodically in operation. Requires the `debsecan` Debian package on the build host (ask the operator - no sudo here). Effort S. Satisfies "CVE check against declared dependency versions" within the no-CPAN house rule.
4. **Install gitleaks host-wide and run it once over full history**, then keep it in the release path alongside the committed floor test. Requires an operator install (single static binary or Debian package). Effort S. Satisfies "gitleaks host-wide".
5. **Wire `perlcritic --theme security` into `t/lint/`** as a fourth lint test (it passes today, so the gate is free at introduction). Effort S. Converts F6.3's hand-run PASS into a by-design prevention.
6. **Correct `docs/POLICY.md` line 14** so the threat model is no longer described as exclusive to the Commercial-regulated overlay - it is a plain Commercial requirement for a user-facing service. Effort S. Keeps the posture of record honest, which POLICY.md itself sets out to be.
