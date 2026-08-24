---
title: "SM509: the manager sees the submissions the store holds"
subtitle: "The panel said 'No submissions yet' for a store the API read five rows from - same site, same file, same moment. A carve-out boundary bug wearing an empty-state costume."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED BY THE OPERATOR via the site agent 2026-08-24 (inbox filing, edge 0.10.28): the plugin-config panel showed 'No submissions yet' while form-submissions read total:5 from lazysite/forms/submissions/contact.jsonl; the Files app and WebDAV correctly refuse the tree, so the manager view was the only surface and it was wrong. ROOT CAUSE: the panel probes with action=list on the store DIRECTORY; _is_carveout's prefix test ('lazysite/forms/submissions/') matches only paths UNDER the store, so the directory itself fell through to the blocked-lazysite-tree deny, and the panel's catch-all rendered the refusal as an empty state. SHIPPED 0.10.30: the directory itself joins its own carve-out (boundary-safe - a name-superset sibling stays blocked), _is_submission_store_path answers for the directory too so the listing is capability-gated (read_submissions|manage_forms) exactly like the files in it, and configured stores (SM422) get the same dir-itself treatment. Clearing debris needs no new surface: with the view fixed, the existing per-row and bulk delete actions reach it. t/unit/manager/66 pins the boundary, the capability, and the exact listing the panel makes."
---

# The report

The operator, on edge 0.10.28: *"in the plugin config: No submissions yet
and i am blocked from forms in files."* Both halves true; the second is
correct behaviour. The API read five well-formed rows from the same store
at the same moment.

# The root cause

The panel probes `action=list` on the store **directory**. The carve-out
matched only `lazysite/forms/submissions/<file>` - the directory itself
fell through to the blocked-lazysite-tree deny, and the panel's catch-all
turned the refusal into "No submissions yet". An empty state and an error
state drawn identically: the operator had no way to distinguish "nothing
there" from "cannot look".

# The fix

The directory joins its own carve-out, boundary-safely (a sibling
name-superset stays blocked), and `_is_submission_store_path` answers for
it too - so the listing is governed by read_submissions|manage_forms
exactly like the files in it. Configured stores get the same treatment.
Clearing the debris needs no new surface: with the view fixed, the
existing per-row and bulk deletes reach it.
