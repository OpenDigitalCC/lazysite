---
title: "SM370 - a byte-comparison test asserted something the payload stopped being able to satisfy"
subtitle: "Filed as an intermittent in the recount dry run. It was neither intermittent in the way described nor in that subtest: two writes a second apart differ in the SM341 timestamp, and a full byte comparison fails on the one field whose purpose is to change."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18, and the FILING WAS WRONG in both particulars before it was right. I recorded 'Failed test: 5' from a gate run without capturing which subtest that was, mapped it by counting to 'the recount reports before it writes', and reasoned from there to a frightening hypothesis - that the figure an operator reads before authorising a rewrite might not be deterministic. Reproducing it (1 failure in 40 runs) showed subtest 5 is 'the durable files are byte-comparable', and the cause is a one-second boundary moving the `generated` field. The fix normalises that field out of the comparison and asserts it is still present, so normalising cannot quietly become normalising away a field that stopped being written."
---

# What it actually was

```
got:      ..."generated":"2026-08-18T06:50:02Z"...
expected: ..."generated":"2026-08-18T06:50:01Z"...
```

Everything else in the two payloads is identical. The subtest writes the same
content twice and compares bytes; when the two writes straddle a second
boundary, the timestamp moves and the comparison fails.

# Why the test was right when it was written and wrong afterwards

[[SM339]] needs the durable files to be diffable: a repair somebody has to trust
must be checkable, and Perl's hash order is randomised per process, so the same
content written twice produced different bytes. Canonical ordering fixed that
and this subtest guards it.

Then [[SM341]] added `generated` to the payload - because a day file that cannot
say when it was produced cost a real claim in the field - and nobody revisited
an assertion that had quietly become impossible to satisfy. It passed 39 times
in 40 because a write usually takes less than the second it would need to fail.

**A test that is 97% true is not flaky. It is asserting the wrong thing and
being lucky.**

# The part worth keeping

I filed this from a gate summary line - `Failed test: 5` - without capturing
which subtest that was. I then counted subtests to map the number, landed on the
wrong one, and built a hypothesis on it: that `--recount`'s dry run might not be
deterministic, which would mean the figure an operator reads before authorising
a rewrite of their durable store is not the figure they get.

That hypothesis was worth writing down and was entirely wrong. The number in a
TAP summary is not the name of a thing, and I treated it as one - the same
mistake I had just filed [[SM368]] against the ACL probe for: a measurement and
an inference in one sentence, with the inference deciding what happens next.

Reproducing it cost forty runs and four minutes. Nothing else would have done.

# Verification

- The subtest passes 40 consecutive runs.
- The comparison normalises `generated` and nothing else.
- The payload is separately asserted to carry `generated`, so the normalisation
  cannot mask its disappearance.

# Related

[[SM339]] (the repair this diffability exists for), [[SM341]] (the timestamp that
made the old assertion impossible), and [[SM368]] (the same reasoning error,
found in somebody else's tool a day earlier).
