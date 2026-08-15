---
title: "SM319 - the deploy probe derives its pass from a positive signal, not an absence"
subtitle: "Reviewing SM317 an hour after it landed, the site agent found that a probe which fetched nothing was announced as 'front end honours the rule'"
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10, correcting SM317 in the same release. The pass now requires the probe to SAY it confirmed something. Reading the probe found FIVE outcomes and FOUR of them not a pass - the three non-fetching returns the report named, plus a PARTIAL ('could not vouch for some file types') and a no-answer ('nothing was served, gated or public') - so the suggested three-way branch would have fixed the reported three and left the other two lying in exactly the same way. Every non-fetching return now carries an 'ACL PROBE SKIPPED' token, a designated marker rather than incidental prose. A not-confirmed site does NOT fail the deploy: absence of evidence is not evidence of exposure. VERIFIED by t/tools/41, shown to fail against SM317 as committed."
---

# What was wrong

The verdict was derived from the absence of `[ FAIL ]`. `run_acl_probe` has paths
that report WARN and return before fetching anything - a bad URL, a docroot it
cannot write a probe folder into, an ACL store it cannot write - so a site in any
of those states was announced as honouring the rule with **no fetch having
happened**. The warn lines were printed only inside the FAIL branch, so the
operator saw no trace of it either.

# Why this one was worth interrupting for

**It is the defect this probe itself shipped with.** SM285's status note records
the first time: the extension list was scoped below the main body, so it was
empty - zero fetches, `0 == 0`, and a verdict of "the front end respects the ACL"
against a port with nothing listening. *A security check that passes by testing
nothing is the exact defect this programme exists to remove.* The tool was fixed.
The caller reproduced the shape one layer up, and this time across a fleet.

**The trigger is the state edge was in that morning.** A non-writable docroot is
what a Hestia vhost rebuild produces (SM270); a deploy runs right after a
rebuild; SM313 gives a second route via a store that cannot be created. So the
population silently absolved is exactly the population being probed for, which
converts an unknown into a false assurance.

# The rule, which is broader than the report asked for

Not "detect the skip" but **"require the confirmation"**. The pass branch matches
the line the probe prints when it has actually established something. Every other
outcome - today's four, and any added later - falls to NOT CONFIRMED, which is
the safe direction and needs no maintenance as the probe grows.

A not-confirmed site does not fail the deploy. It is an absence of evidence
rather than evidence of exposure, and failing on it would train an operator to
ignore the exit status, which is the only signal the real exposure has.

# Related

SM285 (the identical defect in the probe's own first implementation), SM317
(what this corrects), SM270 and SM313 (the two routes to the triggering state).
