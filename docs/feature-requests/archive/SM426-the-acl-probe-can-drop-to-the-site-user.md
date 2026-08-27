---
title: "SM426: the ACL probe refuses as root, and the tool already knows how not to be"
subtitle: "The probe skips when run as root - correctly, because protecting content there would leave root-owned files in the site tree. But the CLI holds each site's owner in its registry and already drops to it with sudo -u for upgrades. The probe is the one command that asks the operator to do by hand what its sibling does automatically."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-20. cmd_probe now drops to the site's registered owner with sudo -n, exactly as upgrade --all does - the same mechanism, on the one command that declined to use it. Only when running as root AND the owner is someone else, so a non-root operator already running as the owner is not re-wrapped. sudo -n never prompts, so a host without the sudoers entry fails loudly rather than hanging a deploy, and the probe's own skip and stated cause come through unchanged where the drop is unavailable. Three sabotages bite: no drop, a prompting sudo, and an unconditional drop. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 from the operator's own deploy output: the health run ends 'NOT CONFIRMED ... run the probe as the site user', so the one check that establishes gating from OUTSIDE is the one a root deploy never gets. THE SKIP IS RIGHT AND STAYS - SM377 added it because protecting content as root leaves root-owned files in the site tree, which is a worse outcome than an unrun probe. What is missing is that lazysite-cli.pl ALREADY has the answer in the same file: the registry records owner= per site (/etc/lazysite/sites.d/<domain>), and `upgrade --all` drops to it with `sudo -n -u $owner --` under a comment calling it 'the only place root is allowed'. The probe does not do the same thing, so an operator running a routine root deploy is told to go and do manually what the command one screen up did for itself. SIZE: S - reuse the existing drop, not a new mechanism. CARE NEEDED: sudo -n must stay non-interactive and fail loudly (a misconfigured sudo becomes a skip with a DIFFERENT reason, which must still be reported rather than swallowed - SM385's whole point about summaries), and if the drop is unavailable the current skip and its stated cause must remain exactly as they are."
---

# What the operator sees

```
==> outside-in ACL probe (in-scope sites only)
  edge.explore.lazysite.io: NOT CONFIRMED
    [ warn ] ACL PROBE SKIPPED: running as root ... run the probe as the site user
0 verified, 0 exposed, 1 not confirmed.
```

The health check that surrounds it repaired two permissions problems and
reported 47 ok. The probe - the only part that measures gating from outside,
anonymously, the way a visitor experiences it - established nothing.

# Why it is worth fixing rather than documenting

::: widebox
The mechanism, the site owner and the precedent are all in the same file. This
is not "add sudo support to the CLI"; it is "use the drop the CLI already
performs, on the one command that currently declines to."
:::

An instruction to re-run something by hand, printed at the end of an automated
deploy, is a step that does not happen. SM366 is the standing evidence: the
probe has never been run from the field at all.
