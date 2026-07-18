# Dimension 1 - Correctness and groundedness - lazysite eight-dimension review

---
title: "Dimension 1 - Correctness and groundedness - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 2026-07-18, Commercial regime, 0.8.0-stable candidate"
brand: plain
---

## Verdict

PASS - every mechanical gate for this dimension is present, green and wired into
the release path (the `perl -Ilib -c` compile sweep now runs over the full
production glob; the full suite is 4,179 tests / 232 files, PASS at this tag);
both open findings the prior review's WARN rested on are verified FIXED (the six
fail-open `user-settings.json` readers are now `<:raw` octets with a dedicated
non-ASCII regression test; the secrets gate's private-key check runs via `-e` and
now carries planted-fixture self-tests); and the large body of new work since
0.7.0 (SM179 multilingual, SM165 domain access, SM175 rename-following history,
the conf-mtime cache invalidation) is well-grounded, fails closed, and matches
its CHANGELOG claims at the implementation sites sampled. The residual findings
are low-severity documentation-of-divergence drift (ADR 0001's title and one
architecture-doc phrase still say "one recorded copy"; one orphaned sub and a
retired-semantics comment persist), each S-effort and none masking a shipped
defect - so the Commercial regime carries no refusal condition here.

## Method

Assessed at tag `v0.7.28`, commit `6780878` (`git describe --tags` = `v0.7.28`;
tree matches HEAD). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`,
Dimension 1 detail (the failure-mode catalogue and the three
divergent-implementation review questions). Prior review:
`docs/review/2026-07-10-eight-dimension/dimension-1-correctness.md` (v0.6.10);
its two WARNs and three low residues were re-checked against the code, not
assumed. Commands and reads:

- `prove -l t/lint/` - all twelve lint gates (six at the prior review), 323
  tests, PASS. `t/lint/04-compile.t` sweeps `perl -Ilib -c` over the full
  production glob (`*.pl`, `tools/*.pl`, `plugins/*.pl`, `lib/Lazysite/**/*.pm`).
- Full-suite evidence cited from the mechanical gate line already green at this
  tag: `prove -lr t/` = 4,179 tests / 232 files PASS (not re-run; heavy).
- F1.3 verification: grep of every `user-settings.json` open in `lazysite-auth.pl`
  (`grep -n "user-settings.json\|<:utf8\|<:raw" lazysite-auth.pl`); each of the
  six readers read and confirmed `<:raw`; the pinning test
  `t/unit/auth/11-non-ascii-settings.t` read.
- F1.4 verification: `t/lint/03-secrets.t` read in full - `-e` flag present,
  planted-fixture self-tests present.
- New-work groundedness sampling against CHANGELOG 0.7.1-0.7.28: `Lazysite::Lang`,
  `Lazysite::I18n`, `Lazysite::Auth::DomainAccess`, `Lazysite::Git` read in full;
  the processor's `try_serve_cache` / `is_fresh` / `resolve_site_vars` and the
  404 fallback read at the implementation sites.
- `perlcritic --profile .perlcriticrc --severity 3` over the seven principal new
  / heavily-changed modules: 0 violations (shared with Dimension 2).
- Residue re-checks: `_has_settings_entry` caller grep; ADR 0001 title/body grep;
  "Phase 1 keeps both working" comment grep.

## Prior findings - status

```datatable
columns: Prior finding | Status | Fix evidence
widths: 6cm | 2.2cm | X
bold: 2
tone: medium
text: 3
---
F1.3 six `:utf8` fail-open readers of `user-settings.json` in `lazysite-auth.pl` | FIXED | All six readers (`_resolve_account` 669, `account_disabled` 890, `token_expired` 907, `account_expired` 924, `mfa_enrolled` 940, and the `ui_enabled` 866) now `open ... '<:raw'`; a header comment at 666-668 records the reason ("a `:utf8` handle made it die on any non-ASCII byte"). Regression test `t/unit/auth/11-non-ascii-settings.t` pins that a disabled account stays disabled with non-ASCII in the settings file
F1.4 secrets gate private-key check never ran (`invalid-test`) | FIXED | `t/lint/03-secrets.t` passes every pattern via `-e`; a `%plant` block writes a planted fixture per pattern and `isnt($out, '', ...)` self-tests that each check CAN fire before trusting its silence - the exact fix the prior review recommended
F1.6 ADR 0001 lists "one recorded copy" but two exist | OPEN (low) | `docs/adr/0001-capability-resolution.md:1` title still reads "one shared helper, one recorded local copy"; `docs/architecture/code-quality.md:16` still says "its single duplicated helper". The second processor copy (`_site_grants_manager`) remains unenumerated in the record
F1.7 SM138 sweep residue | PARTLY OPEN (low) | `_has_settings_entry` (`tools/lazysite-users.pl:2509`) is still defined and never called (caller grep: zero hits outside its own definition); the "Phase 1 keeps both working" legacy-conf-union comment persists (`tools/lazysite-users.pl:2523`, `manager_groups_effective`). The docs half was addressed and is now mechanically guarded - see F1.8
```

## Findings

### F1.1 - Mechanical gates present, green, wired, and broadened (PASS)

The compile gate (`t/lint/04-compile.t:14`) globs the full production surface -
`*.pl`, `tools/*.pl`, `plugins/*.pl`, `lib/Lazysite/*.pm`, `lib/Lazysite/*/*.pm` -
so every new SM179 / SM165 / SM175 module (`Lang.pm`, `I18n.pm`,
`Auth/DomainAccess.pm`, `Git.pm`, the new `Manager/*` and `tools/*.pl`) is under
`perl -Ilib -c`. The lint suite is now twelve gates (six at the prior review):
the new `07-shellcheck.t` closes the prior Dimension 2 F2.5 gap, and
`08-retired-terms.t` operationalises the prior review's documentation-currency
finding (see F1.8). The full suite (4,179 tests / 232 files) is green at this tag,
and `tools/release.sh` runs the whole `prove -r t/` in a fresh staging clone
before the bench, coverage and strict-SBOM gates - a compile or gate failure
refuses the release, the by-design prevention the framework names for this
dimension.

### F1.2 - The prior headline (octets settlement) is now complete (PASS)

The prior review's WARN rested on `lazysite-auth.pl` keeping six private readers
of `user-settings.json` on the `<:utf8` + `decode_json` pairing that ADR 0001
declares "the bug, not the convention" - a fail-open path where one accented
character in any account's free-text field silently disabled the
disabled/expired/MFA gates for every account. Verified fixed: every one of the
six now reads `<:raw` (669, 866, 890, 907, 924, 940), with the reason recorded
inline at 666-668, and `t/unit/auth/11-non-ascii-settings.t` pins the fixed
behaviour end-to-end (a disabled account stays disabled when the settings file
contains non-ASCII). The remaining `<:utf8` opens in the file (842 `load_users`,
1057 `load_user_groups`, 1113/1126 `update_user_hash`, 1170 `read_conf_key`) read
the line-oriented `users` / `groups` / `lazysite.conf` files, not `decode_json`
input, so they are outside the F1.3 fail-open class and correctly left alone. The
standing ADR-0001 contradiction the Commercial signoff would have refused on is
cleared.

### F1.3 - The secrets gate now actually asserts, and self-tests (PASS)

`t/lint/03-secrets.t` builds each pattern into a `git grep ... -e $pattern`
invocation (the `-e` the prior review asked for, so a leading `-` in the
private-key pattern is a pattern not an option), and a `%plant` block writes one
fixture per check into a temp dir and asserts `isnt($out, '', ...)` that each
check detects it before the real scan runs. The false-assurance `invalid-test`
the prior review found inside a by-design gate is converted into a demonstrated
gate. Runs green in the suite.

### F1.4 - New multilingual layer is grounded and fails closed (PASS)

`Lazysite::I18n` (engine-chrome localisation, SM179 P8) is the correctness-critical
new surface because it sits on the auth-reject and 404 paths. It fails closed to
English on every miss (unknown language, missing key, unreadable/invalid JSON,
empty translation - `chrome_string`, 66-80), the language never affects an auth
DECISION (only display text; documented HARD SAFETY LINE, 14-16), interpolated
arguments are HTML-escaped (`_esc`, 82-90), and the override-file lookup validates
the lang code against `^[A-Za-z][A-Za-z-]*$` before it can name a path
(`_overlay`, 44) - no traversal. The reflected-markup fix the CHANGELOG claims for
the bare-404 path is real: `lazysite-processor.pl:4963` routes the request URI
through `_chrome('notfound.body', $uri)`, and `chrome_string` HTML-escapes the
`%s` argument. `Lazysite::Lang` (set membership + coverage) holds its declared
READ-ONLY scope (never writes conf, never moves content, 11-13), computes a set
only when it has >=2 members (`set_members`, 79), and its `_parse_conf` bare-key
regex `^(\w+)\h*:` cannot match a dotted `alias.<host>.<key>` line, so alias
overrides never leak into base vars - matching the same guarantee the processor's
`resolve_site_vars` documents. `translated_from` content-hash staleness falls back
to mtime cleanly (`_file_status`, 210-222).

### F1.5 - The conf-mtime cache invalidation is correct under any process model (PASS)

The CHANGELOG's headline correctness claim for 0.7.28 - a conf-only edit now
invalidates the page cache, so a stale `Content-Language: en` render on a host the
conf has since switched no longer survives - is verified at the code. Freshness
is gated on the cached HTML post-dating BOTH its `.md` source AND the conf mtime,
on both the normal path (`try_serve_cache`, `lazysite-processor.pl:1074`:
`$html_stat->[9] >= $md_stat->[9] && $html_stat->[9] >= $conf_mtime`) and the
page-TTL path (1087-1089, `&& $html_stat->[9] >= $conf_mtime`), and equally in
`is_fresh` (1912-1921, the 404.md render path: `return $h >= (stat $CONF_FILE)[9]`).
Because the check is on file mtimes, not on a process's remembered value, it holds
identically under one-shot CGI and a persistent FastCGI worker - the property the
CHANGELOG claims. `resolve_site_vars` is additionally self-invalidating: it keys
its memo on `(conf mtime, request host)` (3249-3251), so a conf edit or a
different host re-resolves even if a runner never calls `reset_request_state` - a
sound belt-and-suspenders backstop, not a load-bearing single point.

### F1.6 - Rename-following history follows identity, not path (PASS)

`Lazysite::Git` (SM175) is the highest-risk new correctness surface (git
invocation on attacker-influenced paths and messages, plus a history-privacy
contract). It is well-grounded: all git calls are list-form with no shell
(`run_git`, 115-131), SHAs are validated `\A[0-9a-f]{7,40}\z` and paths validated
against NUL / absolute / option-shaped / `.`/`..` segments before any git call
(`_valid_sha` 70, `_valid_rel` 74-82), the never-versioned exclude list is the
documented security boundary keeping auth/forms/tokens/logs out of a pushable
history (143-159), and every write hook is eval-guarded to no-op when the feature
is off. The rename walk (`file_log`, 335-386) deliberately does NOT use git's
`--follow` heuristic - it walks back to each incarnation's add commit
(`--diff-filter=A`) and continues into a prior path only when that commit carries
an explicit `Lazysite-Renamed-From` trailer, so a delete genuinely ends the thread
and a later file reusing the path starts clean (the privacy claim). Edge cases are
handled: a `%seen` cycle guard against a pathological trailer loop (346-347), and
a limit cut-off mid-incarnation stops rather than jumping lineage
(`last unless $reached_add`, 371). This is careful, correct code.

### F1.7 - Domain access model is fail-safe (PASS)

`Lazysite::Auth::DomainAccess` (SM165) resolves content-root confinement from
domain records. Its correctness-critical property - a locked user whose lock
excludes every domain they may manage must be confined to nothing, never silently
unconfined - is met by a `DENY_ALL_SCOPE` sentinel (a string no real path can
match, 21) returned wherever an effective set is empty for a locked user
(`effective_scopes`, 137-138; `intersect_scopes` disjoint case, 63). The
sub-user ceiling (`intersect_scopes`, 44-64) keeps the tighter of two overlapping
scopes and yields deny-all on disjoint sets, so a created account can never
out-reach its creator. A non-default domain with an empty allow-list is
operator-only (no group reaches it, 120); only a general editor with no lock and
no allow-entry gets the empty (unconfined) list, as intended. The empty-list =
unconfined convention is the one sharp edge, but it is documented at every return
site and guarded by the deny-all sentinel for the locked case - the failure mode
is fail-closed.

### F1.8 - The documentation-currency failure mode is now mechanically gated (PASS, notable)

The prior D1/D7 finding (retired-mechanism terms taught as current in docs) is
answered with the by-design prevention pattern the framework asks for:
`t/lint/08-retired-terms.t` fails the build when a retired term (`manager_groups`)
appears in a `.md` outside the historical allowlist without a
retired/legacy/migration marker. This converts a recurring manual-sweep finding
into an unshippable one. Note the gate excludes `*.pl`/`*.pm`/`t/*`, so it does
not cover the code-comment residue in F1.9 - a deliberate scoping (it is a doc
gate), correct as far as it goes.

### F1.9 - Divergence-record drift persists (WARN, low)

Two low residues carried over from the prior review remain, each the class that
misleads a future refactor rather than a shipped defect:

- ADR 0001's title and body still say "one recorded local copy"
  (`docs/adr/0001-capability-resolution.md:1`) and
  `docs/architecture/code-quality.md:16` still says "its single duplicated
  helper", but the processor carries two marked copies
  (`_groups_grant_cap` and the SM138 `_site_grants_manager`). The framework's
  guardrail only works if the record enumerates every copy a future refactor must
  keep in sync. Effort S. (F1.6 prior.)
- `_has_settings_entry` (`tools/lazysite-users.pl:2509`) is still defined and
  never called (caller grep: zero hits) - orphaned since SM138, the same class as
  the prior review's `_user_analytics`. The "Phase 1 keeps both working"
  legacy-conf-union comment persists in `manager_groups_effective`
  (`tools/lazysite-users.pl:2523`) with the union now a post-migration no-op.
  Effort S. (F1.7 prior.)

Classification WARN, low: neither changes runtime behaviour; both are the
divergence-record hygiene the Commercial regime wants kept current but does not
refuse a release over.

## Recommendations

1. Update ADR 0001's title and body and `docs/architecture/code-quality.md:16` to
   enumerate both processor copies (`_groups_grant_cap`, `_site_grants_manager`)
   as the recorded divergence set (F1.9). Effort S. Restores the guardrail the
   record is supposed to be.
2. Delete the orphaned `_has_settings_entry` and the "Phase 1 keeps both working"
   legacy-conf-union comment in `tools/lazysite-users.pl` (F1.9). Effort S. Clears
   the last SM138 sweep residue.
3. Consider extending `08-retired-terms.t` (or a sibling) to scan code comments
   for retired-mechanism terms, so a stranded legacy comment like the
   `manager_groups` Phase-1 note is caught mechanically the way the doc terms now
   are. Effort S. Optional hardening - promotes F1.9's second half into the
   by-design pattern.
