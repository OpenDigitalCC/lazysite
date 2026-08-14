# Dimension 5 - Reliability and resilience - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: WARN (2026-08-14, at 0.10.8)

## Verdict

**WARN**, unchanged. The rehearsal cadence the declaration mandates has still
lapsed. What did change is that it is now **enforced**: the release gate blocks
a stable promotion on it, so this cannot be carried silently into a stable cut
the way it was carried through four of them.

## Findings

### F5.1 - The restore-rehearsal commitment is still lapsed (WARN, carried)

Newest entry in `docs/RELIABILITY.md` remains **2026-07-12**, older than the
last stable cut of 2026-07-27. Five stable-eligible cycles have now passed
without one.

**Now mechanised.** `lazysite-compliance.pl` compares the newest rehearsal
against the date of the newest STABLE release - which is what the declaration
actually promises, rather than a fixed window that would have passed this tree.
On the stable channel it blocks:

```
FAIL restore rehearsal: newest is 2026-07-12, older than the last stable cut
     (2026-07-27) - the declaration requires one per stable release cycle
```

The remedy is half an hour of one person's time. The previous review projected
it as done for this release; nobody's half hour was allocated, which is the
projection finding in the overview.

### F5.2 - The monitor requirement is reassigned, and the reassignment shipped (improved)

A `docs/MONITORS.md` in this repository was always the wrong artefact - what to
monitor is a property of a deployment. The requirement now sits in
`docs/compliance/OPERATIONS-TEMPLATE.md` section 5, which the operator fills and
signs, with a review row in the maintenance template. Both are packaged in
`lazysite-common`, enforced by `t/lint/41`, so an operator installing from the
deb receives them.

What remains genuinely build-side is the capacity test, still not written.

### F5.3 - The relay is bounded, which is the resilience property that mattered (PASS)

SM294 puts a forked child in the request path of a persistent worker. The
failure mode that would matter is a worker blocked forever on a wedged child,
which serves nothing else - one hung request taking a site down.

Bounded by `RELAY_TIMEOUT` (120s, configurable), after which the child is TERMed
then KILLed and the worker answers 504. `local $SIG{CHLD} = 'DEFAULT'` so the
process manager's reaper cannot consume the exit status and leave `waitpid`
blocking, and `IO::Select` pumps both directions so a large body cannot deadlock
against a large response.

### F5.4 - The failure mode SM296 broke is now tested (PASS)

The private-store design specified that a failed move must warn rather than
refuse the rule. That behaviour existed and was unreachable. It now has a test
that exercises it directly, which is the resilience lesson the previous review
drew: a declared failure mode with no test that exercises it is a comment.

## Evidence

- `docs/RELIABILITY.md` rehearsal register - newest 2026-07-12.
- `perl tools/lazysite-compliance.pl --check --channel stable` - 3 blocking,
  including the rehearsal.
- `lazysite-processor.pl` - `RELAY_TIMEOUT`, `$SIG{CHLD}`, `IO::Select`.
