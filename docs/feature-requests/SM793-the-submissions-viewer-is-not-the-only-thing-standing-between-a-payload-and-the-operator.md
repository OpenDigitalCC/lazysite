---
id: SM793
title: "SM793: the submissions viewer is not the only thing standing between a payload and the operator"
subtitle: "Security review, 0.13.8. The verdict is SAFE TODAY, and the filing is for the reason it is safe: form submission values are stored raw and returned raw, and the whole defence is one esc() in the manager's client-side viewer. A single future reader that forgets it - or an apostrophe-quoted attribute, which esc() does not cover - is stored XSS in the highest-privilege session on the site."
brand: plain
standard-margins: true
status: candidate
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
