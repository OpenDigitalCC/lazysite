---
title: "lazysite - human sign-off switch"
subtitle: "Whether the release gate blocks on records that only a person can close. Set by the release manager, not by the engine."
brand: plain
standard-margins: true
signoff_required: no
---

# What this file decides

Some compliance findings cannot be closed by a commit. Walking the
obligations register, re-reading the technical file, signing a
declaration of conformity - each needs a person to have actually done
it, and the only honest way to record that is for that person to say so.

`signoff_required` decides whether those findings **block a release** or
are **reported and passed over**.

```datatable
columns: Value | Effect
widths: 3cm | X
bold: 1
tone: medium
---
`yes` | Sign-off findings block. `release.sh` refuses to cut.
`no` | They are reported as MASKED, with their detail, and do not block.
absent | Treated as `yes`. A missing switch must not quietly disable a gate.
---
```

# Why it is a switch and not a default

::: widebox
**Masked is not passed, and the distinction is the point.** A masked
finding is printed in full, counted, and labelled - it simply does not
stop the build. Nothing is hidden, and turning the switch to `yes`
reveals no new information: the findings were on screen the whole time.
:::

The alternative was to let these findings block, which is what happened
until 2026-08-18. It sounds stricter and is not, for a reason worth
recording: the version anchor they compare against had itself been stale
for five releases (SM375), so the gate had been passing on a false
premise. A gate that blocks on a question it is asking wrongly teaches
people to work around it, and a worked-around gate protects nothing.

Sign-off is a judgement about whether the product is ready to be
declared conformant. That judgement belongs to the release manager and
has a date attached to it, so the engine's job is to put the facts in
front of them, not to guess when they are due.

# Who changes it, and when

The release manager sets `signoff_required: yes` when a release is
heading for a channel where the declaration attaches - in practice, at
the next **stable**. `edge` and `beta` carry no conformity declaration,
so blocking them on one asserts something about a build nobody claimed.

Changing this file is a deliberate act with a commit attached to it,
which is the audit trail.
