---
id: SM912
title: "SM912: the exposure probe cannot protect its own fixture, and a skipped probe is counted as a clean one"
subtitle: "SM901 refuses a read list that resolves to nobody. The SM283 self-probe's read list is a sentinel that resolves to nobody BY DESIGN - it is how the probe proves a protected file is withheld. So from 0.15.0 the probe cannot establish the state it measures on any site that has accounts, which is every real site. The fleet summary still printed 'probe: 1 clean, 0 exposed', because the probe exits 0 when it could not run."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-28 from the 0.15.0 deploy to edge, and REPRODUCED here the same hour with the discriminating measure: the probe's own acl_set call, run twice against the same code, differs only in whether one account exists. With an empty auth store it is accepted and moves content (ok, content_moved 1); with a single account it is refused, kind unknown-principals, nothing written. One account is the whole difference. Why the gate is green: SM901 deliberately checks nothing when the store knows nobody (Files.pm:1997) - a site being provisioned must be able to write a rule before it has accounts - and every probe fixture in t/ is in exactly that state, including t/integration/43, which runs the probe end to end against two real front ends. The suite therefore exercises the probe only under the one condition that exempts it from the check it now fails. P3 has a sharper edge than the other two: the rule the re-apply choked on names `agent-ai`, which is the very rule from the 0.14.4 W5b walk that MOTIVATED SM901."
raised: 2026-09-28
raised-by: release manager (the 0.15.0 fleet deploy to edge, --reapply-acls)
area: access control, check tooling, fleet deploy
---

# What happened

0.15.0 was deployed to edge. The run reported one site updated and, in the same
output, three things that belong together:

```
FAILED: zz-sm283 - The read list names nobody who exists: agent-ai. ...
  Nothing was changed.
[ warn ] ACL PROBE SKIPPED: the engine refused to protect the probe folder:
  The read list names nobody who exists: __lazysite-acl-probe-nobody__. ...
  probe:  1 clean, 0 exposed
```

The first is a re-apply of a stored rule being refused. The second is the SM283
exposure probe declining to measure, correctly, because it could not establish
its precondition. The third is the summary counting that as a clean probe.

# Reproduced, and discriminated

Not inferred from the output. A scratch harness makes the probe's own call -
`action_acl_set( '/zz-probe/', 'local', ['__lazysite-acl-probe-nobody__'], ... )`,
the literal from `tools/lazysite-check.pl:2820` - against two sites that differ
in one thing:

| The site's auth store | Answer |
| --- | --- |
| knows **nobody** - what every probe fixture in `t/` looks like | `ok`, `content_moved: 1` |
| knows **one account** - what every real site looks like | refused, `kind: unknown-principals`, nothing written |

One account is the entire difference. That is the discriminating measure this
finding needs: it rules out every explanation that is not SM901's check.

# Why the gate did not catch it

SM901's check exempts a store that knows nobody, on purpose and for a good
reason stated in its own comment: a site being provisioned has nothing to check a
name against, and refusing every rule there would make a rule impossible to write
before the first account exists.

Every fixture that exercises the probe is in that state. `t/integration/43` is
the one that hurts - it runs the real probe against two real front ends, one
honest and one serving statics off the docroot, which is the correct design for
that test - and its docroot has no accounts. So the suite drives the probe only
under the single condition that exempts the probe from the check it now fails.

**This is the vacuous-pass shape, and it generalises.** Any fixture that writes
an ACL without an account in the store is testing a code path with SM901 switched
off. That is worth a check of its own, and it is row P4 below.

# The rows

| Ref | Cx | What |
| --- | --- | --- |
| P1 | S | The probe can protect its own fixture again, on a site that has accounts. |
| P2 | S | The probe's exit code carries three answers rather than two, and the fleet summary counts them separately: ran and nothing exposed / ran and found exposure / could not run. |
| P3 | S | A re-apply of a stored rule is not refused for naming a principal who has since gone. |
| P4 | XS | A fixture that writes an ACL with an empty auth store is exempting itself from SM901; make that visible. |

