---
id: SM953
title: "SM953: A missing submission's message names the store file"
subtitle: "The single-submission view answers \"no submission <id> in lazysite/forms/submissions/contact.jsonl\"."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the sites agent, 0.15.2 edge walk R2 (owner's finding), 2026-10-07
area: manager
status-note: "Owner finding 2026-10-07: messages should not expose file paths. The message should name the form and the id only."
---

# Measured

R2, edge, 0.15.2: `/manager/submission?file=..&id=<unknown>` and the
`form-submission` action answer "no submission <id> in
lazysite/forms/submissions/contact.jsonl - it may have been deleted since the
notice was sent".

The owner: this should not expose file paths.

# Proposal

Name the form and the id: "no submission <id> on the form 'contact' - it may
have been deleted since the notice was sent".

# Done when

The not-found answer names the form and the id and contains no path; a test
asserts both.
