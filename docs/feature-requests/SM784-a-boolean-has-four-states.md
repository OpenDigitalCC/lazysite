---
id: SM784
title: "SM784: a boolean has four states, and almost every one of them needs all four accounted for"
subtitle: "The release manager's rule, 2026-09-08: true, false, neither, and no answer. Not all four are always revealed - a caller without the credentials to know may be told less - but the LOG records the state that was really established, and the code must have decided what each of the four means before it ships."
brand: plain
standard-margins: true
status: candidate
---

# The rule (release manager, 2026-09-08)

> "The four states of binary should always be considered - true, false,
> neither, no answer. But not always revealed, so the log might record the
> real state even though a host without credentials gets less data. I find
> almost every boolean requires the four states accounting for."

Three distinct claims, and the third is the one that makes it a rule rather
than an observation:

1. **Four states, not two.** *True* and *false* are answers. *Neither* is a
   third answer - the question was asked and the subject is neither, which is
   not the same as false. *No answer* is the fourth - the question could not
   be asked at all.
2. **Revealing is a separate decision from establishing.** A caller may be
   told less than the engine knows, because of what it holds. That is a
   disclosure choice, and it must not corrupt the record: the log keeps the
   state that was really established.
3. **Almost every boolean needs all four.** So the default assumption is that
   a two-state boolean is under-specified, and the burden is on the code to
   show that the other two cannot arise.

# Why it is filed now

Two instances, three days apart, both found by the field rather than by us,
both the SAME collapse - *no answer* rendered as *false*:

- **SM768** - `has_secret: 0` for a secret that was on disk the whole time.
  The store could not be opened, so the answer was unknown; the reader said
  "not set". The fix gave it the third answer (`null`, with
  `secrets_readable: 0` and a warning naming the file and the unix user) and
  made every caller decide what "cannot tell" meant for it: the listing shows
  unknown, the writer refuses to write over what it could not read, the call
  refuses to go out without a credential it cannot see.
- **SM773, caught while building it** - the central check for a missing
  parameter tested *length* rather than *presence*, so `{"value": ""}` - the
  deliberate clear - was answered as if nothing had been sent. Absent is *no
  answer*; empty is *false*, and only the action knows what its false means.
  The check now asks the one question the action cannot: was it sent at all?

And the rule's second claim is already the shape of the engine's own
refusals: `whoami` tells a token client what it may do without telling it
what exists, while the audit trail records the whole fact.

# What acting on it would mean

- **A survey**, which is the work: every boolean the engine answers with -
  `has_secret`, `enabled`, `healthy`, `public`, `disabled`, `verified`,
  `exists`, `pending_schema`, `render_pending`, `mutating`, `cookie_only`,
  the capability map's every flag - asked the same four questions. Which
  produce *neither*? Which can be *unknown*, and what does the caller do
  then? Is the unknown currently rendered as false?
- **A vocabulary**, so the answers are consistent: JSON `true`/`false` for
  the two answers, `null` for unknown, and a named sibling field for
  *neither* where it exists (the pattern SM768 set with `secrets_readable`).
- **The disclosure split** stated once: what is established, what is
  revealed to whom, and the rule that the log always carries the former.
- **A lint** for the cheap half: a reader that returns a boolean derived
  from a store read must not turn an unopenable store into `false` - which
  is t/lint/121's rule (SM770) applied to the answer rather than to the log.

# The concept note, with the prior art

The portable version - with the traditions that each name a different
fourth state - is filed in the toolchain corpus as
`topics/api/four-states-of-a-boolean.md`: **Codd's** A-values ("missing but
applicable") and I-values ("missing and inapplicable"), which is exactly
*no answer* versus *neither* and which SQL never adopted; **Belnap-Dunn
FOUR**, whose fourth state is contradiction rather than inapplicability and
whose bilattice gives the vocabulary for a credential-gated answer (a move
down the *knowledge* ordering, with the *truth* ordering untouched);
**Verilog's** `Z`, which is "nobody is driving the line"; **open- versus
closed-world assumption**, which names the bug precisely - conflating no
answer with false is a CWA leak into an OWA context; and, for the
disclosure half, the **Glomar response** and **polyinstantiation**, with
the everyday 404-not-403. Read that note before starting the survey below.

# Scope

Held. This is a design rule with a survey behind it, not a defect, and it
should not be started inside a release that is already carrying four items.
The two instances it explains are fixed; the rule is recorded here so the
next boolean is designed with it rather than corrected after the field
finds the third instance.
