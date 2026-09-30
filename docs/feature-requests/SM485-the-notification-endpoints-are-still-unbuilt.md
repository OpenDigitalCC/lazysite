---
title: "SM485: the notification endpoints are decided and unbuilt"
subtitle: "SM281 answered the addressing question and shipped that answer. The three pieces of work it unblocked have not been started, and were being carried on a filing whose status said otherwise"
brand: plain
standard-margins: true
status: partial
status-note: "SMTP ENDPOINT BUILT 2026-09-29 on claude/n196-a-notice-can-reach-you-by-mail (stacked on the post-landing bookkeeping). REPRODUCED FIRST: notify() built its record from a fixed key list, so a `to` passed by a caller was DROPPED SILENTLY - every notice was a site-wide broadcast and the bell was the only endpoint reachable without a chat server. BUILT TO THE RULING, clause by clause. `email` joins `bell` and `xmpp` as an endpoint on the routing mechanism that already existed, so there is no second place to say where a notice goes. `to` NAMES AN ACCOUNT, NEVER AN ADDRESS - the address is read at delivery from the account's own record - so nothing a caller passes can point the site at a stranger, and THAT is why the per-site hourly bound is sufficient where SM877 needed a per-recipient cap too: its addresses are typed by visitors, these cannot be. Both switches are real and neither implies the other - the site says which TYPES may leave by mail, the person says whether THEY want mail - and no type is routed to email by default, so an upgrade cannot start a site writing to anybody. A BROADCAST REACHES NOBODY BY MAIL, which is both the ruling and what falls out of the code: there is no addressee to look up. The transport is the Form SMTP extension over its --pipe interface, and when it cannot send the reason names WHICH of three things is wrong (not installed / switched off / no settings saved) rather than \"mail failed\" - a sysop reading the log needs to be sent to the right place. A notice that did not become an email does not fail the call: the bell already has the record, and losing a notice because a mail server was unreachable is the wrong trade. THE OPT-IN is a per-account BOOLEAN, notify_email, and deliberately not an address: the only thing a person can change is whether mail goes where their account already points. It is the SECOND setting to pass SM724's test for self-service (grants nothing, confines nothing, audits nothing), which is what turned that hardcoded single-key carve-out in tools/lazysite-users.pl into a named list with the test written beside it - a third key has to argue the same three things. The hourly count has its OWN record file (logs/notice-mail.jsonl, its own Stores.pm entry) rather than sharing the form handler's: a busy contact form silencing the sysop's notices is the last thing you want, and an unreadable record returns undef so within_caps REFUSES rather than reading \"could not tell\" as room to send. The address is never written to that record, for SM877's reason - a file of addresses is a mailing list, and this one would be a list of the site's own operators. t/unit/lib/55, ten subtests, five sabotages; one earned an extra assertion, because removing the broadcast guard changed no behaviour (the recipient lookup refuses an empty login anyway) but did change the REASON a sysop reads, so the test now pins the reason and not only the silence. AND IT WALKED INTO A LIVE DEFECT, filed as SM915: SM817 renamed the extension list to `extensions:` and said both spellings open the same one, and Notify accepted only the old name - so on a site using the new spelling it reported every extension disabled. XMPP NOTICE DELIVERY HAS BEEN SILENTLY OFF ON THOSE SITES SINCE THE RENAME. Only that one reader is fixed here; three others are wrong and one of them WRITES a second list, which needs a ruling. TABLE CORRECTED: the notice-store read surface is not \"not started\" - its control-API half shipped, and its MCP twin is a recorded deferral in t/lint/23 waiting on exactly the addressing that shipped today, so it is now unblocked and wants a parity ruling. STILL OPEN on this filing: that MCP twin, and agent messaging, which SM231 declined and this does not revisit. PREVIOUSLY: CARVED OUT OF SM281 ON 2026-08-23. SM281's own content was the ADDRESSING DECISION, the last of SM231's two open questions, and it went out with the 0.10.14 cut. What it explicitly did not do is the work that decision unblocks, and its note said so twice: 'the decision unblocks the work, it is not the work'. Carrying both on one filing produced a status nobody could set correctly: marking it done hides three unbuilt pieces, `candidate` denies a released decision, and `partial` is a state that never resolves. THE DECISION, RESTATED SO THIS FILING STANDS ALONE: a notice gains an optional `to` naming an account or a group; a notice WITHOUT one stays broadcast exactly as today, so nothing that emits a notice now has to change. That closes the per-user delivery gap Notify.pm has flagged since SM136. THREE PIECES, SIZED WHEN THE DECISION LANDED: the SMTP endpoint (S), the notice-store read surface (M, and an SM239 parity item in its own right), and the `to` field itself, which touches both. NOT INCLUDED, and deliberately: the agent-messaging door SM231 declined to build. That was a decision, not an omission, and it stays declined until somebody argues otherwise."
---

