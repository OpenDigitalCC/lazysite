# Dimension 1 - Correctness and groundedness - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: REFUSE (2026-08-14, at 0.10.8)

## Verdict

**PASS**. The defect that refused 0.10.8 is fixed, and the fix is verified in
the source, by a regression test that fails without it, and - for the related
SM299 - on the deployed service.

## Findings

### F1.1 - SM296 closed (was REFUSE)

`lib/Lazysite/Private.pm` no longer calls `make_path` directly. `_mkpath`
captures the error and returns, and `make_path` is not imported into the module
at all, because an unqualified call is how the defect happened.

The regression test blocks the store deterministically by putting a file where
its directory must be - no `chmod`, so it behaves identically for an
unprivileged user and for root - and asserts the warning, the stored rule and
the untouched content together, since the fix is only correct if all three hold
at once.

**Verified as fixed, not assumed:** the previous review's finding is reproduced
against the tag and no longer present.

### F1.2 - The suite passes on a clean checkout (was D3 F3.1)

365 files, 7400 tests, `Result: PASS`, run from a fresh worktree of the tag.
That is the configuration in which 0.10.8 failed. Detail under D3.

### F1.3 - SM299 verified on the running service

The `llms.txt` template appended `.md` to a page URL, producing `<dir>/.md` for
an index page. Measured on the deployed host after upgrade: dead links across
the whole registry went from **3 to 0**, and the page the filing itself cited as
lazysite's own instance now resolves correctly as `/docs/integrations/index.md`.

This is the first finding in the review series closed by measuring the deployed
service rather than the tree, which is the stronger claim.

### F1.4 - Prior findings verified

| Prior finding | State at this tag |
|---|---|
| F1.1 croaking `make_path` | Fixed, regression test present |
| F1.2 defect class being caught by the project | Continues - the release gate caught a defect in itself this cycle |
| F1.3 module-free copies pinned by behaviour | Unchanged and still pinned; `t/lint/42` added for the routing table |

## Evidence

- `prove -lr t/` on a clean worktree of `f8bee33`: 365 files, 7400 tests, PASS.
- `lib/Lazysite/Private.pm` - `_mkpath` at :211, called at :250.
- `curl https://edge.explore.lazysite.io/llms.txt` - zero `/.md` occurrences.
