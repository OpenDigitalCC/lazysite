---
title: "SM406: a subtest named for a race it never forced"
subtitle: "'backups taken in the same second' took two backups back to back and hoped they landed in the same second. When they did not, the engine was right and the assertion failed - on the one run where the machine is guaranteed busy: the release gate."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19, AND THE CAUSE OF THE 0.10.16 GATE FAILURE IS NOT ESTABLISHED. What is certain: the 0.10.16 edge cut failed in this file's subtest 5, and release.sh correctly refused to release. What is NOT certain is which assertion failed - the release output was piped through `tail -40`, which discarded the diagnostics, and that was my error on a 70-minute run. A full serial re-run of the suite, exactly as release.sh invokes it, PASSED against the unmodified test, so the failure is intermittent and has been seen once. The subtest defect fixed here is real on its own terms and is the most plausible mechanism - it is the only timing-dependent assertion in the subtest - but it is a hypothesis, not a diagnosis, and it is recorded as one. A competing explanation that cannot be ruled out: the subtest's first assertion is that both backups reported ok, which would fail for reasons having nothing to do with timing."
---

# The defect, which is real regardless

The subtest was called *'backups taken in the same second do not overwrite each
other'*. It took two backups back to back and asserted the second carried a
`-N` disambiguator:

```perl
my $a = action_backup_create('manual');
my $b = action_backup_create('manual');
like( $b->{name}, qr/-\d+\.tar\.gz\z/, 'the later one carries the suffix' );
```

`_claim_name` stamps from `gmtime` **at call time**. Each call tars a fixture
tree. If the pair straddles a second boundary the second backup gets a fresh
stamp, `$n` is 1, and there is correctly no suffix - so the engine behaves
properly and the assertion fails.

::: widebox
The subtest never **established** the condition its own name describes. It
hoped for it. That is the same defect class as a fixture whose non-ASCII string
was secretly ASCII, or one whose events sat inside the session gap - and it is
the fourth time this pattern has surfaced in a fortnight.
:::

# Why it surfaced where it did

It passes on an idle host. It failed on the release gate, which is the one run
where the machine is guaranteed to be busy - a full suite, then a benchmark,
then an instrumented coverage pass.

A test that only fails under load is worse than one that always fails: it
presents as flakiness, and the reflex to flakiness is to re-run rather than to
read.

# The fix

The collision is now **constructed**. The subtest occupies the filename this
second would produce, then takes a backup and asserts it claims the next free
suffix. A bounded retry covers the one remaining race - the clock ticking
between stamping and claiming - and costs microseconds rather than a tar.

The two properties are separated, because they need different things:

- **names never collide** - true however the clock falls, so no timing setup
- **the suffix increments** - needs a real collision, so the fixture makes one

# What is NOT claimed

That this fixed the 0.10.16 gate failure. It may have; the evidence to say so
does not exist, because it was discarded. Recorded here so that if the next cut
fails in the same place, nobody re-reads this filing and concludes the question
was settled.

**Process fix, worth more than the test fix:** a long run must not be piped
through `tail`. The gate output now goes to a file and the file is tailed, so
the diagnostics survive the summary.