# What shipped, and what did not

```datatable
columns: Piece | State
widths: 7cm | X
bold: 1
tone: medium
---
The addressing decision (`to`, optional, broadcast when absent) | **done**, with the 0.10.14 cut -- see SM281
The SMTP endpoint | **shipped 2026-09-29** -- a notice names an account and reaches it by mail
The notice-store read surface | **DONE 2026-09-30, see SM918.** The control-API half shipped first (`notices`, `notices-seen`, gated on `notifications`); the MCP twin `read_notices` shipped under the ruling FULL PARITY, THE CAPABILITY IS THE GATE, and `t/lint/23` now carries the pairing instead of the deferral. One reader serves both doors (`Lazysite::Manager::Notices`), and moving it repaired a four-state fault: an unopenable store had been reading as an empty bell. `notices-seen` stays one-sided on purpose -- a per-partner read cursor is the first half of an inbox, and machine-to-machine is SM646's XMPP connectors
The `to` field itself | **shipped 2026-09-29** with the endpoint, because a broadcast reaches nobody by mail and so the transport had nothing to send to without it
Agent messaging | **declined** by SM231, and still declined
```

# Why it is a separate filing

SM281 was marked `partial`, which is a status that never resolves: its own
subject is finished and the work it unblocked is untouched. A reader checking
whether notifications were delivered got a filing that said *some of it* -- and
the some that shipped was a paragraph of reasoning, not an endpoint.

Splitting it costs one number. It buys a filing that can be closed when the
endpoints exist, and a decision that is recorded as done because it is.

# WHAT THE SMTP ENDPOINT IS HAS NOT BEEN DECIDED (2026-09-28)

Taken off the overnight list and stopped here. The table above sizes the SMTP
endpoint at **S**, and the size is the only thing about it that is settled -
the filing records the ADDRESSING decision and nothing about delivery. Four
questions, and each changes what gets built:

1. **Which notices leave by email?** All of them, the ones a sysop opts into,
   or a declared subset? Every notice by default is a mail for every form
   submission on a busy site.
2. **Who is the recipient when `to` is absent?** A broadcast notice has no
   address. The bell can show it to everyone who logs in; an email cannot be
   sent to everyone without a list, and a list of every account's address is a
   different thing from a notification feature.
3. **Which transport?** The Form SMTP extension owns `lazysite/forms/smtp.conf`
   and is an extension a site may not have enabled. A notice endpoint that
   depends on it inherits that, and one that does not means a second mail
   configuration - which is the shape SM842 spent a release removing.
4. **What bounds it?** [[SM877]] built per-recipient and per-site hourly caps
   for the form handler's acknowledgements, for the reason that a site writing
   to addresses it did not choose is an open relay in miniature. A notice
   endpoint sends to accounts rather than to strangers, so the reasoning is
   weaker - but "unbounded" should be a decision rather than the default.

**RULED 2026-09-29**, and it is the recommendation below: **opt-in per
account** (the person decides whether their notices reach them by mail),
**the Form SMTP extension as the transport**, with a refusal that names it
when it is off, and **a broadcast notice delivered to nobody by mail** - it
is a bell item, and a list of every account's address is a different feature
from a notification one. No second mail configuration, which is what SM842
spent a release removing.

What that leaves to build: the opt-in (an account preference), the send, and
the refusal when the extension is off. The caps question answers itself
under this shape - an opted-in account is not a stranger, so SM877's
open-relay reasoning does not carry, and the per-site hourly bound is the
one worth keeping.

As recommended before the ruling: opt-in per
account (the person decides whether their notices reach them by mail), the
Form SMTP extension as the transport with a refusal that names it when it is
off, and a broadcast notice delivered to nobody by mail - it is a bell item.
That is a recommendation and not a design.

# The decision, so this stands alone

A notice may carry an optional `to` naming an account or a group. A notice
without one is broadcast, exactly as today -- backward-compatible by
construction, so nothing that emits a notice now has to change.
