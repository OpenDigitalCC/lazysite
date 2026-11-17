---
id: SM1476
title: "SM1476: the container's site lists are paged"
subtitle: "lazysite-sites lists every site in one answer; at thousands of instances on a host the list and its status probes need pages."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the SM1361 build (an instance per site), split out by the release manager's ruling 275"
area: operations
status-note: "CANDIDATE, filed 2026-11-17 (ruling 275). Nothing built. Split from SM1361, where ruling 205 allowed paging only if it was small, and it was not."
---

# What is asked

SM1361 makes one instance per site and measured up to 160 sites on one container. The site
lists that `lazysite-sites` prints answer every site at once. At the scale SM1361 aims for, a
list should come in pages, with a stable order, so that an operator or a tool can walk it.

# What a build must keep true

- A list with no page asked for behaves as now for a small host.
- The order is stable between pages, so a site added during a walk is neither lost nor seen twice.
- A test that fails against the old code: a list of more sites than one page answers in pages
  that together name every site once.
