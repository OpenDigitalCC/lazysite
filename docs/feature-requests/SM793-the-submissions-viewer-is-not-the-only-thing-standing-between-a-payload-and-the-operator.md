---
id: SM793
title: "SM793: the submissions viewer is not the only thing standing between a payload and the operator"
subtitle: "Security review, 0.13.8. The verdict is SAFE TODAY, and the filing is for the reason it is safe: form submission values are stored raw and returned raw, and the whole defence is one esc() in the manager's client-side viewer. A single future reader that forgets it - or an apostrophe-quoted attribute, which esc() does not cover - is stored XSS in the highest-privilege session on the site."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-11. THE CLIENT HALF IS BUILT, as the filing's first option: esc() covers the apostrophe. A sweep of every manager surface found the submissions viewer's esc() was one of five helpers short of it - config, nav, plugin-config and two in the manager layout (the command palette's was short of the double quote as well) - and two hand-written inline escapes in the editor, which now call the page's esc(). t/lint/132 pins the rule: any function on a manager surface that escapes < also escapes & > " and ', so which quote an attribute uses stops mattering and the next reader cannot write a four-character copy; seen to fail against the unfixed viewer. NOT BUILT, AND A DECISION: server-side escaping in action_form_submissions. The action is shared - the manager viewer, the control API's form-submissions and MCP's read_form_submissions all return it - so escaping there changes the DATA every token client reads (an agent would receive &lt; for <), where SM786 escaped at a sink that only renders HTML. The alternatives are escaping for the manager's call alone, or the viewer building its table with textContent so no esc() is needed at all; which is the release manager's call."
---

# The finding

Traced and reproduced by the review, and the result is a pass: a public form
value is stored with JSON escaping only, `action_form_submissions` returns it
raw with the comment "the client escapes", and the client - the submissions
viewer in `starter/manager/plugin-config.md` - passes every cell, header and
attribute through `esc()` before assembling HTML. The payload arrives inert.

The notification email is safe for a different reason: it is emitted as
`text/plain`, and `_notify_submission` carries the form name only. It becomes
exploitable the day an HTML body is added without escaping.

# Why file a pass

Because of where the safety lives. The server ships raw and one client-side
function is the entire defence, in the session that holds the most authority on
the site. Two specific ways it lapses: a future reader of the same data that
assembles HTML without `esc()`, and an attribute written with single quotes -
`esc()` escapes `& < > "` and not the apostrophe.

# What is asked

Escape server-side in `action_form_submissions` as defence in depth, so a raw
stored value is never the last line, and either extend `esc()` to the
apostrophe or state in the viewer that attributes are double-quoted only. This
is the same shape as SM786 and should be decided with it: escape at the sink,
every sink.

# Provenance

`inbox/2026-09-08-connector-answer-and-table-render-xss.md`, findings 2 and 3.
Accepted as a hardening filing rather than a defect - the current behaviour is
correct and the exposure is structural.
