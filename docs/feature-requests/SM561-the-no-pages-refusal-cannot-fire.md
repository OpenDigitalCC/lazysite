---
title: "SM561: the produced-no-pages refusal cannot fire"
subtitle: "release.sh appends --prefix to MAN_ADD before testing it for emptiness, so a manpage generator that produced nothing passes the gate."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): release.sh tests MAN_ADD for emptiness before appending the trailing --prefix, so the 'produced no pages' refusal fires; proving assertion in t/tools/27-manpages.t lifts the block and runs it against an empty man directory expecting exit 1 (it reached the tarball step before), and against one page expecting the three-element interleaved shape. FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-release-excerpts/result.txt part 2; class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The 'gen-manpages.pl produced no pages' refusal at tools/release.sh 649-652 is unreachable: the trailing --prefix is appended to MAN_ADD at 648, before the emptiness test, so the array is never empty. The probe lifts lines 641-652 against an empty man directory: MAN_ADD has one element, exit 0, the refusal did not fire."
---

# The finding

The `gen-manpages.pl produced no pages` refusal (`release.sh 649-652`)
cannot fire: the trailing `--prefix` is appended at `release.sh 648`,
before the emptiness test, so `MAN_ADD` always holds at least one
element. The probe lifts lines 641-652 against an empty man directory:
`MAN_ADD has 1 element(s)`, exit 0, `VERDICT-2: refusal did NOT fire`.

# Why it matters

Operability: the gate was written to stop a release whose manpage step
silently produced nothing; as it stands a broken generator ships a
package with no manual pages and the release log shows the step as
passed.

# The proving test

`t/tools/27-manpages`: lift lines 641-652 against an empty dir, expect
exit 1.

# Fix shape

Test `MAN_ADD` for emptiness before appending `--prefix`.
