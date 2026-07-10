---
title: "Dimension 6 - Security - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

REFUSE - one of the two prior refusal conditions has genuinely cleared and one has not. The STRIDE/ASVS threat model now exists (`docs/SECURITY.md`: all six STRIDE categories addressed over the real trust boundaries, the prior review's five named entries all present, ASVS L1 met/open status recorded, and `docs/POLICY.md` corrected), and every mechanical gate passes when run for real at this tag (secrets lint plus the newly-wired security-theme perlcritic gate 5/5; strict SBOM gate exit 0 with 214 components, `Net::XMPP` correctly declared). But the pentest gate remains structurally absent - no `project.yml`, no `pentest:` block, no `docs/pentest/`, and no waiver ADR - for a commercial operator-role posture the framework gates on "annual + on significant change". Worse, the prior review's specific complaint about unfired significant-change triggers has recurred: since 2026-07-01 the release line added a new dependency with authentication logic (Net::XMPP, SM136 - a trigger named verbatim in the framework), a new stored credential class (SM137 SMTP password), and new processing of visitor behavioural data (SM140), with no significant-change assessment recorded for any of them. The framework's letter is explicit that either a current report or an auditable waiver must exist; neither does.

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (working tree equals the tag; only this review directory untracked). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 6 detail and the penetration-testing gate (posture table, `pentest:` manifest block, refusal conditions, significant-change triggers). Prior review: `docs/review/2026-07-01-eight-dimension/dimension-6-security.md` and `90-prelaunch-operational-holds.md`. Commands run:

- `prove -l t/lint/03-secrets.t t/lint/05-perlcritic-security.t` - 5 tests, PASS, 22 s (the security-theme gate is new since the prior review).
- The SBOM strict gate exactly as `tools/release.sh` invokes it, output to scratch: `perl tools/build-manifest.pl --staged . --out /srv/tmp/sm-test/review-d56/m.json --version 0.6.10 --channel edge` (183 files, exit 0) then `perl tools/manifest-to-sbom.pl --strict --manifest ... --deps dist/config/sbom-deps.json --out /srv/tmp/sm-test/review-d56/s.json --version 0.6.10 --staged .` (214 components, exit 0). Nothing written into the repo.
- `command -v gitleaks` and `command -v debsecan` - both exit 1 (still not installed).
- Full suite green cited from `/srv/tmp/sm-test/rel610-suite.log` (`Files=162, Tests=2504 ... Result: PASS`); targeted re-runs of the new-surface tests: `t/integration/14-access-log.t`, `14-bad-url-blocker.t`, `13-write-failure.t`, `t/unit/lib/14-notify.t`, `t/unit/forms/05-smtp-validate.t` - all PASS.
- Read: `docs/SECURITY.md` (the threat model), root `SECURITY.md`, `docs/POLICY.md`, `docs/architecture/security.md`, `docs/adr/` (0001-0006, all dated 2026-07-02, none pentest-related), `dist/config/sbom-deps.json`.
- Source inspection of the new attack surface: `lib/Lazysite/Notify.pm` + `plugins/notify-xmpp.pl` (SM136), `plugins/form-smtp.pl` + the manager `plugin-action` dispatch (SM137), `lazysite-processor.pl` `_visitor_key`/`_access_field`/`_access_record` (SM140), the 0.6.7 `ls-layout-error` banner path, `lib/Lazysite/BadUrl.pm` + `lazysite-auth.pl` `_bad_url_guard` (SM128), `lazysite-dav.pl` `authorise`/`authorise_layout`, `lib/Lazysite/Manager/Plugins.pm` (credential read-back/save), `installers/hestia/lazysite-app.tpl`/`.stpl` (the `RequestHeader unset` lines ship in both vhost templates). System check: `XML::Stream` 1.24 installed - it verifies the TLS peer by default (`ssl_verify` 0x01, `Stream.pm` line 221).
- Absence greps: `pentest|penetration` outside `docs/review/`; `CVE|debsecan|vulnerab` over `tools/`, `Makefile`, `dist/`; `ls project.yml docs/pentest`.

## Findings

### F6.1 - STRIDE/ASVS threat model exists and is method-structured (FIXED, was REFUSE)

`docs/SECURITY.md` (new at 0.5.37) is the threat-model home the framework asks for: assets and five trust boundaries named; a STRIDE table with all six categories each carrying the top concrete threat, the control and its location, and the residual; the prior review's five priority entries all present and correctly stated (forged `X-Remote-*` headers with the two-signal trust gate and the vhost-strip obligation; hostile `layout.tt` as template execution with `EVAL_PERL=0` and the capability boundary honestly described as trust-by-design, not sandboxing; secrets under the docroot with the TOTP-at-rest L2 gap named; partner write-boundary bypass via the capability map and per-file ACLs; CGI-fork DoS with SM128 and the held capacity test). ASVS L1 is the declared verification companion with a met/open register. The controls it cites verify in code: `apply_trust_gate` strips the trust headers fail-closed (`lazysite-processor.pl` 727-752) and both Hestia vhost templates ship the `RequestHeader unset` lines. `docs/POLICY.md` no longer mis-files the threat model under the Commercial-regulated overlay. This clears the first refusal trigger per the framework's letter: the document is structured against the chosen method with each category addressed.

Currency gap: the model has not been refreshed for 0.6.2-0.6.9. Its asset list omits the two new credential classes (the SM136 XMPP client password, the SM137 SMTP password) and the new SM140 first-party access log; none of the STRIDE rows mentions them. The raw analysis exists in this report (F6.5-F6.7); folding it in is small. Classification: FIXED on the refusal condition; WARN on currency.

### F6.2 - Pentest gate still structurally absent; more triggers have fired unassessed (REFUSE, carried over)

No `project.yml`, no `pentest:` block, no `docs/pentest/`, and no waiver ADR (the ADR set is 0001-0006, none touching pentest or its deferral). The posture is unchanged: **commercial (operator role)** - operator-deployed, hosting customer sites - which the framework's table gates at annual cadence plus on significant change, scope application + infrastructure + hosting. The signoff verifies "`required: yes` present and the last-report within the cadence's window - or a waiver ADR present naming the reason ... or a documented deferral with expiry"; none of the three exists. The holds doc (item 6) defers the engagement to operators, but that note is not a waiver ADR, carries no expiry, and the declaration half was itself scoped there as effort S and not done.

The aggravating fact is recurrence. The prior review noted SM070/071/072 as unfired significant-change triggers; since then:

```datatable
columns: Change | Release | Framework trigger it matches
widths: 5.2cm | 1.8cm | X
bold: 1
tone: medium
text: 3
---
SM136 notify-xmpp: Net::XMPP client, per-site credential, outbound XMPP | 0.6.2 | "a new dependency with authentication logic" - named verbatim; also a new external (outbound) interface
SM137 SMTP password stored + staged connection validation | 0.6.3-0.6.4 | new stored credential class; authenticated outbound probes driven from the manager
SM140 first-party access log | 0.6.8-0.6.9 | new data classification processed (visitor behavioural records, anonymised at write)
SM128 bad-URL auto-blocker (default on) | 0.5.41 | new enforcement surface and persistent blocking state on the anonymous request path
```

The framework allows an assessment to waive re-test where a change is contained - but the assessment must be recorded and auditable, and none is. Classification: REFUSE - the second prior trigger stands, now with four more unassessed changes behind it.

### F6.3 - Mechanical gates: all green, one prior recommendation landed (PASS)

Secrets lint 3/3 and the new `t/lint/05-perlcritic-security.t` 2/2 (the prior review's recommendation 5 - the security theme is now an enforced gate, not a hand-run fact). Strict SBOM gate exit 0: 183 files, 214 CycloneDX components with per-file SHA-256 and SPDX licence ids. SBOM currency held through the new surface: `Net::XMPP` is declared in `dist/config/sbom-deps.json` with `debian_pkg`/`rhel_pkg`/`alpine_pkg` and an honest `used_by` note (lazy-required, optional) - the by-design property worked exactly as intended when SM136 added a dependency. Classification: PASS.

### F6.4 - CVE check and gitleaks: still absent (WARN, carried over)

Nothing in `tools/`, `Makefile` or `tools/release.sh` performs a CVE check against the declared dependencies, and neither `debsecan` nor `gitleaks` is installed - the holds doc's own item 5 marked these "unblocked earlier at zero risk by installing the two packages", nine days ago. The `debian_pkg` fields the check would key on are present for every non-core module (now including `libnet-xmpp-perl`). Classification: WARN - unchanged, and the cost of clearing it has been S since 2026-07-01.

### F6.5 - SM136 notify-xmpp: sound boundary, one credential-storage inconsistency (WARN)

Verified controls: the credential file `lazysite/notify-xmpp.conf` is unreachable over WebDAV (everything under `lazysite/` outside the layouts carve-out is denied for read and write - `lazysite-dav.pl` 1032-1034 routing into `authorise_layout`, which denies non-layouts paths at 1077-1080) and web-denied by the vhost; the manager read-back deletes password-typed fields (`Manager/Plugins.pm` 257-259) so the password is never shown again; a blank submission keeps the current password (the form only posts non-empty password inputs); `plugin-save`/`plugin-action` are absent from the token `%need` map, so the whole surface is cookie-only (manager). Egress is TLS-on by default and the installed `XML::Stream` 1.24 verifies the peer certificate by default; delivery is lazy-loaded, strictly best-effort and time-boxed (`alarm 15`), with notice text stripped of CR/LF before storage.

The finding: `notify-xmpp.conf` sits at the top of `lazysite/`, outside every permission-checked directory. Its sibling credential file `smtp.conf` lives under `lazysite/forms/`, which `lazysite-check` enforces at mode 02770 (group-confined); `notify-xmpp.conf` is written by `write_file_checked` with no `chmod` (so default CGI umask, typically world-readable) into a directory `lazysite-check` does not probe, and the checker has no entry for it. On a multi-user host the XMPP account password is likely readable by other local users. Small, real, and cheap to fix (F6.2's currency point applies too: this credential is in no threat-model asset list). A cosmetic sibling: the agent-facing `scope.deny` list in `whoami` (`lazysite-manager-api.pl` ~1259-1266) names `smtp.conf` and `handlers.conf` but not `notify-xmpp.conf` - enforcement covers it regardless, but the advertised list should match the boundary. Classification: WARN.

### F6.6 - SM137 SMTP password and validate action (PASS)

The password is stored in `lazysite/forms/smtp.conf` - operator-only, inside the 02770-checked directory, denied over WebDAV by name (`lazysite-dav.pl` 1020-1023) and never returned to the UI (same password-field strip as F6.5). `resolve_password` is shared by delivery and validation; `password_file` remains the fallback. The Validate action rides `plugin-action`, which is not in the token `%need` map - cookie-only, manager-gated. The staged check never sends mail, is time-boxed, and probes plain-first so a closed port is not misreported as TLS; it is pinned by `t/unit/forms/05-smtp-validate.t` (PASS). Residual worth one line in the threat model: validation is an operator-driven TCP connect to an arbitrary configured host:port - an SSRF-shaped primitive, acceptable at manager trust but worth recording. Classification: PASS.

### F6.7 - SM140 first-party access log: anonymise-at-write verified, one corner case (PASS with a gap)

The privacy claim holds in code and test: the visitor key is `hmac_sha256_hex("$ymd|$ip", site secret)` truncated to 16 hex chars - keyed, daily-salted, and the IP itself is never written (`lazysite-processor.pl` 4050-4063); log-injection defence strips control characters, caps length and JSON-escapes every attacker-controlled field (4067-4073); writes are single `O_APPEND` `syswrite`s below PIPE_BUF; retention prunes at 90 days by default; `first_party: off` disables; recording failure can never break serving. `t/integration/14-access-log.t` pins the key anonymisation, the sanitisation, the off switch and the prune (PASS). The 0.6.9 export layer reads the same files with a `source` field.

The gap: the HMAC key is `lazysite/auth/.secret`, which is minted by the auth wrapper. On a site that has never used auth the file may not exist, and `_visitor_key` silently proceeds with an empty key - at which point a day's keys are brute-forceable over the IPv4 space by anyone holding the log file, weakening "never reversible to the IP" exactly where the log is the only per-visitor artefact. Mint the secret on first record (or omit the `v` field when the secret is empty). Related exposure: `lazysite/logs` is expected at 02775 with 0664 files, so other local users can read the (anonymised) access log - acceptable given the anonymisation, but it makes the empty-secret corner matter more. Classification: PASS on the design and tests; the corner case feeds recommendation 5.

### F6.8 - 0.6.7 manager-layout error banner: correctly gated (PASS)

The loud `ls-layout-error` banner renders only when the failed layout is `$MANAGER_LAYOUT` (`lazysite/manager/layout.tt` - the manager-route layout, not resolvable by per-page layout overrides, which live under `lazysite/layouts/`), and manager routes are auth-gated by `handle_manager_path` before rendering. The TT error text is HTML-escaped before injection (`lazysite-processor.pl` 3558-3569). Public pages keep the silent fallback, so template error detail (paths, TT internals) is not exposed to visitors. Classification: PASS.

### F6.9 - SM128 bad-URL auto-blocker (PASS with notes)

Blocking is keyed on `REMOTE_ADDR` (`lazysite-auth.pl` 89), not on any client-suppliable header, so a third party cannot poison the blocklist against someone else's IP; the list/unblock actions are gated on `manage_config`; auto-blocks are audited. Two residuals for the threat model's DoS row (which already notes the auth-wrapped-sites scope): the store fails open (a corrupted counter file disables the blocker - consistent with the project's availability posture but worth recording), and on a deployment where a front proxy leaves `REMOTE_ADDR` as the proxy's address, threshold hits would block all visitors at once - a deployment note for non-Hestia fronts. Classification: PASS.

## Prior findings - disposition

```datatable
columns: Prior finding | Was | Now
widths: 7cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
F6.1 secrets gate green, gitleaks absent | WARN | WARN - unchanged; gitleaks still not installed
F6.2 strict SBOM gate | PASS | PASS - 214 components; Net::XMPP declared when added
F6.3 security perlcritic clean but ungated | PASS+gap | FIXED - now enforced as `t/lint/05-perlcritic-security.t`
F6.4 no CVE check | WARN | WARN - unchanged
F6.5 no STRIDE/ASVS threat model | REFUSE | FIXED - `docs/SECURITY.md`; currency gap for 0.6.x surface
F6.6 no pentest gate | REFUSE | REFUSE - unchanged, plus four more unassessed significant changes
```

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies.

1. **Declare the pentest gate now; the engagement can follow.** Add `project.yml` with the block shaped in the prior review (annual cadence; scope application + infrastructure + hosting; the four significant-change triggers; CREST-CRT/OSCP third party; remediation SLAs; retest for critical/high), and - since no report exists yet - the waiver ADR the framework's letter accepts: a documented deferral naming the reason (pre-launch, per the holds decision) with an explicit expiry tied to the launch date. Effort S for both artefacts; the first engagement remains L. This is the minimal set that clears the remaining refusal condition as written.
2. **Record significant-change assessments** for the backlog of fired triggers - SM070/071/072 (prior) and SM128/136/137/140 (this cycle) - one short auditable note each, stating contained/not-contained and why. Effort S. Satisfies "signoff records the significant-change assessment" and stops the recurrence pattern this review is the second to document.
3. **Refresh the threat model for the 0.6.x surface**: add the XMPP and SMTP credentials and the first-party access log to the asset list; extend the Information-disclosure and DoS rows with the F6.5-F6.9 residuals (notify-xmpp.conf placement, SSRF-shaped validate, blocker fail-open and proxy corner). Effort S - the analysis is in this report. Satisfies threat-model freshness.
4. **Harden `notify-xmpp.conf`**: either relocate it under a 02770-checked directory or `chmod 0660` after `write_file_checked`, add it to the `lazysite-check` credential-file probe set and to the agent-facing deny list in `whoami`. Effort S. Closes F6.5.
5. **Close the SM140 empty-secret corner**: mint `auth/.secret` on first access-record (or skip the `v` field while the secret is empty), and add the case to `t/integration/14-access-log.t`. Effort S. Keeps the anonymise-at-write claim unconditional.
6. **Install debsecan and gitleaks and wire the wrappers** (operator installs the two Debian packages; then a small release-path CVE check keyed off the `debian_pkg` fields, and a one-off full-history gitleaks sweep kept in the release path). Effort S each. Satisfies "CVE check against declared dependency versions" and "gitleaks host-wide" - both waiting since 2026-07-01 on a zero-risk unblock.
