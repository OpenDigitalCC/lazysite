---
title: "SM274 - check --fix repairs the content directories, or says why it will not"
subtitle: "SM246's third consumer. The model is applied and verified; repairing an existing directory needs a decision, not more code."
brand: plain
status: candidate
status-note: "SPLIT from SM246 on 2026-08-11. SM246's four deliverables are complete - the incident explained, one declared permission model, the fresh-vs-upgrade policy declared, the CGI-writable file list declared once, and 0.10.5 added `check` verifying the whole declared directory set. This last third is BLOCKED ON A DECISION rather than on implementation, which is why it is its own filing: holding a four-deliverable request open for one undecided question misrepresents both."
---

# SM274 - the repair third

## Where SM246 got to

"One table, three consumers: install applies, check verifies, check --fix
repairs." Two of the three are true. `install.pl` applies the declared
mode on creation; `lazysite-check` verifies the whole declared set against
the recorded install state.

`--fix` repairs the CGI-writability set and the docroot (SM270), and
deliberately does NOT touch the other declared content directories. It
reports them and prints the `chmod`.

## The decision this needs

**Should a tool an operator ran to ask a question change permissions on a
live site?**

The argument for repairing: the model exists to be true. A directory that
has drifted from its declared mode is drift, and leaving it reported but
unrepaired means the operator does by hand what the tool could do
correctly - which is how the 0.6.5 incident happened in the first place.

The argument against: these are content directories on a running site. An
operator who tightened one deliberately - because that subtree holds
something they wanted locked down - should not have it widened by a
diagnostic. The permission model describes what the installer creates, not
what the operator must keep.

**Both arguments are good, which is why this is a decision and not a
task.**

## Options

**A. Repair, with the same confirmation --fix already implies.** Simple,
consistent with how --fix treats everything else, and it means running the
diagnostic is not safe on a site with deliberate local tightening.

**B. Repair only what is DEMONSTRABLY drifted from the install state**, not
merely different from the model - i.e. the recorded mode at install time
versus now. Narrower, and it distinguishes "the installer made this and
something changed it" from "the operator chose this".

**C. Keep report-only, and say so in the docs.** What 0.10.5 does. The cost
is that the design's own sentence stays two-thirds true.

I would take B if the install state carries enough to tell the two cases
apart, and C otherwise. A is the one I would not take: a tool that widens
permissions as a side effect of being asked a question is a tool people
stop running.

## Acceptance

Whichever option: `docs/architecture` and the `--fix` help text must state
plainly which directories --fix will and will not touch. The current
behaviour is correct and undocumented, which is the part that will confuse
someone.

## Related

SM246 (the model and the other three deliverables), SM270 (the docroot,
which --fix does repair, because that one is "the site does not work").
