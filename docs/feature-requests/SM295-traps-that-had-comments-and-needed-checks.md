---
title: "SM295 - Three traps that had comments and needed checks"
subtitle: "Each was documented in the code. Each was then made again by someone who had just read the documentation. A comment that has failed twice is not a weaker test - it is a different thing, and it does not work."
brand: plain
status: shipped
status-note: "FILED AND SHIPPED 2026-08-13, on the operator's question: 'can these traps be converted into behaviour changes of tests, or different tests or other improvements, so that our structure improves.' Three converted: t/lint/39 (file-scoped state below the main body), t/lint/40 (a list interpolated into a shell command string), and guards in tools/coverage.sh. t/lint/39 found a THIRD live instance on its first run - %OEMBED_PROVIDERS, shipped for months, leaving a documented SSRF mitigation inert."
---

# SM295 - the ones that came back

## Why this filing exists

Three mistakes cost real time in a single session. Two of them had cost time
before, and both were already written up **in a comment, in the file, next to
the code**. In one case the second instance was written a few hundred lines from
a comment describing the first.

That is the finding. A comment records what happened; it does not stop it
happening. The three below are now checks.

## 1. File-scoped state below the main body

`t/lint/39-no-state-below-the-dispatch.t`

These scripts run their main body near the top and define their subs below it.
A `my %TABLE = (...)` written among the subs is initialised only **after** the
request has been served, so every sub that reads it during the request sees an
empty variable. Perl says nothing: the declaration is in scope at compile time,
and an empty hash is an ordinary value.

| When | What | What it did |
|---|---|---|
| SM285 | `my @PROBE_EXT` | the ACL self-probe looped over an empty list and reported "the front end respects the ACL" against a dead port |
| SM293 | `my %REGISTRY_CT` | every generated registry 404'd |
| **found by the lint** | `my %OEMBED_PROVIDERS` | every oEmbed fell through to autodiscovery for months |

The third is the one worth dwelling on. With the provider table empty, the
known-provider shortcut never matched, so the endpoint came from the **remote
page's own link tag** instead of the hard-coded list. It kept working - the large
providers do advertise that tag - which is exactly why nobody noticed, and the
"restrict to trusted hosts" mitigation named in the comment beside it was inert
the whole time.

**The boundary is computed, not guessed:** the last top-level statement at brace
depth zero that runs something. A first attempt used "the first sub" and flagged
every legitimate constant in the processor. Noise is how a check stops being
read, so a check that cannot describe the file's real shape is worse than none.

## 2. A list interpolated into a shell command string

`t/lint/40-no-array-in-shell-strings.t`, and `TestHelper::run_cmd`

`qx($^X $tool @args)` does not pass `@args` as arguments. It builds one string
and hands it to the shell, which re-splits on whitespace - so the moment any
element contains a space, the command silently becomes a different command.

**The failure signature is what makes it expensive.** The tool receives nonsense,
refuses everything, and every assertion in the file fails at once - which is
precisely what a completely broken feature looks like. Both times, the debugging
started on the product.

- `lazysite acl` appeared to reject every call with "--docroot is required";
- the SM293 front door appeared to route nothing to any surface, because
  `Host: front.test` became two shell words.

`run_cmd` is the one correct way now: list form, no shell, nothing to re-split.
Four live instances were converted with the lint.

**The lint reads inside the command only.** A first version tested the whole
line and flagged `my @members = \`tar tzf ...\`` - where the array is the
assignment target and nothing is interpolated at all. A check with false
positives gets waived rather than fixed.

## 3. Coverage that corrupts itself

`tools/coverage.sh`

Two failures, both on the same day, both silent about their real cause:

- **Two concurrent runs share `cover_db`.** The second one's `rm -rf` deletes
  files the first is still writing, and both then report every CGI as
  `NOT MEASURED` - which reads as a genuine gate failure.
- **An orphaned `prove` keeps writing.** Killing a coverage run's shell left its
  child reparented to init, still executing tests for half an hour. `rm -rf`
  then fails and the run proceeds on a poisoned database.

Now there is an `flock`, so a second run refuses rather than sharing; and a check
that the database actually went away, which names the orphan and how to find it.
The `rm` needed `|| true` first: `set -e` was exiting on it with a bare "cannot
remove" and no explanation, which is exactly how it presented.

## A correction

I reported earlier that coverage exited 0 while printing `COVERAGE BELOW FLOOR`,
and called that contradictory. It was not: the run had been piped to `tail`, so
the status read was `tail`'s. The script's exit logic was correct and is
unchanged. The sibling of the standing rule about `tail` on test output - *a
pipeline masks the exit status of everything before it*.

## What is deliberately NOT converted

Two traps from this session stay as judgement rather than checks, because a
check would be guesswork:

- **A fixture that agrees with its reader** (SM292). Driving a reader test from
  the real writer is the fix, and no lint can tell a hand-built fixture from a
  legitimate one.
- **A skipped subtest reporting as a pass.** `skip_all` on a condition that
  should not have been possible is a judgement call at the point of writing.

Both are in the standing notes. Naming them here is the point: it says which
lessons have teeth and which are still only advice.

## Related

[[SM285]], [[SM293]] (the two that shipped the first trap), [[SM292]] (the
fixture one, deliberately not converted), and `docs/architecture/code-quality.md`.
