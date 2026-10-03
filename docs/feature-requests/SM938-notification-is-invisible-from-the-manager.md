---
id: SM938
title: "SM938: notification is invisible from the manager - the bell cannot be acted on, and routing has no UI"
subtitle: "Two reports filed the same day by the same operator, and the second declares them one problem. The bell announces an event with no route to it and marks everything read when opened; and whether a submission reaches XMPP is decided in three places, only one of which has any interface."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-01
raised-by: sites agent (dhcf.eu, xisl.com, opendigital.cc), relaying an operator's own words
area: manager
status-note: "NOT YET RULED. TWO REPORTS, MERGED HERE BECAUSE THE SECOND SAYS SO: 'Same operator, same underlying problem: notification is invisible from the manager.' THE OPERATOR'S WORDS: 'the bell is confusing - it shows but doesn't do anything. can you file to dev agent, that it should show link to the thing that happened, and requires some kind of mark as read.' ONE HALF IS ANSWERED HERE AND THE ANSWER IS PARTLY AN UPGRADE. The reporter asked explicitly to be told, because from the operator's seat a fix and an upgrade are indistinguishable: measured in the current tree, a submission notice carries `url => '/manager/handlers'` (plugins/form-handler.pl, the line carrying the comment 'SM928 defect 4 - see the notify call'). On 0.14.4 the operator saw `/manager/plugins`, the Extension Manager, which is a page about extensions - SM928 moved it to the Handlers page, which is at least about forms. SO AN UPGRADE IMPROVES IT AND DOES NOT CLOSE IT: both are a manager SECTION, and the ask was the row that was submitted. Measured further: nothing in the manager pages addresses a single submission, so that half is an addressable submissions view rather than a changed string. The read-state half has no dependency and applies to the tree as read: a per-principal last-seen marker exists and works, and the only thing that sets it is OPENING the panel - so the badge is a has-opened-the-panel indicator rather than an outstanding-work one, which is the opposite of what a bell is for."
---

# RULED 2026-10-03

- **R17: a write control for `notify:`, in 0.15.2 (plan D4).** The text stays the
  source of truth: the control writes the form's `notify:` line through the
  existing writer, and D2's report then shows the result.
- **R18: B-1 in 0.15.2 (plan D5).** An addressable view of one submission, and the
  submission notice's `url` pointed at it.

# BUILT 2026-10-03 (PENDING)

Two of the three halves. **B-1 (a notice links to the thing that happened) is NOT
built**: no manager page addresses a single submission, so it needs an addressable
submissions view first.

- **B-2 (D3), all three asks, in the report's order.** (1) Per-notice read state:
  each notice has a stable id, and marking one leaves the rest alone. (2) An
  explicit "Mark all read"; opening the panel marks nothing. (3) Dismiss, as a
  second per-principal marker - the store keeps every line. Following a notice's
  link marks that notice read. A pre-existing marker (principal => epoch) still
  reads. `t/unit/lib/196`; seven sabotages each fail a named subtest.
- **H (D2), read-only.** The Handlers page shows, per form, the endpoints a
  submission notice reaches and, for each one it will not, the first thing that
  says no (the form's `notify: off`; `emit.submission: off`; a route without xmpp;
  the extension off, or its account missing or incomplete). It is computed by the
  checks delivery itself runs, and `t/unit/lib/197` runs a real delivery beside
  each case to show the report and delivery agree. Six sabotages each fail a named
  subtest.
- **What D2 does not do: change anything.** This filing records no ruling, and
  the work plan's "smallest change first" ranking is not written down here, so
  the shape built is the one the report's own condition allows without a ruling:
  text stays the source of truth, and the manager now shows what the text
  currently does. A control that WRITES `notify:` or `route.submission` would need
  a ruling.

# The operator's report, verbatim

> "the bell is confusing - it shows but doesn't do anything. can you file to dev
> agent, that it should show link to the thing that happened, and requires some kind
> of mark as read."

Both halves are the same complaint: the bell announces that something happened and
leaves the operator with no way to reach it or clear it deliberately.

**Grade: operator observation (A) plus source reading (A).** The reports are explicit
that there was **no reproduction on a test instance** - the observation is from two
production sites on 0.14.4 and the source reading is of 0.15.1.

# B-1. A notice should link to the thing that happened

The panel already renders a notice as a link when the record carries a `url` and as
an inert div when it does not (`starter/lazysite/manager/layout.tt:429-431`). So the
affordance exists and the question is what arrives.

**Answered here, by reading the current tree.** A submission notice carries
`url => '/manager/handlers'`. The history is recorded in the code: SM231 noted that
`url` "was recorded and discarded, and that one omission is most of what made a
notice hard to act on"; SM928 defect 4 then moved it off `/manager/plugins`, which is
what the operator saw on xisl.com on 2026-09-30.

So: **upgrading gets a better destination and not the right one.** `/manager/plugins`
was a page about extensions; `/manager/handlers` is at least about forms; neither is
the submission. And **no manager page addresses a single submission today**, so the
remaining work is an addressable view, not a changed string.

The same shape applies to `reset-request` and `service-degraded`: a notice that names
an event with no route to it.

# B-2. Read state is implicit, whole-list, and fires on open

A per-principal last-seen marker exists and is correct as far as it goes
(`Lazysite/Manager/Notices.pm`, `logs/notices-seen.json`, principal to epoch; unread
is the count of notices newer than the mark). The only thing that sets it is opening
the panel (`layout.tt:434`).

So opening the panel marks **everything** seen, including what is below the fold, and
there is no way to say "I have dealt with this one". The operator who filed this had
acted on none of them and had already lost the count.

The asks, in the reporter's preference order:

1. **Per-notice read state**, so marking one does not mark the rest - the one the
   operator is asking for;
2. **An explicit control** - "mark all read" in the panel - rather than marking on
   open, because "opening a list is reading it only when the list is short";
3. **A way to dismiss** a notice that has been dealt with, so the panel empties
   rather than growing. If the record must be kept, dismissal is a second marker and
   not a delete - the bell store is the record and should stay one.

# H. Routing has no interface

Whether a submission reaches XMPP is decided in three places: the extension and its
account, the site route (`route.submission: bell,xmpp` in `lazysite/notify.conf`),
and the per-form `notify:` state (`off` / `on` / `full`). **Only the first has any
UI** - the Extension Manager's XMPP settings form. A grep of the manager pages for
`notify|xmpp|XMPP` matches nothing.

So an operator cannot confirm from the manager that a form will announce itself, nor
diagnose it when it does not.

# What these filings do not claim

Both reports were explicit, and the sizes above respect it:

- **Not** that mark-as-read is absent. "It exists, per-principal, and is correct as
  far as it goes. The defect is that it is implicit and whole-list, which is a design
  gap, not a bug."
- **Not** that the panel never links. "It links when `url` is present; the question
  is whether it is present and correct."
- **Not** that notification is broken. "The path works; this is about it being
  unobservable."
- **Not** that `notify:` should move out of the form definition. "Text remains the
  source of truth; the ask is a control over it, not a relocation."

# Related

[[SM928]] (defect 4, which moved the url and is the reason half of B-1 is an
upgrade), [[SM231]] (the url recorded and discarded), [[SM918]] (an agent can read
the bell), [[SM919]] (the submissions table's own controls).