## P1 - the probe needs a read list the store knows

The probe does not actually need "nobody". It needs **"not the anonymous
visitor"**, because the measurement is an anonymous fetch. Four ways to get
there:

| Option | Verdict |
| --- | --- |
| Name a principal the store knows - the first account in the store - and fall back to the sentinel when the store knows none | **Recommended.** No engine change; the fallback tracks SM901's own exemption exactly, so the probe is accepted in both worlds. The cost is that an existing account briefly holds read on a throwaway folder the probe then deletes. |
| Use `draft` instead of a read list | Possibly the better shape: "readable by nobody" is a state the engine already has a name for, and the probe would need no principal at all. **Needs checking first** - the probe's assertion is `content_moved`, and whether drafting moves content out of the docroot is the question that decides this. |
| Name the rule's own owner (`local`) | Does not work. `local` is the probe's synthetic identity and is not an account, so the same refusal applies. |
| Exempt the sentinel name inside the engine's check | **Refused.** A magic string that skips a security check is worse than the problem, and the next reader cannot tell it from a backdoor. |

The gate for P1 is the thing the suite was missing: run the probe against a
store **with** an account. A sabotage that removes the fix must fail that file.

## P2 - a skipped probe is not a clean probe

`t/tools/41-acl-probe-skip-is-not-a-pass.t` already holds this property for the
tool's own **words**, and the tool honoured it - it said SKIPPED, loudly. What
does not carry it is the **exit code**: the probe exits 0, and
`installers/hestia/lazysite-hestia-update-all.sh:775` reads the exit code and
nothing else, so a probe that could not run lands in `_probe_ok`.

Three states, three answers. The counting line becomes "N clean, N exposed, N
could not run", and a run with any in the third column is not a run that
certifies anything. Note that the CHECK counter in the same summary already does
this correctly - "0 clean, 1 with warnings or failures" - so the fleet script
already knows the shape; the probe's exit code is what does not supply it.

## P3 - refusing an idempotent re-apply protects nobody

SM901's ruling was about **authoring** a rule: "a login that will exist tomorrow
is a legitimate thing to write today; a list that reads to nobody can only be a
mistake". Re-applying a rule that is already stored is not authorship, and the
mistake - if it was one - was already made and already stored.

What refusing costs: `--reapply-acls` is the command that re-establishes
protection when content has drifted back into the document root, which is the
SM377 state where a rule exists and nothing was moved. On a site holding a rule
whose principal has since been removed, that command now fails at that rule. The
protection already in place is not lost (the engine changed nothing), but the one
tool that would repair a drift cannot run to completion.

Recommendation: when the incoming list is **identical** to the stored one, report
`unknown` and proceed. That keeps the refusal for every new authorship and
removes it from the one case where it cannot prevent anything.

The edge rule that hit this names `agent-ai` - the same rule from the 0.14.4 W5b
re-walk that motivated SM901 in the first place. It is still on that site, and it
is now the rule that stops the re-apply.

# What this does not claim

The engine's refusal is right, and SM901 is not being asked to soften for new
rules. Nothing was silently accepted and nothing was wrongly protected; both
surfaces said clearly what they had refused and why, which is why this filing
exists at all. The defects are that a tool's fixture is illegal under a rule
shipped after it, that one summary line collapses three states into two, and that
a repair command cannot run past a stale name.

# Related

[[SM901]] (the check, and the ruling it implements), [[SM283]] (the exposure this
probe exists to find), [[SM377]] (the probe must establish what it measures -
`content_moved`), [[SM285]] (the self-probe), [[TEST-PLAN-0150]] (T6's shape: a
deployed host is where this became visible),
[[feedback_vacuous_pass_on_empty_or_null]],
[[feedback_negative_finding_needs_a_discriminating_measure]],
[[feedback_a_boolean_has_four_states]].
