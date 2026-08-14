# Dimension 2 - Code quality - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-07-18)

## Verdict

**PASS**, with one structural pressure recorded rather than charged as a defect
(F2.1). The mechanical gates are clean, the lint suite has more than tripled
since the 0.8.0 gate, and the *kind* of lint the project writes has improved -
from matching text to driving two implementations and comparing their answers.

## Method

- `perlcritic --profile .perlcriticrc --severity 3` across every CGI, `lib/` and
  `tools/`.
- Established what the project's tidy gate actually requires before assessing
  against it - see F2.2, which is a note about the audit rather than the code.
- Measured the growth of the render path across releases, because ADR 0001
  concentrates complexity there by design and that pressure is worth tracking.

## Findings

### F2.1 - The processor is 6,323 lines and carries eleven module-free copies (noted, not charged)

ADR 0001 keeps Lazysite modules out of the render path, so anything the
processor needs it must carry itself. That is a deliberate and defensible trade
- it is why the render path is fast and why it has no load-order surprises - but
it has a cost that compounds, and the cost is now visible:

| Tag | `lazysite-processor.pl` | Perl files |
|---|---|---|
| v0.7.0 | 4,151 | 49 |
| v0.8.0 | 5,178 | 68 |
| v0.9.10 | 5,139 | 68 |
| v0.10.0 | 5,355 | 69 |
| v0.10.8 | 6,323 | 75 |

A 52% growth in the single file that is hardest to test in isolation and most
expensive to get wrong. This is **not** charged as a defect, for a specific
reason: every duplicated decision in that file is now pinned by a lint that
drives both copies and compares the answers (`t/lint/35` group resolution,
`t/lint/37` engine-dir resolution, and `t/lint/42` on the pending SM294 branch).
Duplication that cannot silently diverge is a different thing from duplication.

What should be tracked is the trajectory. The mitigation is per-copy: each new
module-free copy needs its own parity lint, and the day one ships without it is
the day the ADR's cost becomes a defect. That is worth a standing item rather
than a finding.

### F2.2 - The tidy gate is changed-code-only, deliberately (PASS - and a note on assessing it)

`t/lint/06-tidy.t` runs `tools/tidy-check.pl`, which flags only lines a change
touched since the last release tag. The header states the intent plainly: "The
existing tree keeps its hand-formatting."

Recorded here because the audit initially ran perltidy across the whole tracked
tree and produced a list of "not tidy" files. That list was **not** a finding -
it was measuring a standard the project has explicitly decided against. The
check was discarded. Noted so a future assessor does not repeat it and so the
deliberate position is on the record.

### F2.3 - perlcritic severity 3 is clean across the tree (PASS)

```
$ perlcritic --profile .perlcriticrc --severity 3 lazysite-*.pl lib tools
... source OK (every file)
critic rc=0
```

Clean across all seven CGI surfaces, `lib/`, and `tools/`, on a tree that has
grown by roughly 1,000 lines in the render path alone since the 0.8.0 gate.

### F2.4 - The lint suite's shape improved, not just its size (PASS)

41 lint files, up from 12 at the 0.8.0 gate. The important change is in kind:

- **Behavioural parity** rather than text comparison: `t/lint/35` and
  `t/lint/37` execute both implementations and compare results, because two
  implementations that read alike can still disagree.
- **Real tools rather than assumptions**: `t/lint/34` starts nginx and parses
  every shipped config; `t/lint/07` runs shellcheck.
- **Derived lists rather than maintained ones**: `t/lint/31` and `t/lint/41`
  assert that a hand-kept list matches the filesystem, so a template or a
  surface nobody listed fails rather than passing silently.

The last of these is the project's most valuable recurring lesson, found four
separate times and converted into a mechanism each time.

### F2.5 - Comments carry cause, not description (PASS, noted)

A quality worth recording because it is unusual and it is load-bearing for a
codebase this size. The comments in the changed code explain *why the code is
this shape and what went wrong when it was another shape* - `make_path` is not
imported into `Private.pm` because "an unqualified call is how this happened";
the extension probe is a sub rather than a file-scoped `my` because of a named
prior incident. That is the form of comment that survives contact with a later
maintainer.

## Evidence

- `perlcritic --profile .perlcriticrc --severity 3` - rc 0.
- `t/lint/06-tidy.t`, `tools/tidy-check.pl` - the changed-code-only scope.
- `git show <tag>:lazysite-processor.pl | wc -l` across five tags.
