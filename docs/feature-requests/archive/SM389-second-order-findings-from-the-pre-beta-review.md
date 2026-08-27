---
title: "SM389: second-order findings from the pre-beta review"
subtitle: "A static read whole into a persistent worker, and two commits in the shipped release whose own subject lines say they are not proven. One was a resource defect; the other turned out to be resolved, and the checking is the point."
brand: plain
standard-margins: true
status: shipped
status-note: "CLOSED 2026-08-19. All four remaining items done, each with a test that was confirmed to fail against the unfixed code. (1) REGISTRY REGENERATION: TTL expiry was a stampede - measured at 12 of 12 concurrent requests each running a full site scan - and a non-blocking lock now picks one while the rest serve the file stale; only a cold start with nothing to serve makes the losers wait. Registry hits also recorded NOTHING at all, the one served path that did not, so they are now logged on their own channel and counted beside pageviews rather than inside them. (2) THE RELAY BODY is bounded both ways - a declared CONTENT_LENGTH is refused before allocating, and the no-length case (chunked, which the client chooses) reads in bounded chunks and stops one byte past the cap. The cap follows manager_upload_max_mb UP, because a backstop that silently undercut the upload limit would present as 'uploads broke after a config change'. (3) THE APACHE TEMPLATES gained LimitRequestBody, matching the client_max_body_size every nginx template already had; real Apache parses them in the test, because a misspelled directive looks like protection and refuses to start the server. (4) THE SECURITY REGISTER gained rounds 2 (2026-07-21, fixed in 0.9.9) and 3 (SM268, fixed in 0.10.5), and t/lint/64 now DERIVES last_covered and never_covered from the rounds so the file cannot claim coverage it has not got. The four never-covered classes the derivation produces match the four the review counted independently. Recorded honestly: work done outside a round is not coverage - SM389 itself touched dos-resource-exhaustion and concurrency-races, and that is noted in the register as incident-driven rather than as a sweep."
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
