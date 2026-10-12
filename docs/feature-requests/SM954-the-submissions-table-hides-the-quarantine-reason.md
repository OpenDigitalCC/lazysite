---
id: SM954
title: "SM954: The submissions table shows \"quarantined\" without the reason"
subtitle: "The reason is stored in the row (_spam_reason); the table omits it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the sites agent, 0.15.2 edge walk R3 (owner's browser), 2026-10-07
area: manager
status-note: "SHIPPED (0.15.3): the reason is drawn as text beside the quarantined tag (it was only a hover title). t/unit/manager/180 runs the viewer code against a recording DOM and asserts the visible text; with the line removed it fails. The single-submission page already showed it."
---

# Measured

R3, edge, 0.15.2: a submission with two links was quarantined and stored with
`_spam_reason: 2 urls`. The Submissions view's Status column reads
"quarantined" and shows no reason, on the quarantine filter as well. The
documentation says the reason is shown there.

# Proposal

Show `_spam_reason` beside "quarantined" (escaped), on every view that shows the
status.

# Done when

A quarantined row shows its reason in the table; a test renders a quarantined
row and finds the reason.
