---
id: SM1274
title: "SM1274: Dismiss all empties the notices panel"
subtitle: "\"Mark all read\" marked every notice read and left them all in the panel, so it never emptied. It now dismisses them as well: every notice is read and out of the panel, and stays in the store as a single dismiss leaves it. The control is called Dismiss all."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 26 (2026-10-23)"
area: manager
status-note: "SHIPPED (0.16.3) on n732: notices-seen with no id dismisses, by id, every notice the caller's bell holds (the operators' and a member's me-notices-seen alike); the store is untouched; a later notice is unread. The manager panel and the account bell call it Dismiss all and empty the list; the manager offers it while the panel holds any notice. t/unit/lib/208, 196, t/unit/manager/204."
---

# What was asked

Ruling 26 (2026-10-23): in the manager's notices panel, "Mark all read" also DISMISSES.
It marks everything read and takes it all out of the panel. The notices stay in the
store, exactly as a single dismiss leaves them (SM938 D3). A notice that arrives after it
appears in the panel as unread. The count and the panel agree after the action and after
a reload, which is SM1100's defect (the bell cleared on screen and came back on the next
page), not to be regressed.

# What shipped

- **`Lazysite::Manager::Notices::action_notices_seen`** with no id now marks the
  caller's dismissed set with every notice in their bell. Dismissed implies read, so
  everything is read and out of the panel.
  - **By id, not by time.** The `mark` timestamp it used to advance is left as it was. A
    notice appended in the same second afterwards is not among those ids, so it arrives
    unread. Before, `ts <= mark` would have marked it read.
  - **Bounded as before.** The ids drop out of the marker when they age out of the window.
  - **Saved as before.** The marker is still written through SM1100's sibling-and-rename,
    so the mark is kept or the reply says it was not.
- **Both bells.** The operators' bell (`notices-seen`) and a member's own
  (`me-notices-seen`, `addressed_only`) call the same function, so both get it.
- **The manager panel** (`starter/lazysite/manager/layout.tt`):
  - the control is **Dismiss all**, titled "Mark every notification read and remove it
    from the list". The old label no longer said what it does, and Dismiss is the
    panel's word for taking one out;
  - it is offered whenever the panel holds a notice, read ones included. It used to show
    only while something was unread;
  - on success the list empties and the badge takes the reply's count.
- **The account bell** (`account-bell.tt`) is relabelled the same way, keeping its
  `data-ls-mark-all` attribute for layouts that override it. It re-reads the list after
  the call, so it empties.
- **Docs:** FEATURES.md, the Submissions guide, `starter/docs/manager.md`, and
  `starter/docs/auth.md` ("read, dismiss, and dismiss all").

# Tests

- **t/unit/lib/208** (new):
  - after Dismiss all, the reply's count is 0;
  - a fresh read finds the panel empty, the count 0 and three notices dismissed, with
    the store byte-identical;
  - a notice appended afterwards, in the same second, is the one notice in the panel,
    unread, and the count is 1;
  - another operator's panel is untouched;
  - a member's Dismiss all empties their own bell.
- **t/unit/manager/204**, a real browser against the panel:
  - after Dismiss all, no notice is left and the panel says there are none;
  - with every notice already read, Dismiss all is still offered.
- **t/unit/lib/196**: mark-all now takes the notices out of the panel, and the panel
  offers "Dismiss all".

With Notices.pm and layout.tt at n731's tip:
- t/unit/lib/208 fails 3 of its 4 subtests. The fourth, "another operator's panel is
  untouched", holds either way. "The store is unchanged" is an assertion inside the
  first subtest, which fails.
- t/unit/manager/204 fails the three new assertions.
- t/unit/lib/196 fails the two changed subtests.

# Not done

- No separate "mark all read, keep them listed" control: the ruling replaces it.
