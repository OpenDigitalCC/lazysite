---
id: SM1208
title: "SM1208: the fleet test waits for what it checks"
subtitle: "t/tools/29-cli-fleet.t compared installs with the VERSION file while t/tools/52 held VERSION at 99.0.0, so under prove -j the nightly failed it. It now takes the lock 52 takes."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the nightly suite, 2026-10-20 08:33 (main 13f0b549f), t/tools/29-cli-fleet.t failed 2 of 6"
area: tests
status-note: "SHIPPED (PENDING) on n696: t/tools/29 holds the VERSION preserve lock t/tools/52 holds, so it never reads 99.0.0. New t/tools/190 holds the lock and requires 29 to wait; it fails without the fix."
---

# What happened

The nightly (tools/suite.sh --nightly, prove -j on a loaded host) failed
t/tools/29-cli-fleet.t at 08:33:

> upgraded despite policy/channel: got '0.15.12', expected '99.0.0'

and the `sites` listing showed 0.15.12 where the test expected 99.0.0. It had
passed at 08:18 and in the 0.15.12 gate, and passes alone in about 11 seconds.

# Cause

99.0.0 is the value t/tools/52-human-signoff-is-masked-not-removed.t writes to
VERSION (line 67) for the length of its run. It serialises with other VERSION
writers through TestHelper::preserve_tracked, which locks the file. 29 read VERSION
(`chomp( my $VERSION = slurp("$ROOT/VERSION") )`) with no lock. In the failed run it
read 99.0.0 inside 52's window; the first manifest it built, and so the first
subtests' installs, were 99.0.0 too (those subtests passed); 52 then put VERSION
back, and the manifest 29 built for the `--force-security` subtest was 0.15.12.
Expected 99.0.0, installed 0.15.12 - the two numbers in the log.

The 258 seconds seen in the nightly is waiting: 29 queues on the repo manifest lock
behind the other tests that build one. Its own work is about 11 seconds.

# Change

29 takes the VERSION preserve lock before anything reads VERSION and keeps it to
the end. t/tools/190 holds that lock, starts 29, and requires that 29 has checked
nothing after 8 seconds and passes once the lock is let go.
