---
title: "SM317 - the deploy asks the front end, not just the engine"
subtitle: "SM285 built the outside-in probe because the engine's report and the front end's behaviour are different claims. Nothing ran it."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10, and REVISED WITHIN THE HOUR by SM319 after a site-agent review found that the first version read a probe which fetched nothing as a pass. Every rollout now ends with `lazysite check --check-acl` per site; DO_ACL_PROBE=0 skips it. It runs AS THE SITE USER (root-owned leftovers in a tree the CGI must write are the SM139 mistake), does not abort a fleet rollout midway (mixed versions are worse than the condition reported), and sets the exit status."
---

# Why

The engine's report and the front end's behaviour are different claims, and they
have now disagreed three times:

- **SM283** for weeks across a live fleet
- **SM296**, whose crash produced the same state
- **SM313**, whose repair looked complete and left it live - measured on edge
  after a successful docroot repair, eight of ten probed extensions still served
  200 anonymously from a folder with an active read list

The recurring shape, stated plainly because it keeps returning: **a rule can be
stored, honoured by the engine, reported as applied, and contribute nothing to
what an anonymous request receives.**

`lazysite check --check-acl URL` was built for exactly this in SM285. The tool
existed; failing it stopped nothing.

# Where it belongs

The release gate runs offline against a clean checkout of a tag, so there is no
deployed site to fetch and the question cannot be asked there at all. It is a
property of a SITE, not of a build.

The nomination asked for it in the gate. This is the same check at the only place
that can run it.

# Related

SM285 (the probe), SM283, SM296 and SM313 (the three disagreements), and SM319,
which corrects how this reads the probe's result.
