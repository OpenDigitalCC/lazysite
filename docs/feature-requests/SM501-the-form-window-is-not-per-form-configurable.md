---
title: "SM501: the form timing window is fixed while the rate limit is per-form"
subtitle: "A submission must arrive within the 2-hour HMAC window; unlike rate_limit there is no per-form knob. Recorded from the field before it becomes a pattern - the reporter is working around it by design rather than asking for an exemption."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). `timestamp_window` is per form, in the form's config, defaulting to the shipped 7200 seconds so every existing form is unaffected. `off` removes the AGE CEILING ONLY - the HMAC must still match, so a timestamp cannot be forged or lifted from another form, and the three-second too-fast floor still applies. Both of those are asserted in t/unit/manager/139 and sabotage-verified, because a test proving only that a wide window accepts an old submission would pass against a check that had been deleted. The reporter asked for no exemption and worked around it; this is the design sketch the filing recorded, built when the second case arrived."
---

# The observation

Form submissions carry a timestamp+HMAC pair minted at render; the handler
refuses a pair older than two hours. `rate_limit` is per-form configurable;
the window is not. For a long careful form, crossing two hours is the
ordinary case, and the refusal lands after the typing.

# Why recorded rather than requested

The reporter's own words: handled with partial submission and shorter pages;
no exemption asked. One workload is not a pattern - this filing exists so the
second report finds the first, with the design sketch already thought
through (per-form key defaulting to today's value; and note the real
protection for typed work is a failure path that carries values back,
which is SM415's territory, not the window's).
