---
title: "SM501: the form timing window is fixed while the rate limit is per-form"
subtitle: "A submission must arrive within the 2-hour HMAC window; unlike rate_limit there is no per-form knob. Recorded from the field before it becomes a pattern - the reporter is working around it by design rather than asking for an exemption."
brand: plain
standard-margins: true
status: candidate
status-note: "RECORDED 2026-08-24 from the site agent, mid-specification of a gated data-entry app (~45 questions per page, an office team working carefully): a form submission must arrive within the fixed 2-hour HMAC token window, and for that workload crossing two hours is likely rather than exotic - and the failure lands on the person who has just typed a page of answers. NOT A REQUEST: the reporter is handling it in-spec with partial submission and shorter pages, explicitly declining to ask for an exemption because the last request of that shape (SM402-adjacent identity relaxation) was rightly refused, and one careful workload is not a pattern. WHY IT IS WORTH A FILING ANYWAY: rate_limit is per-form configurable and the window is not, so the two spam-family knobs have different reach for no stated reason; and the failure mode is regressive - it costs the most careful user the most typing. IF FIELD USE ELSEWHERE MEETS THIS: the shape to consider is a per-form window key with the current 2 hours as both default and ceiling-of-sanity documentation, plus the SM415 outcome-redirect carrying the typed values back on a timing refusal (which is the half that actually protects the person's work, whatever the window). DO NOT build on one report; this filing exists so the second report finds the first."
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
