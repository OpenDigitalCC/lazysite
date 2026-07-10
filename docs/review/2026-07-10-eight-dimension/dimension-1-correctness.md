---
title: "Dimension 1 - Correctness and groundedness - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

WARN - every mechanical gate is now in place, green and wired into the release path (compile sweep over 47 production files; full suite 162 files / 2,504 tests PASS at this tag), and all five prior Dimension 1 findings are verified fixed; but the encoding settlement that closed the prior headline finding stops one file short of its own claim: six security-relevant readers of `user-settings.json` in `lazysite-auth.pl` still use the `:utf8`-layer read that ADR 0001 declares "the bug, not the convention", empirically shown here to open the disabled/expired/MFA fail-open gates for every account the moment any non-ASCII character enters the file - and the committed secrets gate's private-key check has never actually run (an `invalid-test` inside a lint gate).

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (clean working tree, tag verified with `git describe --tags` and `git status`). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 1 detail (failure-mode catalogue and the three divergent-implementation review questions). Prior review: `docs/review/2026-07-01-eight-dimension/dimension-1-correctness.md` (v0.5.35); 35 releases have shipped since. Commands run:

- `prove -l t/lint/` - all six lint gates, 63 tests, PASS; `t/lint/04-compile.t` sweeps `perl -Ilib -c` over 47 production files (36 at the prior review).
- Full-suite evidence: `/srv/tmp/sm-test/rel610-suite.log` read and verified - `Files=162, Tests=2504 ... Result: PASS`, run 2026-07-10 at this tag (not re-run; heavy).
- Groundedness sampling of four recently shipped areas against their CHANGELOG/docs claims: SM136 notifications (0.6.2), SM138 `manager_groups` retirement + migration (0.6.5), SM140 first-party analytics (0.6.8–0.6.9), and the 0.6.5–0.6.7 field-fix round - each read at the implementation site and its pinning test.
- Repo-wide grep sweeps for each prior finding's symbol (`groups_grant_cap`, `_user_analytics`, `manager_groups` readers); `perl lazysite-processor.pl --describe` and `perl plugins/payment-demo.pl --describe` run live.
- A scripted sweep for `:utf8`-layer opens feeding `decode_json` within ten lines (scratch, 47 production files), and an empirical repro of the encoding failure mode against the exact reader shape in `lazysite-auth.pl`.
- A grep-based dead-code scan over all 694 defined subs (name occurring only at its definition, production + test trees).

## Prior findings - status

```datatable
columns: Prior finding | Status | Fix evidence
widths: 6cm | 2.2cm | X
bold: 2
tone: medium
text: 3
---
F1.2 no compile gate in the suite | FIXED | `t/lint/04-compile.t` (0.5.36), 47 files, green; unskippable at release via `release.sh`'s full `prove -r t/` in a fresh staging clone
F1.3 four-way capability read, utf8/octets split | FIXED (for the group-settings read) | Shared `groups_grant_cap` in `Auth::Settings`; `lazysite-auth.pl:27,988` and `Acl.pm:99–104` route through it; the processor's copy is marked and recorded in `docs/adr/0001-capability-resolution.md`; group-settings reads are `<:raw` everywhere. See F1.3 below for the residue the fix missed
F1.4 architecture docs contradict the code | FIXED | `docs/DEVELOPER.md:9` and `docs/architecture/code-quality.md:10–17` now state the shared-`lib/` reality with the module-free render-path exception (0.5.37)
F1.6 payment-demo lacks `--describe` | FIXED | Answers `--describe` with the uniform key set plus `demo: true`, before any `DOCUMENT_ROOT` check; the compile warning is gone (0.5.36)
F1.7 dead `_user_analytics` | FIXED | Repo-wide grep: zero occurrences (0.5.36)
```

## Findings

### F1.1 - Mechanical gates present, green and wired (PASS)

`t/lint/04-compile.t` runs `perl -Ilib -c` over the same 47-file production glob as the perlcritic gate; all pass. The gate is unskippable in the release path: `tools/release.sh` clones to a staging dir and runs the full `prove -r t/` (which includes `t/lint/`) before the bench, coverage and strict-SBOM gates - a compile failure refuses the release, exactly the by-design prevention the framework names for this dimension. The full-suite log at this tag (`/srv/tmp/sm-test/rel610-suite.log`) confirms 162 files / 2,504 tests, PASS.

### F1.2 - The prior divergent-implementation finding is resolved and ADR-recorded (PASS)

The prior review's headline (four capability readers against a "one implementation" spec, with a `:utf8`-versus-octets split) is closed the way the framework asks: `Lazysite::Auth::Settings::groups_grant_cap` is the shared request-context resolver; the login landing and the ACL operator bypass route through it; the processor keeps one deliberate module-free copy, marked at `lazysite-processor.pl:444–448` with a keep-in-sync instruction; and ADR 0001 records the split, the copies, and the octets decision. A semantic compare of the marked copies against the canonical subs found them in sync (same three-flag check in `_site_grants_manager`, same raw-octets read). The lazy `require Lazysite::Fetch` on the `.url` fetch path (`lazysite-processor.pl:1326–1338`) also carries an ADR 0001 reference, consistent with the deferred-LWP precedent.

