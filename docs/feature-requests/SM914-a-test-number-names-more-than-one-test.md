---
id: SM914
title: "SM914: a test number names more than one test, 107 times, and 1,294 citations point at the ambiguity"
subtitle: "Filings, module comments and tooling cite tests by number - `t/integration/13`, `t/lint/58` - and that has never been an identifier. 107 numbers name two or more files; one names four; the most-cited ambiguous number appears 61 times. Nothing is broken and every reference is a guess."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-09-29 after I claimed it as a defect I had caused and the measurement disproved that. Adding two lints on 2026-09-28 I picked 110 and 111 by checking `ls t/lint/ | tail -12` (sorted lexically, so 99 looks like the last) and `ls t/lint/ | grep '^10'` (which cannot see 110-151), and landed them beside the existing 110-the-doc-index-matches-the-tree.t and 111-the-coverage-digest-covers-what-is-measured.t. I wrote a gate asserting that a number names one test, ran it, read the first five lines of its diagnosis - three pairs in t/tools/ - and built an allow-list for those three. The full output has 107. The gate was deleted rather than shipped with a 107-entry allow-list, which is not a gate. My two were renumbered to 152 and 153 because the numbers were free and the citations were mine to correct; the other 107 are the tree's long-standing convention and are not mine to decide."
raised: 2026-09-29
raised-by: engine agent (while renumbering two lints of my own)
area: testing, documentation
---

# What was measured

`tmp/count-collisions.pl`, over `t/lint`, `t/tools`, `t/integration` and every
`t/unit/*` directory. Each is its own numbering space, because the directory is
part of how a test is cited.

**107 numbers name two or more test files.** One names four
(`t/integration/59`). Summing the bare-number citations across those 107 numbers
in `*.pm`, `*.pl`, `*.md` and `*.t`: **1,294**.

The worst few, by how often the ambiguous form is actually written down:

| Number | Cited | Names |
| --- | --- | --- |
| `t/integration/13` | 61 | `13-layout-compile-cache.t` + `13-write-failure.t` |
| `t/integration/6` | 28 | `06-deny-consistency.t` + `06-preview.t` |
| `t/integration/14` | 24 | `14-access-log.t` + `14-bad-url-blocker.t` |
| `t/tools/03` | 20 | `03-bundle-apply.t` + `03-install-pl.t` |
| `t/integration/18` | 20 | `18-domains-served.t` + `18-mixed-identity-modes.t` |

# Why it matters, and why it has not hurt yet

**Nothing is broken.** The harness globs filenames; the numbers are not
identifiers to it, and two files with one number both run.

What is affected is the CITATION. This project points at evidence by test number
constantly - a filing's status-note saying which test holds a property, a module
comment saying which lint enforces a rule, a commit message saying which subtest
caught a sabotage. `[[feedback_a_citation_is_never_a_key]]` is the standing rule
this runs into: an identifier that stops identifying does not announce itself, and
the reader who follows it reaches two different tests and cannot tell which was
meant.

It has not hurt yet because the *full* filename is usually written beside the
number in practice, and because a reader who lands on the wrong one of a pair
usually notices. Neither is a property anybody arranged.

# What this is NOT

Not a request to renumber 107 tests. A rename invalidates every citation that
names the file in full as well as every bare-number one - `t/tools/03-install-pl`
is cited eleven times - so the cure is larger than the disease and would churn
history for a property no code depends on.

# The options, for a ruling

1. **Leave it, and say so.** Write down that a test number is a label rather than
   an identifier, and that a citation should name the file (`t/integration/13-write-failure.t`).
   Costs nothing, makes the existing habit correct, and the 1,294 loose citations
   stay loose.
2. **Gate new tests only.** A lint that refuses a NEW collision while recording
   the 107 as a fixed set that may only shrink - the treatment `t/lint/118` gives
   bare-tempdir docroots. Stops the set growing; leaves every existing citation
   ambiguous.
3. **Renumber.** Correct, expensive, and it rewrites references in filings that
   are already closed.

My recommendation is **1 plus 2**: the convention written down so citations start
naming files, and a gate so the set stops growing. Option 3 buys clarity that
option 1 gets for free.

# Related

[[feedback_a_citation_is_never_a_key]] (the rule this runs into),
[[feedback_reference_name_not_evidence]], and `t/lint/118` (the
count-only-comes-down idiom option 2 would copy).
