---
title: "SM344 - a successful rollout reports failure and asks for a version bump"
subtitle: "0.10.12 installed on the one site that could take it, verified against its manifest, and was confirmed working from outside. The rollout reported failure, and the deploy watcher told the operator to bump the version and retry - which cannot fix what was actually wrong and burns a version number to find that out."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17 as part of [[SM345]] (commit 1ab6098) and left marked candidate by mistake - the fix landed in the same commit as the scope containment, and only the filing that owned that commit got flipped. `update-all` separates the two facts one bit was carrying: 1 = the rollout FAILED and a retry is meaningful; 2 = the rollout SUCCEEDED and the fleet has findings a human must look at. The deploy watcher was updated to match, so a working release is no longer announced as a failure with advice to burn a version. FILED 2026-08-17 from the 0.10.12 edge rollout, which installed and verified on every site that could accept it and still exited non-zero because 22 sites on an older line were exposed - conditions no retry of that deploy could change."
---

# What happened

```
VERIFY OK: installed code matches the manifest for 0.10.12.
...
 0 verified, 22 exposed, 1 not confirmed.
1 clean, 1 repaired, 21 need a human.
...
Deploy of 0.10.12 failed; skipping (bump again to retry)
```

Everything above the verdict says the deploy worked. The deploy worked. The
verdict says it failed and names a remedy that cannot help.

# The chain

`lazysite-hestia-update-all.sh` ends with four independent reasons to exit 1:

```bash
[ "${#FAILED[@]}"       -gt 0 ] && exit 1   # a site's install failed
[ "${#PROXY_FAILED[@]}" -gt 0 ] && exit 1   # a proxy move failed
[ "${REPAIR_RC:-0}"    != 0 ]   && exit 1   # a site needs repair
[ "${ACL_PROBE_RC:-0}" != 0 ]   && exit 1   # the probe found an exposure
```

The deploy watcher then treats any non-zero as a failed deployment and prints
`bump again to retry`.

**The first two are rollout failures. The last two are fleet conditions.** A
site that needs repair, or that serves protected content because it is on an
older line, is in that state before the rollout starts and stays in it
afterwards. Re-running the deploy changes nothing, and bumping the version to
re-run it burns a version number to discover that.

`[[SM317]]`'s reasoning for making an exposure non-zero is sound and should not
be reverted: a fleet caller that only reads `$?` must not miss an exposure. The
defect is that one bit is being asked to carry two facts, and the caller that
consumes it has to guess which.

# What it costs

**A real failure becomes unreadable.** After one run of this, the operator
learns that "failed" does not mean failed. The next genuine install failure
arrives wearing the same words.

**The advice is actively wrong.** "Bump again to retry" is correct for a
transient install fault and incorrect for everything else the status now covers.
Following it burns a version - and this project's own rule is that burned
versions are never reused.

**It hid a real result.** 0.10.12 was deployed, verified and independently
confirmed working from outside. The rollout that achieved that reported failure.

# The fix

Separate the two facts:

```
0  rollout succeeded, fleet clean
1  ROLLOUT FAILED - a site's install or proxy move failed; a retry is meaningful
2  rollout succeeded, FLEET FINDINGS - repairs needed or exposures found;
   a retry changes nothing, a human is needed
```

The summary line should say which it is in words as well as in status, because
the log is what an operator actually reads.

The watcher side is the operator's own script and not this repository's to
change, but the corresponding change is small: treat 2 as deployed-with-findings
- advance the version, report the findings, and do not suggest a bump.

# Verification

- A rollout where every site installs cleanly and the fleet has pre-existing
  exposures exits 2, not 1, and says so in words.
- A rollout where a site's install fails exits 1 and says a retry is meaningful.
- The exposure is still visible to a caller reading only `$?` ([[SM317]]'s
  requirement is preserved).
- No path suggests bumping a version for a condition a bump cannot change.

# Related

[[SM317]] (which made an exposure non-zero, correctly, and is the half this
keeps), [[SM319]] (a probe that measured nothing must not read as a pass - the
same distinction pointed the other way), [[SM321]] (`repair` and `probe` as
verbs, whose exit statuses feed this), and `inbox/lazysite-deploy.sh`, the
watcher that consumes the status.
