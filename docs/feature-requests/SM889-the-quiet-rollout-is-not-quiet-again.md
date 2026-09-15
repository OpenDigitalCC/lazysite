---
id: SM889
title: "SM889: the quiet rollout is not quiet again - SM701's contract held, and everything added since ignored it"
subtitle: "The 0.14.2 fleet update printed about 200 lines to say 29 updated, 0 failed. The --quiet report is still selected and still prints its summary table, so nothing was reverted: phases added after SM701 simply never asked whether they were in quiet mode, and three of them print the same sentence once per site."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-15
raised-by: release manager
area: installers
status-note: "REGRESSION of [[SM701]], which shipped in 0.11.9 and set the contract: ONE candidate table, then only warnings and failures each attributed to its site, then a summary table, with --verbose restoring the transcript. THE FLAG LOGIC IS INTACT - the run still ends '(quiet report; re-run with --verbose for every phase in full)' and the summary table is exactly right. What regressed is that the backup, ACL re-apply and probe phases emit unconditionally. MEASURED FROM THE 0.14.2 DEPLOY: 71 per-file backup lines, 29 truncated sentences, ~25 unattributed 'No protected sections' lines, the same ~90-word ACL paragraph 8 times, the same ~45-word probe warning 21 times VERBATIM, and about a dozen INFO log lines interleaved out of order. Signal in that output: 29 summary rows and perhaps four distinct conditions. ALSO CARRIES A REAL DEFECT, not just noise: one message is truncated mid-sentence, ending in a colon with nothing after it."
---

# What the operator saw

29 sites updated, 0 failed - reported in roughly two hundred lines, of which
the summary table at the end is the part that answers the question.

This is the same complaint as [[SM701]] and it is not the same cause. SM701's
rollout printed every candidate four times and then streamed each install
transcript. That was fixed and stayed fixed: the candidate table is printed
once, the summary table is right, and the run correctly says it is the quiet
report.

**The phases added since do not consult the flag.**

# Counted from the 0.14.2 deploy

| Ref | Source | Lines | Distinct information |
| --- | --- | --- | --- |
| N1 | `backup: missing <path> (recorded in state but not on disk; skipped)` | **71** | 16 sites have some recorded files that are no longer on disk. One line per site would carry it; one line per site per file does not. |
| N2 | `[<domain>]      deliberate, not a missing step, and there is no default login:` | **29** | None - and see D1 below, because this line is **broken**, not merely repeated. |
| N3 | `No protected sections - nothing to re-apply.` | **~25** | None. It reports a no-op, and it names **no site**, so it cannot even be read as a per-site result. |
| N4 | `already in place: <name>` followed by the same ~90-word paragraph about `@group` entries and token partners | **8 paragraphs** | The paragraph is identical every time. It is guidance for someone SETTING a rule, printed while re-applying rules that are already correct. |
| N5 | `0 re-applied, N already in place, 0 could not be moved, 0 failed.` + `Verify from OUTSIDE with: ...` | **~14** | Per-site totals for a phase whose fleet total is already printed. |
| N6 | `[timestamp] [INFO] [lazysite] [acl-set] acl set user=local path=X` | **~12** | INFO logging on stdout during a fleet run - and **out of order**, appearing after the block it belongs to. |
| N7 | The probe warning about a front-end cache holding descriptors | **21**, verbatim | **One** condition affecting 21 sites. The sentence is ~45 words and identical except for which extensions were served. |

# The three failures, which are different from each other

**Per item where a count would do** (N1). The operator does not need 71 paths to
learn that some sites have recorded files that were deleted. They need to know
which sites, and how many - and only if they might act on it.

**The same sentence once per site** (N4, N7). These are not 21 findings and 8
findings. They are **two conditions**, each affecting a set of sites. A report
that repeats identical prose per site is asserting a per-site result it does not
have, and it buries the cases that genuinely differ - N7's extension lists vary
between sites, and that variation is invisible inside twenty-one copies of the
same paragraph.

**Output that is not attributed at all** (N3, N6). SM701's contract is *"each
attributed to its site"*. A bare `No protected sections - nothing to re-apply.`
belongs to no site the reader can identify, and INFO log lines interleaved out
of sequence belong to no phase.

# D1 - a truncated message, which is a defect and not verbosity

Every site prints:

```
[<domain>]      deliberate, not a missing step, and there is no default login:
```

It ends in a colon with nothing after it, on all 29 sites. Either the
continuation is being dropped, or a multi-line message is being filtered to its
first line while the part it introduces is discarded. **Whatever it was meant to
say, nobody has read it for some time**, because a sentence that stops at its
colon reads as a formatting artefact rather than as missing content.

This should be fixed whether or not the verbosity is.

# The summary counts sites, not conditions

```
check:  1 clean, 28 with warnings or failures
```

True, and it reads as twenty-eight problems. Twenty-one of them are the same
front-end cache condition, which the engine's own warning text already explains
and which [[SM888]] records as ESTATE rather than engine. A summary that said
*"28 with warnings: 21 the same front-end cache condition, 7 other"* would be
the same length and would tell the operator whether they are looking at one
problem or twenty-eight.

# The fix

Not "add more conditionals". The lesson of the regression is that a phase added
later will not know about a flag it was never told about.

- **Route every rollout line through one reporter** that knows the verbosity
  level, the way SM701's own output already does. A phase that prints directly
  cannot regress this if it has no way to print directly.
- **Group by condition, then list sites** - so a new repeated message degrades
  into a count rather than into a wall.
- **Keep the escape hatch honest**: `--verbose` shows everything, and a site
  that FAILS still prints everything captured, which SM701 established for the
  right reason and which nothing here changes.

A lint could pin it: no direct `echo` to stdout in the rollout's phase
functions. That is the shape [[SM836]] used for gated writes, and it works for
the same reason - it removes the ability to get it wrong rather than asking
people to remember.

# Related

[[SM701]] (the contract this breaks, shipped 0.11.9), [[SM888]] (N7's condition,
classed ESTATE), [[SM836]] (the one-way-in pattern the fix should copy),
[[SM283]] (the front-end exposure the probe phase exists to catch).
