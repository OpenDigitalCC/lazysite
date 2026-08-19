---
title: "SM385: the NOT CONFIRMED summary overwrote the stated reason with a guess"
subtitle: "The probe said why it declined. Three lines later the summary recommended a repair that fixes nothing, unconditionally, whatever the reason was - and the summary is the part a deploy log reader sees."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19 on claude/sm385-not-confirmed-names-its-cause. Found in the real 0.10.15 deploy to edge, in output produced by my own SM377 change: that added a new skip reason (running as root) and left the summary printing its one fixed guess. The summary now prints the reason the probe gave, and keeps the repair advice only for the case where no reason was given - which is real, and losing it would trade one wrong summary for another."
---

# Measured, in the 0.10.15 deploy

The probe declined and said exactly why:

```
[ warn ] ACL PROBE SKIPPED: running as root - protecting content here
         would leave root-owned files in the site tree (SM139); run the
         probe as the site user
```

The summary, three lines below:

```
Nothing was established either way. Usual cause is a docroot or
ACL store the probe could not write: run `lazysite repair` first.
```

::: widebox
**`lazysite repair` fixes nothing here.** The cause had been established
and stated, and was then overwritten by a guess - in the summary, which
is the part a deploy log reader actually reads. An operator following
it would run a repair, see no change, and be no closer.
:::

# Why it happened

SM377 added the root refusal - a new reason the probe can decline - and
did not update the summary that explains declines. The summary had one
fixed sentence, written when there was one likely cause.

That is the [[SM368]] shape again: a tool stating an inference in the
same voice as a measurement, where the inference decides what the
operator does next.

# The fix

The summary prints the reason the probe gave. The repair advice survives
for the case where **no** reason was given - a docroot the probe cannot
write really does produce that, and dropping the advice would trade one
wrong summary for another.

# Verification

- The skip reason is parsed from the probe's designated
  `ACL PROBE SKIPPED:` line and printed in the summary.
- The repair advice appears only in the no-reason branch; making it
  unconditional again fails the test.
- The root refusal is named in the test, so removing that skip cannot
  silently orphan the case that exposed this.

# Related

[[SM377]] (which added the skip and left this behind), [[SM368]] (the
same shape: an inference where a measurement belongs), [[SM319]] (a skip
must announce itself - it did; this is about what happened next).
