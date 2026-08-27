---
title: "SM404: three writers that renamed a torn file over a good one"
subtitle: "`_write_json_atomic` was atomic in the rename and not in the write. It checked neither the print nor the close, then promoted the result - and returned success. Where it matters most, the file it overwrites is never written again."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19. All three atomic writers in plugins/stats.pl checked neither print nor close before renaming, so a write that ran out of space produced a TRUNCATED temp file and the rename promoted it over a good one, while the function returned 1. The processor's main page-cache writer has had checked print AND checked close since SM020 - a pre-beta review praised it for exactly this property - and the stats writers never gained it. WORST FOR THE DURABLE STORE: day files are written ONCE and never rewritten because a past day is immutable, so a torn day file is permanent where a torn cache merely rebuilds. One of the three was added by SM393 days earlier, written to match the local style, which is how a defect propagates once it is the house pattern. Now one checked writer with one rename in the file. The test drives a REAL failed write with ulimit -f rather than reading the source, and carries a second case sized to fail only at the FLUSH - because with a large payload print() fails first, so a writer that checked print and not close would pass everything else."
---

# The defect

```perl
open my $fh, '>', $tmp or return 0;
print {$fh} JSON::PP->new->canonical->encode($data);
close $fh;
return rename( $tmp, $path ) ? 1 : 0;
```

The open is checked. The print and the close are not. So a write that runs out
of room writes a **truncated** temp file, and the rename promotes it over a good
one - and the function returns 1, so every caller believes it saved.

::: widebox
The processor's main page-cache writer has had checked print **and** checked
close since SM020, and the pre-beta promotion review singled it out for
approval: "disk-full drops the tempfile rather than serving a torn page". The
same repository had three writers without it.
:::

# Where it matters most

The durable day files are written **once** and never rewritten, because a past
day is immutable. A torn day file is permanent.

The export cache is the opposite: a torn cache fails to parse, is treated as
absent, and rebuilds. Slow, but correct. So of the three callers the one that
looks least dramatic - the durable store - is the one that could lose data for
good.

# How it spread

One of the three writers was added by [[SM393]], days before this was found,
written to match the two already there. That is how a defect becomes a house
pattern: the next person writing a similar function copies the shape, and the
shape is the bug.

There is now **one** checked writer and **one** rename in the file. The test
asserts that count, because three copies of an atomic write is three chances to
omit a check.

# The test, and what its first version failed to prove

The first version used `/dev/full`, and proved nothing. The writer appends
`".$$"` to the path, so it was opening `/dev/full.12345`, failing at **open** -
a branch that existed in the broken code too. Both sabotages of the print and
close checks passed against it.

`ulimit -f` makes the write itself fail, with no privileges and no mount. Two
cases, and the second is the one that earns its place:

- a large payload, where **print** fails
- a payload sized to sit inside Perl's output buffer, so print succeeds and the
  failure surfaces only in the flush that **close** performs

Without the second, a writer that checked print and not close passed everything.
That is the exact case the pair exists for, and it was invisible until the
sabotage matrix showed one of three sabotages not biting.

# Verification

`t/unit/plugins/17-a-failed-write-does-not-replace-good-data.t`, 15 assertions,
against three sabotages each confirmed to apply and still compile: restoring the
original unchecked write; checking print but not close; and detecting the failure
but renaming anyway. It asserts on **what is left on disk** - that the good file
still holds the old data and no temp file remains - rather than on the source.
