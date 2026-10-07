---
id: SM955
title: "SM955: The Notifications section reports where a notice is meant to go, not whether it arrived"
subtitle: "With a wrong XMPP destination the form row reads \"announces to bell, xmpp\" and nothing arrives."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the sites agent, 0.15.2 edge walk R4 (owner's finding), 2026-10-07
area: notifications
status-note: "Owner finding 2026-10-07: a wrong XMPP destination still reads \"announces to bell, xmpp\". The row states configuration, not delivery. Related: SM932 (2) sink probe, scheduled R6. Needs a decision on what to show."
---

# Measured

R4, edge, 0.15.2: after the owner configured XMPP the form row read "announces
to bell, xmpp". With a wrong destination the row still read so and the message
never arrived. The owner: the page does not say when an XMPP destination is
wrong.

The row is derived from configuration (SM938 D3); nothing records whether a
delivery succeeded.

# Proposal

Record the outcome of the last delivery per channel (time, delivered or the
refusal) and show it beside the channel; offer a test send. Shares its shape
with SM932 (2), which writes a known line and reports which sinks received it.

# Done when

A failed XMPP delivery shows on the form's row with its cause; a test with a
stand-in transport that refuses asserts it.
