---
id: SM1234
title: "SM1234: the 0.15.15 stable candidate is promoted to beta"
subtitle: "0.15.15 walked clean on edge (V1-V9 PASS, no material finding), so its code is released unchanged on the beta channel as 0.15.16. This filing is the release's one entry: the release material refuses a release with no Unreleased entry."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, 2026-10-20 (\"Yes, beta.\"), after the 0.15.15 walk (lazysite/inbox, test-plan-01515-results)"
area: release
status-note: "SHIPPED (PENDING) on n716: no code change. The beta 0.15.16 carries 0.15.15's code; PATH-TO-STABLE step 4 (no material findings, promote to beta)."
---

# What was asked

The release manager, 2026-10-20, asked whether the stable candidate 0.15.15 should
move to beta after its walk: "Yes, beta."

docs/PATH-TO-STABLE.md, the sequence: "3. One test pass against the deployed build.
4. No material findings, then promote to beta. 5. Stable after that."

# The walk

The test plan lazysite-sites/inbox/2026-10-20-test-plan-01515.md was walked on edge
and in the OOM Lab on 2026-10-20, 18:10-19:10 BST: V1-V9 PASS, "No material
finding". It proved the fixes the candidate was cut for: H-1's empty app settings
(SM1209), the offline app's rows X2-X5 that H-1 had blocked (SM1197, SM1203,
SM1212), the empty front-matter key and the raw-page downgrade (SM1213), app
installs that keep the others answering (SM1211) and a write with no answer being
"not known" (SM1218).

# What shipped

No code. A published version is never re-cut, so the promotion is the next version
number cut on the beta channel from the same code, as 0.10.34 was 0.10.33's. The
release material (tools/release-material.pl) refuses a release whose Unreleased
section is empty ("there is nothing to release"), so this filing and its CHANGELOG
entry are the release's content: they record the promotion and the walk that
earned it.

# Not done

- Stable follows once the beta sites run clean; that cut needs the coverage stage
  (SM1083) and the stable gate's records signed (SM1231, held for 0.15.17).
