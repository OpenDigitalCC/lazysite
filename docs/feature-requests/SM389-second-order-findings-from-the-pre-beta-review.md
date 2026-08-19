---
title: "SM389: second-order findings from the pre-beta review"
subtitle: "A static read whole into a persistent worker, and two commits in the shipped release whose own subject lines say they are not proven. One was a resource defect; the other turned out to be resolved, and the checking is the point."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-08-19. DONE: statics are streamed rather than slurped, and the two self-flagged commits were checked rather than assumed - both resolved, by code and not by rewriting the tests, which is verifiable from git. OPEN: the registry regeneration herd (TTL expiry with no lock), the front-door relay's unbounded body read when CONTENT_LENGTH is absent, the Apache one-rule templates' missing body cap, and the security register's missing rounds. Each is its own change and none is a promotion gate."
---

# Done: a static was read whole into a persistent worker

`_serve_content_static` read the entire file into memory before writing
a byte of it. In a pool worker that means **one request for a large
upload sizes that worker to the file and keeps it there** - the worker
persists, the memory does not come back.

Nothing capped it. WebDAV accepts 64m bodies by front-end configuration,
and an operator publishing video has no reason to expect that a fetch of
their own file is a memory event.

::: widebox
**A cap was the other option and is worse.** Refusing to serve a file
the operator legitimately published, to protect a limit they never set,
trades an availability defect for a resource one. Reading in 64 KiB
blocks costs nothing and makes the worker's footprint a constant rather
than a function of what anybody published.
:::

# Done: the two commits that flag themselves as unproven

The review noted, correctly, that two commits sit in the shipped release
with doubt in their own subject lines:

```datatable
columns: Commit | Subject says
widths: 3.0cm | X
bold: 1
tone: medium
---
`8c675f2` | SM335 ... **NOT READY TO LAND**
`3f3cfc6` | SM195 ... **NOT YET PROVEN END TO END**
---
```

`8c675f2` left **two tests failing on purpose**, on the grounds that
they encoded the old contract and "rewriting a test to match new
behaviour is how a contract change gets made silently".

**Both tests pass today, and neither file has been touched since.**
`git log 8c675f2..HEAD -- <the two files>` is empty, so they were made
to pass by the follow-up's code (`9b3bc1f`) rather than by editing the
tests to agree. That is the outcome the original commit was protecting,
and it can be checked rather than believed.

Recorded because "a commit that says it is not ready is in the release"
is alarming, and the answer was neither "ignore it" nor "revert it" but
one command.

# Open

- **Registry regeneration herd.** TTL expiry with no lock: N concurrent
  requests all regenerate. Registry hits are also missing from
  analytics.
- **The front-door relay reads an unbounded body** when
  `CONTENT_LENGTH` is absent, and the Apache one-rule templates carry no
  body-size cap. Different layer from the fix above and a different
  change.
- **The security register records round 1 only.** The 2026-07-21 round
  (critical `..` bypass, since fixed) and the August SM268 round are
  absent, and four attack classes have never been covered - two of them
  the serving path and the manager API.

# Related

[[SM342]] (the performance budget), [[SM335]] and [[SM195]] (the two
commits), [[SM268]] (the security round that is unrecorded).
