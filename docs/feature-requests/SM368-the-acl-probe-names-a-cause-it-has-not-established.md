---
title: "SM368 - the ACL probe names a cause it has not established"
subtitle: "It reported \"the split is by FILE EXTENSION, which is a front end serving a static list straight off the docroot\". The split was a cache transient. The probe cannot tell those apart, and said which one it was."
brand: plain
status: shipped
status-note: "FILED 2026-08-18 after the site agent corrected a diagnosis I had relayed to the operator as fact. The probe's FINDING is sound - protected files were reachable anonymously - and only its explanation is wrong. But the explanation is what decides who has to act, and it sent the answer to the wrong person: a front-end template change needing an operator, when the truth was a cache window that clears itself. SHIPPED 2026-08-18 with the discriminator rather than softer wording, because the probe already had everything it needed to ASK. SM331 had already made it warm the folder before gating it - which is what creates the cached population it then misattributed - so the missing step was one file written after the gate and never fetched, and one request for it. Serves: the split is by extension, SM283, and an operator has a template to change. Refused: the extensions that served were the probe's own warm pass, SM331, it clears itself and there is nothing to do. That second case is now a WARN saying 'no action' rather than a FAIL telling an operator to apply a proxy template - which is what sent the field finding to the wrong person twice. Only runs when there is a leak to explain, so a healthy site pays nothing. Tested with two stub front ends, one per shape, because the whole point is which verdict is reached and a real front end can only be persuaded to do one of them."
---

# What the probe printed

```
[ FAIL ] a file the engine refuses is served to anonymous visitors:
         .png, .pdf, .txt, .css, .gz served, .dat refused - the split is by
         FILE EXTENSION, which is a front end serving a static list straight
         off the docroot
```

Everything before the dash is measured. Everything after it is inferred, and it
is stated in the same voice.

# What it actually was

The site agent's test:

```datatable
columns: Case | Result
widths: X | 4.4cm
bold: 1
tone: medium
---
all eight extensions, while public | 200
previously fetched, immediately after protecting | png pdf txt css gz xml = 200, dat md = 302
**written after protection, never fetched** (`late.png`, `late.gz`) | **302 on the first probe**
all eight, after the cache window | 302
---
```

The third row decides it. `.png` and `.gz` sit in the *served* set when
previously fetched and gate immediately when never requested. **An
extension-based rule cannot do that** - the extension is identical in both
cases. What differs is whether the front end already holds a descriptor. That is
[[SM331]]'s transient, it needs no operator, and it clears itself.

Corroboration pointing the same way: the split is not stable between runs.
`.xml` gated immediately one day and served in the same position the next. An
extension rule would not move.

# Why this matters more than a wrong sentence

**The explanation decides who has to act.** "A front end serving a static list"
is an operator task on a template. "A cache window" is nobody's task. The
rollout summary carried the finding up as a fleet condition needing a human, and
it was relayed onward as one - so a correct measurement produced a false
work item, twice, before somebody re-ran the experiment properly.

The probe is entitled to report what it saw. It is not entitled to name a
mechanism it has no way to distinguish, and the two live in one sentence with
nothing marking where the evidence stops.

# What would fix it

Report the observation, not the cause
: "these extensions served, these refused" is the finding. The next line should
  say what would tell the two candidates apart, not pick one.

Or make the probe able to tell
: the site agent's discriminator is cheap and decisive - write a file AFTER
  protection, never fetch it, and probe it. A front-end extension rule serves
  it; a cache transient gates it. That is one extra request and it converts a
  guess into a finding.

The second is better and is why this is filed rather than just corrected: the
probe already has the site, the ACL and the credentials, and the experiment that
settles it is smaller than the sentence that guesses.

# What IS true and unchanged

`X-Lazysite-Front` is absent on edge, so it is on a stock proxy template. Every
static is answered by the front end there, which is a real condition with real
consequences - see [[SM369]] - and it is not what this probe measured.

# Related

[[SM331]] (the cache window this actually was), [[SM283]] (the front end
answering by extension, which this was mistaken for), [[SM344]] (the rollout
exit contract that carried the finding up as a fleet condition), and
`inbox/archive/2026-08-18-validation-0.10.13.md`.
