---
title: "SM375: VERSION sat five releases behind, and the compliance gate believed it"
subtitle: "The file that says which version this is read 0.10.9 while 0.10.10 through 0.10.14 shipped. The remedy was written in 2026 for the identical defect, committed, and never wired into the release - so it recurred exactly."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-08-18 on claude/sm375-version-file, NOT in 0.10.14 (found while verifying that build). release.sh now STAMPS VERSION in the stage from the released version, before the three things that read it; t/lint/63 fails when the repo's copy falls behind the newest tag; t/tools/51 asserts the stamp AND its ordering, and runs the stamp line extracted from release.sh rather than a copy. THE FINDING THAT MATTERS IS NOT THE STALE FILE: correcting it turned the release compliance gate from 0 blocking to 2 blocking, because for five releases that gate was asking whether records were current as of 0.10.9 - a question they passed by standing still. See the Consequences section; those two are a blocker for the next cut and one of them needs a person, not a commit."
---

# What was found

`VERSION` in the repository root read **0.10.9**. Releases 0.10.10,
0.10.11, 0.10.12, 0.10.13 and 0.10.14 had all shipped since.

Found while unpacking the 0.10.14 tarball to confirm a set of fixes was
actually in the build before asking the site agent to test them. The
fixes were there. The version marker beside them was not.

# Why it recurred, which is the interesting part

`tools/bump-version.pl` exists **for exactly this defect**. Its header
records the first occurrence:

> the 2026 seven-dimension review found it stuck at 0.2.18 while
> releases were at 0.3.x

and states the remedy:

> The release process should call this AFTER a tag is cut.

The release process never called it. So the fix was written, reviewed,
committed - and left depending on a person remembering to invoke it.
Five releases later the defect returned in the same file, in the same
shape, for the same reason.

::: widebox
**A remedy that must be remembered is not a remedy.** This is the same
conclusion SM372 reached about the `.deb` set - "a step that is not part
of a process that succeeds is a step that eventually stops happening" -
and it was reached in the *same file*, `debian/changelog`, four days
earlier. VERSION sits next to it and was missed because only one of the
two was being looked at.
:::

# Consequences

```datatable
columns: Reader | What the stale value did
widths: 6.2cm | X
bold: 1
tone: medium
---
`lazysite-compliance.pl` | Compared compliance records against **0.10.9**, so records that had not moved since then passed as current. This is the serious one.
`build-manifest.pl` | Defaults to the file; correct only because `release.sh` passes `--version` explicitly - authoritative by accident of invocation.
`manifest-to-sbom.pl` | The same.
The shipped tarball | Carries `VERSION` inside it, where nothing passes those tools anything.
---
```

::: widebox
**The compliance gate was passing on a false premise for five releases.**
Correcting VERSION to 0.10.14 turns it from `0 blocking` to `2 blocking`:
the obligations register and the technical file both record
`0.10.9` as the version they were last walked at. Neither is a code
defect and neither can be closed by editing a version marker - doing that
would be recording a review that did not happen, which is the exact
failure this project keeps removing. They need walking.
:::

Also now visible, previously masked: `FEATURES.md` newest entry is
0.10.9, and the declaration of conformity is stamped 0.8.0 and unsigned
(advisory on edge, blocking at the next stable).

# The fix

`release.sh` stamps `VERSION` in the **stage**, from the version being
released, leaving the repository's own copy alone - release.sh does not
touch main (SM063). This is precisely what SM372 did for
`debian/changelog`, and the reasoning transfers without change: the
artefact cannot disagree with the tag by construction.

It is stamped **before** the compliance gate, `build-manifest`,
`manifest-to-sbom` and the tarball, because all four read it. A stamp
placed after any of them would leave the same wrong answers while looking
correct in a diff, which is why `t/tools/51` asserts the ordering rather
than the presence.

The repository's copy is brought to 0.10.14 and `NEXT_VERSION` to
0.10.15, and `t/lint/63` fails when VERSION falls behind the newest tag.

::: widebox
**The red window is deliberate.** Between cutting `vX` and bumping
VERSION, `t/lint/63` fails on main. That is the forcing function rather
than a flaw: release.sh stamps the artefact correctly on its own, so a
red main costs one line - and it is the only thing that makes that line
get written.
:::

# Verification

- `t/lint/63` fails when VERSION is behind the newest tag, and when
  NEXT_VERSION is not ahead of VERSION. Both shown failing.
- `t/tools/51` asserts the stamp exists, that it precedes all four
  readers, and **runs the stamp line extracted from `release.sh`** against
  a stage carrying a stale value. Removing the stamp fails it; moving it
  after the compliance gate fails it specifically on ordering.
- `lazysite-compliance.pl --check` now reports version 0.10.14 and two
  blocking findings, where it previously reported 0.10.9 and none.

# Related

[[SM372]] (the same defect, the neighbouring file, four days earlier),
[[SM064]] (burned versions are never reused), [[SM063]] (release.sh does
not touch main).