### F1.3 - The octets settlement stops one file short of its own claim (WARN, plausible-but-wrong + divergent-implementation)

ADR 0001, decision 4: "JSON auth files are read as RAW OCTETS (`<:raw`) and decoded with `decode_json`, **everywhere** ... `:utf8`-layer reads are the bug, not the convention." CHANGELOG 0.5.36 repeats the claim ("JSON auth files are read as raw octets everywhere"). The canonical reader was duly converted - `Lazysite::Auth::Settings::read_settings` (`Settings.pm:142–160`) reads `user-settings.json` as `<:raw` with a comment citing the ADR. But `lazysite-auth.pl` keeps six private readers of the same file on the old pairing:

```datatable
columns: Line | Sub | Consequence when the decode dies
widths: 1.6cm | 4.2cm | X
bold: 2
tone: medium
text: 3
---
624 | `_resolve_account` | Password-reset identity resolution returns nothing
770 | `ui_enabled` | Fails open - interactive login allowed (documented)
794 | `account_disabled` | Fails open - a disabled account authenticates again
811 | `token_expired` | Fails open - an expired access token is accepted
828 | `account_expired` | Fails open - a time-boxed account outlives its expiry
844 | `mfa_enrolled` | Fails open - TOTP enrolment invisible, MFA step skipped
```

Empirical repro (scratch script, exact reader shape): `user-settings.json` written as the single writer writes it (`>:utf8`, character strings) with one non-ASCII character in one account's free-text field; the `<:utf8` + `decode_json` read dies (`malformed UTF-8 character in JSON string`), and `account_disabled` for an unrelated, ASCII-only account returns 0. The `<:raw` read of the same bytes decodes correctly and returns 1. Free-text `label`/`description` fields are stored verbatim (`tools/lazysite-users.pl:2314`), so one accented character supplied through normal account management opens every fail-open gate above for **all** accounts at once - silently, but for a WARN log line.

Applying the framework's review questions: a shared helper exists (`Settings::read_settings`), `lazysite-auth.pl` already imports `Lazysite::Auth::Settings`, and six adjacent private reads reinvent it with a material behavioural difference - the same `divergent-implementation` shape as the prior headline finding, one file over, and this time with no module-free excuse and no ADR cover (the ADR says the opposite). Classification: WARN - the code contradicts a recorded architectural decision and the CHANGELOG's stated claim; under the Commercial regime this must be resolved (routed through the shared reader, or at minimum re-paired to `<:raw` with a regression test) before the next signoff. Cross-referenced to the Dimension 6 assessor - four of the six gates are security controls that fail open together.

### F1.4 - The secrets gate's private-key check has never run (WARN, invalid-test)

