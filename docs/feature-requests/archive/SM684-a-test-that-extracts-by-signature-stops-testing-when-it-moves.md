---
id: SM684
title: A test that extracts a function by its signature stops testing when the signature moves
raised: 2026-08-28
raised-by: engine agent
area: testing
status: shipped
status-note: "SHIPPED in 0.11.6 - t/lib/PageScript.pm matches the function NAME, lets the parameters move, and DIES when it is absent; all seven call sites converted (the lint found one I had missed by hand) and t/lint/93 refuses a new signature-pinned extraction. Verified both directions on the real page: adding a parameter keeps all seventeen assertions running, renaming the function fails loudly. ORIGINALLY: Found while landing SM683: t/unit/manager/127 pulls renderHistory out of files.md with a regex pinned to its exact two-argument signature, SM683 added a third argument, and the five assertions behind the extraction were SKIPPED rather than failed - the suite read 16 tests with 5 skipped and looked healthy. Five sibling tests use the same pattern. The fix is not to widen six regexes: it is to make a failed extraction a FAILURE everywhere, and ideally to extract through one shared helper that says which function it could not find."
---

# What happened

`t/unit/manager/127-a-history-row-says-how-big-the-change-was.t` reads
`starter/manager/files.md` and pulls the renderer out of it with:

    my ($fn) = $src =~ /(function renderHistory\(panel, entries\).*?\n\})/s;

SM683 gave `renderHistory` a third argument - whether the file is protected.
The regex stopped matching. The five assertions that run the extracted function
under node were inside a `SKIP` block, so they did not run, and the only visible
symptom was one failed `ok()` among sixteen tests with five skipped.

That is the worst shape a test failure can take: the suite still passes its own
summary line, and the assertions that would catch a real regression are quietly
not being made. It was caught here only because the `ok()` before the skip
failed loudly enough to fail the gate.

# The pattern, not the instance

Six tests extract a JavaScript function from a manager page by matching its
exact signature:

| Test | Function |
| --- | --- |
| `t/unit/manager/126` | `loadDir(dir)`, `loadAliasesInto()` |
| `t/unit/manager/127` | `renderHistory(panel, entries)` |
| `t/unit/manager/131` | `loadProtectedSections()` |
| `t/unit/manager/124` | `applyPreset(name)` |
| `t/lint/72` | `updateHereProtection()` |

Every one of them silently stops testing the moment somebody adds a parameter -
which is a normal, correct thing to do to a function. The test does not object
to the change; it just stops watching.

# What it needs

Three things, in increasing order of value:

1. **A failed extraction must fail, never skip.** Whatever else changes, the
   `ok($fn, ...)` must be outside the `SKIP` block, so a signature move breaks
   the gate rather than hollowing it out.
2. **One helper, not six regexes.** A shared `extract_js_function($src, $name)`
   in `t/lib` that matches on the NAME and tolerates the parameter list, and
   dies with the function name and file when it finds nothing. Six call sites
   become six one-line calls that cannot drift apart.
3. **A lint that counts.** The extraction helper could record which functions it
   was asked for; a lint then checks each still exists in the page it names.
   That catches a function being renamed or deleted, which today reads as the
   same silent skip.

# Why this is worth doing now rather than later

The manager pages are where the release's UI behaviour is asserted, and this
class of test is how it is asserted. A suite that stops watching when a
signature changes gives its strongest false assurance exactly when the code is
being changed most - which is during a release.

# Related

SM683 (the change that exposed it), [[SM662]] (a gate's reach living in more
places than anyone checks - the same shape, in the capability map rather than
the tests).

# Not started
