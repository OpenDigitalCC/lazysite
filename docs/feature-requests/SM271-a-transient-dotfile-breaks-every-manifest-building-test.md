---
title: "SM271 - A transient dotfile at the repo root breaks every manifest-building test, and never says so"
subtitle: "build-manifest.pl refuses on any file matching no classification rule. Three different tools tripped it in one session, and each time the failure presented as something else."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-11 (unreleased on main), option A. classify_file excludes any path that is a DOTFILE at the repo ROOT (a leading dot, no slash), and nothing else. An unclassified ordinary file still refuses, which is what the gate exists for, and t/tools/01 pins both directions plus 'no root dotfile is ever shipped'. The eight now-redundant dotfile excludes were DELETED from classification.json rather than left in place, so the general rule is exercised rather than shadowed by the specific ones it replaces; the manifest still carries 213 files either way. The refusal message now leads with the offending file - it named the manifest, two layers from the cause, which is what made this expensive to diagnose three times. ORIGINALLY FILED 2026-08-10 after the third occurrence in a single session: .prove (from prove --state=save, which SM269's own brief asks for), .manifest-test.lock (a test lock I added), and .test_info.<pid>.json (written by yath, one per job, deleted moments later). Each broke every test that builds a manifest, and each presented as a different problem - twice as parallel-safety failures, once as harness incompatibility. The third cost a wrong diagnosis that was stated as fact before being caught."
---

# SM271 - a transient dotfile breaks every manifest-building test

## The mechanism

`build-manifest.pl` refuses to build when it meets a file matching no
classification rule:

```
build-manifest: files match no rule and no exclude:
  .test_info.1027979.json
Add a rule or exclude to dist/config/classification.json.
```

That strictness is correct and deliberate: an unclassified file is one
nobody has decided about, and shipping it - or silently omitting it - is
how a release acquires content nobody reviewed.

Six tests build a manifest at the repo root. So an unclassified file
anywhere at the root makes all six fail, with an error that names the
manifest rather than the file, two layers away from the cause.

## Why it keeps happening

Three occurrences in one session, none of them careless:

**`.prove`** - written by `prove --state=save`, which the SM269 phase 0
brief explicitly asks for. Following the commissioned method broke the
suite.

**`.manifest-test.lock`** - a lockfile added by the SM269 phase 1 work to
fix a different problem in the same area.

**`.test_info.<pid>.json`** - written by `yath` (Test2::Harness), one per
job, and deleted a fraction of a second later.

The pattern is not "people are careless with the repo root". It is that
**the repo root is where per-run tooling state conventionally goes**, and
this project has made that a build-breaking act.

## Why the diagnosis is expensive

The failure never names the real cause, and it presents as whatever is
being worked on at the time:

- With `.prove` present, a parallel trial produced four failures that
  looked exactly like parallel-safety collisions.
- With the lockfile present, the same again.
- With yath's files present, six tools tests failed and it looked like
  harness incompatibility - and produced a confident wrong hypothesis
  (inherited `flock` across forked jobs) that would have cost a session.

The third case is worth recording in full, because the trap has a second
edge. The transient file exists for a fraction of a second per job, so
`ls -a` during a run usually shows nothing. That negative observation was
stated as fact - "yath doesn't leave artefacts in the repo root" - and it
was wrong. **A transient condition cannot be ruled out by one sample.**

## Options

**A. Ignore unclassified DOTFILES at the repo root** (recommended). A
dotfile at the root is tooling state by convention, not shippable
content; nothing lazysite ships is a root dotfile. Narrow, matches the
convention, and removes the class rather than the instance. Still refuses
an unclassified *ordinary* file, which is the case the strictness exists
for.

**B. Build into a tempdir instead.** The six tests need a manifest beside
`install.pl`, which resolves it as `abs_path(dirname($0))` - so this means
either a staging copy per test or a manifest-path argument install.pl does
not otherwise need. More work, and it widens a production surface for a
test's convenience.

**C. Keep adding exclusions.** What has happened three times. Each is one
line and each is only found by tripping over it.

## Acceptance

Whichever is chosen: dropping a transient dotfile at the repo root during
a test run must not fail the build, and if a build IS refused the message
should name the offending file first, not the manifest it was trying to
write.

## Related

SM065 (release-manifest.json generated, not tracked), SM269 phase 0 and 1
(where all three occurrences surfaced).