`t/lint/03-secrets.t:23,30` passes the pattern `-----BEGIN [A-Z ]*PRIVATE KEY` to `git grep` positionally; git parses the leading `-` as an option and exits 129 with a usage error on stderr. The test reads only stdout, gets the empty string, and `is( $out, '', ... )` passes vacuously - observable in any `prove` run of the gate, where the git usage dump appears above a green result. The check has therefore asserted nothing since it was written; the other two checks (AKIA key ids, assigned secret literals) pass their patterns safely and do run. Run correctly by hand (`git grep -nIE -e '-----BEGIN [A-Z ]*PRIVATE KEY' ...` with the gate's own exclusions), the tree is clean - no violation ships, but the gate is a false assurance. Classification: WARN - the framework's `invalid-test` failure mode ("tests asserting only on mocks" has a sibling: tests asserting on the empty output of a command that failed to start), found inside a by-design gate. The fix is one `-e` flag plus a planted-fixture self-test.

### F1.5 - Groundedness samples match their claims (PASS)

SM136 notifications (0.6.2)
: `lib/Lazysite/Notify.pm` is the one shared write path the CHANGELOG claims - bell-store append to `logs/notices.jsonl`, then best-effort, time-boxed XMPP delivery only when the notify-xmpp plugin is enabled and configured, failure never propagating to the caller. The `notifications` capability exists in `Capabilities.pm:105–107`, and the manager API refuses the notices actions without it (`lazysite-manager-api.pl:471–474`, resolver at 1306–1311). Pinned by `t/unit/lib/14-notify.t` via the overridable `$XMPP_SENDER` hook.

SM138 `manager_groups` retirement (0.6.5)
: `_migrate_conf_manager_groups` (`tools/lazysite-users.pl:2159–2175`) runs on any settings read via `_ensure_groups_seeded`, materialises the full manager grant minus the remote `api`/`mcp` channels (SM127) for each conf-named group, then removes the conf line - exactly the "effective access is unchanged" claim. `whoami` derives from group settings (`_manager_groups_from_settings`, `lazysite-manager-api.pl:1290`); the processor's config descriptor no longer lists the key (verified by running `--describe`: zero occurrences); the unsecured-mode signal is `site_grants_manager` (`Settings.pm:118–126`) with the processor's marked module-free copy; `UPGRADE.md` documents the migration.

SM140 first-party analytics (0.6.8–0.6.9)
: the recorder (`lazysite-processor.pl:4027–4128`) matches every CHANGELOG property: daily-salted HMAC visitor key from the site secret, never the IP (`_visitor_key`); control-character stripping and length caps on attacker-controlled fields (`_access_field`); a single `O_APPEND` `syswrite` below `PIPE_BUF`; daily files with filename-dated retention pruning (default 90 days, floor 1); `first_party: off` honoured; recording failure never breaks serving. The stats plugin reads first-party as the primary source with the server log as fallback and a `source` field saying which (`plugins/stats.pl:481–484, 456, 582`); the 0.6.9 increment converts the AI export via `_export_ingest_first_party` into the same day-bucket cache. The 0.6.8 bonus claim (unhandled processor error answers a clean 500) is at `lazysite-processor.pl:656–664`. Pinned end-to-end by `t/integration/14-access-log.t`.

0.6.5–0.6.7 field-fix round
: the 0.6.6 ownership repair is genuinely scoped - `install.pl:958` repairs only root-owned paths and uses the web-server group (`getgrnam 'www-data'`), with the 0.6.5 regression explained in the comment block above it. The 0.6.7 TT fix retries a failed render once with `COMPILE_DIR`/`COMPILE_EXT` deleted (`lazysite-processor.pl:3081–3097`), shows the loud `ls-layout-error` banner only on auth-gated manager pages (3562), and `lazysite-check.pl:243–267` carries the cache/tt writability probe with the `--fix` removal. Pinned by `t/integration/13-layout-compile-cache.t`, whose header records the field incident.

### F1.6 - The divergence record is drifting behind the code (WARN, low)

ADR 0001 records "one recorded local copy" in the processor; SM138 added a second (`_site_grants_manager`, `lazysite-processor.pl:465–480`), correctly marked with an ADR 0001 reference - but the ADR itself was not updated, and `docs/architecture/code-quality.md:16` still says "its **single** duplicated helper". The framework's protection only works if the record enumerates the copies a future refactor must keep in sync. Classification: WARN, low - the discipline was followed at the code site and missed at the record.

### F1.7 - SM138 sweep residue (WARN, low)

Three small leftovers from the retirement, each the class of residue that misleads a future change:

- `docs/architecture/security.md:139–147` (and the aside at 462) still documents the retired `manager_groups:` conf-key model as the manager-access rule; `docs/FEATURES.md:398` carries the current model. Shared with the Dimension 7 assessor.
- `tools/lazysite-users.pl:2056–2059` (`read_manager_groups`) and 2191–2198 (`manager_groups_effective`) still union the legacy conf key with comments claiming "Phase 1 keeps both working" / "the seed/fallback" - retired semantics; post-migration the union is a no-op, and the only consumer is the `is_last_manager_ui` safety check.
- `_has_settings_entry` (`tools/lazysite-users.pl:2176`) is defined and never called anywhere (scan over 694 subs; sole single-occurrence hit), orphaned in the SM138 commit `f3a712a` - the same class as the prior review's `_user_analytics`.

## Recommendations

1. Close the encoding residue (F1.3): route the six `lazysite-auth.pl` readers of `user-settings.json` through `Lazysite::Auth::Settings` (the module is already imported; `read_settings` plus thin accessors covers all six), or at minimum switch each open to `<:raw`; add a non-ASCII regression test mirroring the group-settings one from 0.5.36, asserting `account_disabled`/`token_expired`/`mfa_enrolled` still hold with an accented character in an unrelated account's field. Effort S. Clears the standing contradiction of ADR 0001 the Commercial signoff would otherwise refuse on, and closes four fail-open security gates.
2. Fix the secrets gate (F1.4): pass every pattern via `-e`, and add a planted-fixture self-test (a temp file containing a fake key header) proving each check can fail. Effort S. Converts a false assurance back into a gate.
3. Update ADR 0001 and `docs/architecture/code-quality.md:16` to enumerate both processor copies (`_groups_grant_cap`, `_site_grants_manager`) as the recorded divergence set (F1.6). Effort S.
4. Sweep the SM138 residue (F1.7): rewrite the manager-access section of `docs/architecture/security.md` to the groups-only model; drop the legacy conf union and Phase-1 comments in `tools/lazysite-users.pl`; delete `_has_settings_entry`. Effort S.
