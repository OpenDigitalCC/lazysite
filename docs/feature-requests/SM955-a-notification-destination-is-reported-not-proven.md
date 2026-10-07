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
status-note: "RULED 2026-10-07 (release manager): the test button must report a delivery the server refuses - today it says sent when the server accepts a message to an invalid JID and bounces it after. Every delivery failure, test or real, is written to the audit log so it can be exported. WORK-PLAN-0153 R9."
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

# Ruling (2026-10-07)

The release manager: "the test button suggests all is well, even when target
jid invalid. this test button should report if this is the case. failures
should be logged in audit log so that they can be exported if required."

Measured in `Lazysite::Notify::test_xmpp`: it returns ok once the send
completes, and its message asks the operator to check arrival because "a
server can accept a message it then declines to deliver". An invalid
recipient JID is answered by a bounce (an error stanza) after the send, which
the test never waits for.

1. The test waits a bounded time for an error reply to its message and reports
   a refused recipient as a failure, with the server's reason.
2. Every delivery failure, from the test or from a real notice, is written to
   the audit log (channel, destination, cause), so it can be exported.

# Done when

A failed XMPP delivery shows on the form's row with its cause; a test with a
stand-in transport that refuses asserts it.
