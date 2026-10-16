---
id: SM1097
title: "SM1097: the bell is the one indicator of a new submission"
subtitle: "The Submissions menu entry no longer carries an unread-count bubble beside the bell."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.5 test plan, T8)
area: manager
status-note: "SHIPPED on n606: starter/lazysite/manager/layout.tt, the three manager stylesheets, style guide; t/unit/manager/202 and 204."
---

# What happened

The owner's observation from the manager in the 0.15.5 test plan:

    The menu's submission bubble does not say which form has the new
    submission, and the bell shows the same events: two indicators for one
    thing. One is wanted, not both.

SM957 gave the Submissions entry an unread count beside the bell's badge. The
release manager ruled: "bell stays".

# What shipped

The bubble is gone: the `<span id="mg-nav-subs-count">` in the menu, the
`setSubsCount` and `subsUnread` code in the bell's script, and the
`.mg-nav-count` rule in the three manager stylesheets and the style guide. The
bell is untouched; it still fetches `notices` for its own badge and panel, so
no fetch was removed. The `notices` endpoint still answers `unread_by_type`
(t/unit/manager/203 pins it), as other callers may ask.

t/unit/manager/202 now pins the bubble's absence in the menu, with and without
the notifications grant. t/unit/manager/204 (renamed, was "the submissions
count in a real browser") pinned the bubble; it now pins its absence and keeps
what the bell must still do in a real browser: count every unread notice, move
when a notice is followed from the panel or from a Submissions row, send the
mark as a POST, and be absent for an account the bell refuses.
