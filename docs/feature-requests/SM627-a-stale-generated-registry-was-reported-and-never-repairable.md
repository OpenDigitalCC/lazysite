---
title: "SM627: a generated registry left in the document root was reported on every check and could not be repaired by any of them"
subtitle: "The second warning pinning all 26 sites into the worst bucket of a fleet repair"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (edge, 2026-08-26), alongside SM625 and SM626 and originally documented with them; filed separately so the ref can be cited on its own. A sitemap.xml, llms.txt, feed.rss or feed.atom left at the old path is resolved by the front end BEFORE the engine is consulted, so it keeps being served and nothing ever regenerates it - a sitemap frozen on the day of the upgrade, quietly. It was reported and never repairable, so it pinned every site alongside SM626's warning. THE ACTION IS NOT 'DELETE', which is why this took a decision rather than a patch: the engine deliberately yields to an operator's OWN sitemap or llms.txt, and NOTHING ON DISK SAYS WHICH KIND A FILE IS - the shipped templates emit no generator marker, so a generated registry and a hand-written one are indistinguishable. Deleting would have destroyed an operator's deliberate file silently, twenty-six times, on one fleet run. So --fix MOVES it to lazysite/backups/stale-registries/ with the time it was moved: the stale file stops being served, the engine serves a current one, and an operator's own file is recoverable by name. That is the recoverable-versus-irreversible line SM587 and SM591 drew for data, applied to a file - this tier may act BECAUSE what it does can be undone. MY OWN TEST CAUGHT A HOLE IN MY OWN SAFETY MECHANISM: the timestamp has one-second resolution, so two repairs inside the same second landed on the same name and move() would OVERWRITE, destroying the copy the whole design exists to keep. It never overwrites now."
---

# Why moving, not deleting

| | |
|---|---|
| Generated, stale | must not stay - it is served instead of a current one |
| Operator-authored | must not go - the engine yields to it on purpose |
| On disk | **indistinguishable** - no generator marker |
