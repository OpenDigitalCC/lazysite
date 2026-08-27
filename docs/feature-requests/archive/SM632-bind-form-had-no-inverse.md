---
title: "SM632: `bind_form` created a registration that no token could remove, and a field agent left one on a live site"
subtitle: "Row R-12 of the capability-row campaign. `zz_r12_formflow` is still on edge.explore because the agent that made it had no way to unmake it"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26). THE ASYMMETRY: bind_form writes lazysite/forms/<name>.conf and there was no inverse on ANY token surface - nothing in the action registry, and delete_file refuses the path because lazysite/ is internal, correctly. So a capability a token may hold created an object no capability a token may hold could destroy, and registrations accumulated with nothing able to prune them: form-list counts a bound form with no store as a real form. Same create-without-delete shape SM578 closed for site packages, on a different object. FOUND HONESTLY: the field agent checked before and after precisely so the residue would be visible rather than silent, named it in its filing, and asked the operator to remove the conf. WHAT IT WILL NOT DO is the part the action is shaped around. A form with STORED SUBMISSIONS is refused - those are personal data, and removing the registration would leave them on disk and out of every listing: present, unreachable and invisible, which is worse than leaving the form alone. Deleting submissions stays interactive on purpose (SM214: a human confirms a destructive operation on personal data, often on the only copy). An EMPTY store is not a reason to refuse; there is nothing to orphan, and refusing there would re-create the very defect this closes. The row count comes from action_form_list, the SAME reader the listing uses, so a form cannot look empty in one and full in the other. Confirmation names the form, like data-table-drop - a destructive verb taking only an id is one an agent fires by having the wrong id - and a confirmation sent in the query string is told so rather than silently ignored (SM605). BOTH SURFACES AT ONCE: form-delete on the control API and delete_form on MCP, declared under manage_forms, recorded as twins, marked destructive and mutating in every table that has an opinion. A capability that advertises the create and not the destroy is how an agent concludes the object is permanent. SIX SABOTAGES, ALL FAIL - including the two that would quietly restore the original defect: an empty store blocking the delete, and stored submissions failing to. ONE OF MY OWN TESTS WAS VACUOUS AND A SABOTAGE SHOWED IT: the reserved-name assertions ran against a fixture where handlers.conf and smtp.conf did not exist, so removing the guard still failed with 'no such form' and the test passed for the wrong reason. THE RESIDUE ON EDGE IS STILL THE OPERATOR'S: this ships the tool, it does not reach into a live site."
---

# The asymmetry

| | Create | Destroy |
|---|---|---|
| MCP | `bind_form` | **none** |
| Control API | writes the conf directly | **none** |
| WebDAV | `lazysite/forms/<name>.conf` | refused - `lazysite/` is internal |

# What it refuses, and why that is the point

A registration whose form holds submissions is not deleted. The submissions
would stay on disk and vanish from every listing - **present, unreachable and
invisible**. That is a worse outcome than the residue this action exists to
clear.
