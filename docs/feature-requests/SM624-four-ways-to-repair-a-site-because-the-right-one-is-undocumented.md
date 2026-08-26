---
title: "SM624: four invocations in field use for one job, because the verb built for it appears nowhere in OPERATOR.md"
subtitle: "Operator, repairing 31 sites after the 0.11.1 rollout: 'we have had many different ways to run fix - lets clean up old ways and have just one way to do it'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26), documentation and one signpost - NO code change to the repair path, because the code was already right. THE FOUR WAYS DO NOT DISAGREE: lazysite-check.pl is the engine, lazysite-fix-perms.pl says in its own header that it is a front-end to it 'keeping ONE implementation avoids the two drifting apart', and the CLI delegates to the same file. One implementation, four entrances. THE PROBLEM IS THAT THE SIGNPOSTED ONE IS UNSIGNPOSTED: `lazysite repair` runs the doctor, applies its fixes, then CHECKS AGAIN and reports the state after - which is the thing an operator wants after an upgrade - takes --all and --dry-run, and appears NOWHERE in OPERATOR.md. An operator who found any other door first had no way to learn it existed, so they built a shell loop, which is what happened. THE FLEET FORM WORKS ON THIS DEPLOYMENT SHAPE and the doc now says why: --all reads /etc/lazysite/sites.d, which `provision` writes and the TARBALL PATH NEVER RUNS, and SM329 already added the fallback to Hestia's own site list. Without that sentence an operator reads '--all walks the registry' and concludes it cannot help them - which is the same misreading SM321 was filed about and SM329 fixed in the code but not in the doc. ALSO CORRECTED: two Troubleshooting rows told the operator to `chmod g+w` by hand or re-deploy, for exactly the symptoms this verb repairs. AND A ROW ADDED for the connector that never asks for the connect code (SM621/SM622), since that cost the operator time twice today. TWO OF MY OWN ASSERTIONS WERE BLIND AND SABOTAGES CAUGHT BOTH: one matched /tarball/ which survived in an unrelated sentence after the caveat was deleted; the other grepped fix-perms' SOURCE for 'lazysite repair', which the COMMENT above the print also contains, so deleting the print passed. The second now RUNS the tool and reads its stderr - a tool's source containing a string is not the tool saying it, which is SM616's lesson arriving for the third time. My own tmp/postupgrade-sweep.sh, written earlier the same day before I found `repair`, is deleted rather than left as a fifth way."
---

# The four doors, and what is behind them

| Invocation | What it is |
|---|---|
| `lazysite-check.pl --fix` | the engine - per-site, you supply the paths |
| `lazysite-fix-perms.pl` | front-end to the engine, no fleet addressing |
| `lazysite check --all --fix` | the REPORTING verb, with a flag |
| **`lazysite repair --all`** | **fixes, then re-checks and reports the state after** |

# The command

```bash
sudo lazysite repair --all --dry-run     # preview
sudo lazysite repair --all               # apply
```
