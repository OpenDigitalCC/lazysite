---
id: SM891
title: "SM891: two directives in the shipped runtime unit that systemd has been ignoring"
subtitle: "A start-rate limit in the wrong section, and a Documentation= pointing at a man page that does not exist. Both found by one `systemd-analyze verify` the release manager ran; both had been there since the unit was written, and the exit code was 0 throughout."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-15
raised-by: release manager
area: installers
status-note: "FIXED 2026-09-15, both, and pinned by t/lint/147 which runs `systemd-analyze verify` over every shipped unit. THE START LIMIT: StartLimitIntervalSec and StartLimitBurst were in [Service]; they moved to [Unit] in systemd 230 (2016), and in [Service] they are parsed, rejected and skipped. The comment above them explains at length why a runtime that cannot start should not be retried tightly - and that reasoning has never been in force, so a runtime failing on a bad config has been retried every 5s for ever. THE DOC LINK: Documentation=man:lazysite(1) names a man page this project has never shipped, in both the runtime and the pool unit; now the docs URL. WHY IT SURVIVED: `systemd-analyze verify` EXITS 0 with both present - it reports on stderr and succeeds - so any check written as 'run it, assert success' passes on a unit whose directives systemd is discarding. The lint asserts the OUTPUT is empty."
---

# What was found

The release manager ran one command:

```
systemd-analyze verify /etc/systemd/system/lazysited@.service
```

```
lazysited@.service:70: Unknown key 'StartLimitIntervalSec' in section [Service], ignoring.
lazysited@i.service: Command 'man lazysite(1)' failed with code 16
```

Reproduced against the repo's own copy before anything was changed, so this is
the shipped file and not an edit made on the host.

# The start limit, which is the one that matters

`StartLimitIntervalSec` and `StartLimitBurst` belong in `[Unit]`. They were in
`[Service]`, where systemd **parses them, rejects them and carries on**.

The comment sitting immediately above them says why they are there:

> The supervisor's own restart handling covers a SERVICE dying; this covers the
> supervisor itself. A runtime that cannot start at all should not be retried
> tightly - the usual cause is configuration, which restarting will not fix.

That is correct, and it has never happened. `Restart=on-failure` with
`RestartSec=5` four lines above it **has** been in force. So a runtime that
cannot start - the exact case the comment describes, and the one whose usual
cause is a configuration error restarting will not fix - has been retried every
five seconds indefinitely, with the bound that exists to stop it inert.

This is the [[SM783]] shape: a declaration the code ignores. The reasoning was
written down, reviewed, and had no effect.

# The documentation link

`Documentation=man:lazysite(1)` in both the runtime and the pool unit. There is
no `lazysite(1)` man page and there never has been.

A pointer to a page that does not exist is worse than no pointer: it tells an
operator where to look and the answer is that nothing is there. Now
`https://lazysite.io/docs/`, which exists.

# Why it went unnoticed, and what the test does about it

**`systemd-analyze verify` exited 0** with both defects present. It writes its
findings to stderr and succeeds anyway.

So the obvious test - run it, assert it succeeded - passes on a unit whose
directives systemd is silently discarding. `t/lint/147` asserts the **output is
empty**, over every `*.service` this project ships, and skips only where
`systemd-analyze` is not installed.

Deliberately strict: any output fails, rather than a grep for the two strings
already seen. These files are small, this project owns every line of them, and
the lesson here is precisely that the message nobody read was the one that
mattered.

# What is not claimed

**Whether this explains anything observed in the field is open.** The same day
this was found, the operator's host showed 28 of 29 `lazysited@` units
`inactive dead`. A start limit that never applied means a failing unit was
retried forever rather than stopping - which is not the same as being dead, and
may be unrelated. [[SM892]] carries that question with the readings that would
settle it; nothing here should be read as having answered it.

# Related

[[SM892]] (the dead units and the upgrade path), [[N142A]] (which restarts
these units), [[SM757]] (the persistent runtime this unit supervises).
