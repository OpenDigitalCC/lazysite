---
id: SM788
title: "SM788: the start-time parse reads the field its own comment names"
subtitle: "Security review, 0.13.8. The bug is real and the comment proves it: _start_ticks says 'everything after the last )' and the regex takes everything after the FIRST ') '. A comm containing ') ' shifts every field, so the pid-reuse guard compares the wrong number. The filing's escalation claim does NOT hold, and is corrected here: anchoring earlier yields MORE fields, never fewer, so the value is wrong rather than undef - and _is_ours then fails closed, not open."
brand: plain
standard-margins: true
status: candidate
---

# The finding, and the part of it that is not true

`_start_ticks` (`Supervisor.pm:176-189`) reads the kernel start time from
`/proc/PID/stat` for the pid-reuse guard `_is_ours`. `/proc` stat is
`pid (comm) state ...`, the comm is parenthesised and may contain `) `, and the
regex `/\)\s+(.*)\z/s` is not anchored - so it matches at the **leftmost** `)`
followed by whitespace. The comment directly above it says "everything after
the **last** `)`". The code and its own declaration disagree, which is the
standing rule about a declaration the code ignores, and the comment is right.

Reproduced here on a synthetic stat line whose comm is `x) 9 9 9 9 9`:

    current parse field22 = 4
    last-paren  field22 = 209152295

**The filed severity story does not hold, and accepting it would have been the
error.** The brief says the mis-parse yields `undef`, that `_is_ours` reads
`undef` as "no /proc, pid is all we have" and returns true, and that the guard
is therefore disabled. Anchoring at an earlier `)` yields a **longer** field
list, never a shorter one, so `$f[19]` is a different field and essentially
never absent. The brief's own reproduction says `_start_ticks=0` - a defined
value, which makes `_is_ours` return **0**. The guard fails closed.

So: a real correctness defect in a security-relevant guard, wrong in the
direction of refusing rather than admitting, and benign for the daemon's own
children (a Perl child has no `)` in its comm, and spawn and check use the same
parse). Low.

# What is asked

Parse from the last `)`, which is what the comment already specifies:

    my $li = rindex( $line, ')' );
    return undef if $li < 0;
    my @f = split ' ', substr( $line, $li + 1 );
    return $f[19];

And a test feeding a stat line whose comm contains `) ` and asserting field 22
comes back - the test that turns the comment into a check.

Separately worth deciding rather than assuming: whether `_is_ours` should treat
an unreadable start time as NOT ours on a host where `/proc` is expected. That
is a fail-open default (`return 1 unless defined $now_ticks`), and it is the
four-states question again - "could not tell" is currently answered as "yes".

# Provenance

`inbox/2026-09-08-daemon-start-ticks-comm-parse.md`. The defect is accepted;
the escalation claim is rejected, with the reason above.
