# Dimension 3 - Test coverage - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: WARN (2026-08-14, at 0.10.8)

## Verdict

**PASS**. The finding that held this dimension at WARN is closed and verified in
the configuration that exposed it: a clean checkout of the released tag now
passes its own suite.

## Findings

### F3.1 - A clean checkout passes (was WARN)

```
$ prove -lr t/          # fresh worktree of v0.10.9
Files=365, Tests=7400 ... Result: PASS
```

At 0.10.8 the same invocation failed, because fifteen test files invoke
`install.pl`, which required `release-manifest.json` - a gitignored build
artefact present in a developer's working copy and absent from a clone.

Both readers now derive the manifest when it is missing, to a temp path so the
checkout stays clean, and only when the builder and the classification map are
both present - which is the condition distinguishing a source checkout from a
broken tarball, where dying remains correct.

**This closed D6 F6.6 in the same change**: the strict SBOM gate needed the same
artefact, so a released tag could not run the CRA control that substantiates its
own SBOM claim. It now can - `manifest-to-sbom.pl --strict` returns rc 0 from a
clean worktree.

### F3.2 - Coverage floors enforced and met (PASS)

`dist/config/coverage-floor` continues to declare 75% statements and 62%
branches per cleanly-measured production CGI, fail-closed so an unmeasured file
fails rather than passing.

Met at this tag. The release gate's own instrumented run on `f8bee33` reported:

```
coverage: all measured production CGIs at or above 75% statements /
          62% branches (target 75%)
```

Cited from the release gate rather than re-measured here, because that run was
against this exact commit and a second full Devel::Cover pass would add nothing
but an hour of CPU.

The retirement recommendation from the previous review is unactioned: the three
per-file branch overrides held at 60 measured 64.6-65.6 at 0.10.8, clearing the
62 general floor by more than the documented variance, and the file states its
own condition for removing them. Carried, build-side.

### F3.3 - The release gate was testing in an unsupported configuration (closed)

Assessed here because it is a test-discipline finding. The gate ran
`prove -r "$STAGE/t/"` with no `-l`, so `PERL5LIB` was never exported and
subprocess-spawning tests lost the library path. Five files failed; they fail
identically at v0.10.8.

Two things follow for this dimension. First, "the suite passed in the gate" was
a weaker claim than it appeared for at least one release. Second, the repair had
a trap - `-l` resolves relative to the working directory, so adding it without
also running from the staging clone would have tested the developer's library
against the candidate's tests, and passed.

Fixed as `cd "$STAGE" && prove -lr t/`.

### F3.4 - An intermittent failure was deterministic (closed)

`t/tools/03-install-pl.t` had been recorded as intermittently failing. It failed
whenever a stale `release-manifest.json` was present and passed when it was not.
`repo_manifest_guard`'s contract is now "a manifest that describes this tree"
rather than "a manifest exists", and `t/lib/FlakeLog.pm` records outcomes with
the harness-versus-standalone context that discriminated this case.

### F3.5 - `lang_status` remains unbenchmarked (WARN, carried to D4)

Carried since 2026-07-18 and still not done. Recorded under D4 with the other
measurement gaps.

## Evidence

- `prove -lr t/` on a clean worktree of `f8bee33`: 365 files, 7400 tests, PASS.
- `perl tools/manifest-to-sbom.pl --strict` on the same worktree: rc 0.
