---
title: "SM849: the page editor has no way into that page's history"
subtitle: "Release manager, 2026-09-11, on 0.13.12: when content history is enabled, editing a page should offer its history"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. The editor's toolbar offers History when git-status says content history is on, and not for a new file, which has no versions yet. It is the route the filing asked for: it opens /manager/files?path=<folder>&history=<file>, and Files, once the folder is listed, turns to the list page holding the file, opens its row and opens its History panel - the one View, Diff and Restore implementation, not a copy. A file not in the folder, or history switched off since, is said so in the status bar. Leaving with unsaved edits is caught by the shared dirty guard."
---

# As reported

In page edit there should be access to the page's history, when content history
is enabled.

Recorded as reported and not yet re-measured.

# The shape

The history already exists per file - Files' row panel offers History, Diff and
Restore - so this is a route, not a feature: from the page being edited, to the
same panel for that page. It should appear only when the content history
extension is on, which the editor can ask the same way Files does.

# Related

SM085 (content history), [[SM222]] (a switched-off extension offers nothing).
