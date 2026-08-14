# Dimension 3 - Test coverage - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-07-18)

## Verdict

**WARN**. The suite is large, disciplined and genuinely load-bearing - it has
caught several of this period's defects before a user did, which is the only
real measure of a test suite. Coverage floors are enforced and met.

One finding stops this being a clean pass, and it is a reproducibility problem
rather than a coverage one: **the suite does not pass on a clean checkout of the
released tag** (F3.1). Fifteen test files invoke `install.pl`, which requires
`release-manifest.json` - a gitignored build artefact. On a developer's working
copy that file is lying around from the last build and everything passes; in a
fresh clone or worktree of `v0.10.8`, it is absent and those tests fail. The
release gate has never noticed because the gate runs where the artefact exists.

## Method

- Ran the full suite on a **clean worktree** of the tag rather than in the
  working copy. This was not a deliberate experiment - it is how the audit was
  set up, and it is the reason the finding surfaced at all.
- Reproduced the failure to root cause rather than accepting the symptom.
- Ran `tools/coverage.sh --check` against the declared floors.
- Read the lint suite's growth and its shape.

## Findings

### F3.1 - The suite passes only where an untracked build artefact happens to exist (WARN, new)

Full suite on a clean worktree of `v0.10.8`:

```
Files=356, Tests=7325 ... Result: FAIL
t/tools/38-migrate-engine-tree.t  (Wstat: 512 (exited 2) Tests: 7 Failed: 2)
```

The same file in the primary working copy at the same commit:

```
t/tools/38-migrate-engine-tree.t .. ok
Result: PASS
```

Root cause, reproduced directly:

```
$ perl /srv/projects/lazysite-audit/install.pl --docroot ... --cgibin ...
release-manifest.json not found at /srv/projects/lazysite-audit/release-manifest.json

$ git ls-files release-manifest.json | wc -l
0
$ git check-ignore -v release-manifest.json
.gitignore:42:release-manifest.json     release-manifest.json
```

`release-manifest.json` is generated at build time and gitignored. `install.pl`
requires it. **Fifteen test files invoke `install.pl`**, so the exposure is
wider than the two subtests that happened to fail here - those two failed
because they check the *result* of the install; others may be tolerating a
failed install more quietly.

Why this matters beyond tidiness:

- The suite's result depends on **untracked state in the developer's working
  directory**. That is the same class as the fixture-agrees-with-the-reader
  problem this project has already named for itself - the test and the thing it
  depends on are both under the author's hand, so agreement proves nothing.
- Anyone who clones at `v0.10.8` and runs the suite - a reviewer, a CI runner, a
  contributor, an auditor - gets failures on a released tag.
- It also means the release gate cannot distinguish "the installer works" from
  "the installer works given a manifest from a previous build".

Remedy options, in preference order: have `install.pl` generate the manifest when
absent (or the test fixture generate one); or have the affected tests build it
via `tools/build-manifest.pl`, which already exists and is tested by
`t/tools/01`; or, weakest, skip with an explicit reason so the gap is visible
rather than silent. A `skip` is the least good because it would hide the
installer from the suite entirely on clean checkouts.

### F3.2 - Coverage floors are declared, enforced and fail-closed (PASS)

`tools/coverage.sh --check` on the audited tree, full suite under Devel::Cover
with subprocess CGIs instrumented - `rc=0`:

| Surface | Statements | Branches | Floors |
|---|---:|---:|---|
| `lazysite-oauth.pl` | 99.4% | 94.8% | 75 / 62 |
| `lazysite-dav.pl` | 93.5% | 74.5% | 75 / 62 |
| `tools/lazysite-users.pl` | 91.9% | 74.8% | 75 / 62 |
| `lazysite-mcp.pl` | 90.9% | 65.4% | 75 / 60 |
| `tools/lazysite-bundle-apply.pl` | 89.8% | 65.0% | 75 / 62 |
| `lazysite-processor.pl` | 88.4% | 73.1% | 75 / 62 |
| `lazysite-auth.pl` | 82.5% | 64.6% | 75 / 60 |
| `lazysite-manager-api.pl` | 80.8% | 65.6% | 75 / 60 |

Every measured production CGI clears both floors. The floors are also
**fail-closed** - an unmeasured file fails rather than passing silently, which
is the property that matters more than any individual number.

**The three branch-floor overrides are now unnecessary and should be retired.**
`dist/config/coverage-floor` holds `lazysite-manager-api.pl`,
`lazysite-auth.pl` and `lazysite-mcp.pl` at 60 rather than the general 62,
because at the v0.6.10 measurement they cleared 62 by less than the documented
run-to-run variance. They now measure **65.6, 64.6 and 65.4** - between 2.6 and
3.4 points clear of 62. The file states its own retirement condition ("remove
these overrides when ... targeted branch tests lift them clear of 62+variance")
and that condition is met. Ratcheting them away is the file's own instruction
and costs nothing.

`dist/config/coverage-floor` declares 75% statements and 62% branches per
cleanly-measured production CGI, with three documented per-file branch overrides
at 60 (`lazysite-manager-api.pl`, `lazysite-auth.pl`, `lazysite-mcp.pl`), each
justified in the file by measurement variance rather than by convenience, and
each annotated "never lower the others".

That file is a model of how a threshold should be recorded: it states the
baseline measurements, the date and review that set them, the reason for every
override, the condition under which an override may be relaxed further, and the
instruction to ratchet upward only. The statement floor **is** the Commercial
floor, met by enforcement rather than by luck.

### F3.3 - The lint suite has become the project's strongest asset (PASS, noted)

41 lint files at the audited tree, up from 12 at the 0.8.0 gate. More
importantly, their *shape* has changed. The best of them do not match text; they
drive two implementations and compare answers (`t/lint/35`, `t/lint/37`), start a
real nginx and parse shipped configs (`t/lint/34`), or assert that a hand-kept
list matches the filesystem (`t/lint/31`, `t/lint/41`).

The project has now found the same defect - **a hand-maintained list that
silently went stale** - four separate times, and each time converted it into a
derived list. That is the correct response and it is visibly working.

### F3.4 - Tests that were shown to fail first (PASS, noted)

Spot-checked several of this period's security and behaviour tests for evidence
that they were demonstrated failing against unfixed code before being accepted -
`t/lint/33` was verified failing both with the templates absent and with the ACL
branch stripped while the header stayed; `t/integration/42` was verified by
breaking the template five ways. That practice is the difference between a test
and a comment, and it is being followed.

### F3.5 - The deferred D3/D4 item from July is still open (WARN, carried)

"`lang_status`'s content walk unbenchmarked; retain a release-suite log before
the cut" was deferred at the 0.8.0 gate and has not been done.

## Evidence

- `prove -lr t/` on a clean worktree of `ec6fe0a`: 356 files, 7325 tests, FAIL.
- `install.pl` error output, reproduced above.
- `git check-ignore -v release-manifest.json`.
- `dist/config/coverage-floor`.
