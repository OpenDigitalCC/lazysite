---
title: "SM386: the path scrub removed the one thing a caller could act on"
subtitle: "SM378 made the snapshot refusal say why; a partner agent then hit it for real and got a scrubbed detail that named nothing - the guard did not cover its own output."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.10.16 (8192654). RETROACTIVE FILING, written 2026-08-19 during the post-release pass alongside [[SM383]]'s: the fix landed with a changelog entry and no doc, and t/lint/26 flagged it the moment its entry left Unreleased for a release section. Facts restated from the commit; nothing new claimed. THE DEFECT: the scrub replaced the docroot with <site> and a generic absolute-path rule then matched the RELATIVE remainder, because its lookbehind excluded '<' and not '>' - so 'tar: <path>: Permission denied' reached the caller with the path gone, and they could not tell the private store from the render cache from a lock file. This is the detail SM378 existed to carry, removed by the sanitiser one layer down: a guard that does not cover its own output. NOW: relative always, absolute never - <site>/lazysite/cache/x and <private>/upcoming/a.pdf keep their shape; a path outside the site keeps only its tail. Nothing is disclosed a caller cannot already list. FIELD NOTE: the partner agent whose refusal triggered this went on to diagnose SM412 (the snapshot scoping) FROM the detail this fix restored - the carried cause paying for itself within days."
---

# Why this filing exists after the fact

Same reason as [[SM383]]'s, found by the same lint on the same day: a released
item without a feature-request doc has no findable "why". The status-note
carries the complete record; the source of truth is commit 8192654 and the
0.10.16 changelog section.

# The one-sentence lesson

A sanitiser is part of the surface it sanitises: if the diagnostic exists to
carry a path, the scrub must preserve the actionable shape of that path, or the
diagnostic is decoration.
