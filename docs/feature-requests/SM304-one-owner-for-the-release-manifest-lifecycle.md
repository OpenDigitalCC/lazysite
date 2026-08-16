---
title: "SM304 - Three places now generate release-manifest.json when it is absent"
subtitle: "A gitignored build artefact that three separate readers each learned to derive for themselves. Two of those three were added in one day, by one change, to fix one bug."
brand: plain
status: partial
status-note: "THE CORRUPTION GAP IS CLOSED (2026-08-16): both readers now treat a manifest that is PRESENT but unparseable exactly as an absent one, regenerating it - the recovery was identical and already written in both, so neither needed new logic, only the branch. Verified by reproducing the power cut: null-filling the manifest and running both tools, which now exit 0 where they died. THE DUPLICATION ITSELF REMAINS - _generate_manifest_to_tmp is still the same function in two files, and this fix added a third near-identical block to each, which is the argument for one owner getting stronger rather than weaker. CORROBORATED 2026-08-15 by a power cut that left release-manifest.json full of nulls: both duplicated readers failed with different messages, and NEITHER handles a file that is present but unparseable - only absent. The recovery for both is identical and already written. FILED 2026-08-15 out of the 0.10.9 review. Nothing started. Not urgent and not subtle: the duplication works, is tested and is currently consistent. It is filed because this project removes duplicated lifecycles on principle, and because SM269 phase 1 already did this once for the same file."
---

# SM304 - the same three steps, in three files

## What is duplicated

`release-manifest.json` is generated at build time and gitignored, so it exists
in a release tarball and not in a checkout. Three readers now each handle its
absence:

```datatable
columns: File | What it does when the manifest is missing
widths: 5cm | X
bold: 1
tone: medium
text: 2
---
`install.pl` | `_generate_manifest_to_tmp` - runs build-manifest.pl to a temp path, loads, unlinks
`tools/manifest-to-sbom.pl` | the same function, same name, same body
`t/lib/TestHelper.pm` | `repo_manifest_guard` - sets any existing manifest aside, always rebuilds, restores
```

The first two were added on the same day, by the same change, and are near
identical. The third is older, does something deliberately different (it
guarantees the manifest *describes the current tree*, which is stronger), and
predates them.

## Why this matters more than ordinary duplication

SM269 phase 1 already consolidated this exact lifecycle once. Its rationale is
worth quoting back:

> Six copies of one lifecycle is what kept producing ordering bugs. A lock alone
> did not fix it: the lock serialises the tests, but each test still decides
> independently when to create and destroy a file they all share.

The count went six to one, and is now back to three. Two of the new copies were
added while fixing a defect *caused by* inconsistent handling of that same file
- a clean checkout could not run the test suite or the SBOM gate because both
assumed the artefact was present.

The failure mode is not hypothetical for this file specifically. Its handling
has already produced: a suite that passed only where a stale copy happened to
exist, a "flaky" test that was deterministic, and a compliance control that
could not be run from the tag it attests.

### Corroborated the same day, by accident

A power cut during the 0.10.10 gate left `release-manifest.json` as 66,505 bytes
of nulls - written, not fsynced. The file is gitignored, so `git status` reported
the tree clean and nothing pointed at it.

Both duplicated readers hit it, and said different things:

```datatable
columns: Reader | What it reported
widths: 6.4cm | X
bold: 1
tone: medium
---
`install.pl:1812` | `Cannot parse ...: malformed JSON string ... at character offset 0`
`tools/manifest-to-sbom.pl:311` | the same malformed-JSON die, with no `Cannot parse` prefix and no path
---
```

Neither considered that a file it knows how to REGENERATE might be present and
unusable - both handle "missing" and neither handles "corrupt", which is the same
gap written twice. One owner would have one answer, and the obvious one is to
treat an unparseable manifest exactly as an absent one, since the recovery is
identical and already implemented.

It cost a failed gate run and two diagnoses. That is small, and it is the
cheapest possible version of the lesson: the same fault arriving through two
copies of one lifecycle, reported two ways, on a file whose whole point is to
describe what ships.

## What to build

One helper owning the whole lifecycle, with the two distinct contracts named
rather than blurred:

`ensure_manifest($root)`
: return a path to a manifest describing `$root`, generating one to a temp
  location if absent. For readers that only need to read it - install.pl,
  manifest-to-sbom.pl.

`guarantee_fresh_manifest($root)`
: the stronger contract the test guard needs - the manifest must describe the
  tree *now*, so any pre-existing one is set aside and rebuilt, and restored
  afterwards. Never trust an existing file, because an mtime check is not
  sufficient: copying an old manifest gives it a new mtime with stale content.

The awkwardness is that `install.pl` is module-free by design - it is the
bootstrap that installs `lib/` and so cannot depend on it (the same constraint
as ADR 0001's render path). So either the helper is a small module the two tools
share and install.pl keeps its own copy pinned by a parity lint, or install.pl's
copy is the canonical one and the others call out to it. That decision is the
work.

## Care needed

- **The temp-path behaviour is not incidental.** Writing into the checkout would
  leave an untracked artefact that later silently answers questions on the
  tree's behalf, which is the original defect.
- **Whatever is chosen, pin it.** If install.pl keeps a copy, it needs the same
  treatment as the other module-free copies: a lint that drives both and
  compares answers, not source text.

## Related

SM269 phase 1 (which consolidated this lifecycle the first time),
`docs/review/2026-08-14-eight-dimension-0.10.9/` D3, ADR 0001 (the module-free
constraint that makes install.pl awkward).
