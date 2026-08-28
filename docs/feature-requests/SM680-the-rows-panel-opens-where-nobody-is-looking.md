---
title: "SM680: the Rows panel opens below the fold and a watched user did not see it"
subtitle: "Release manager, 2026-08-28, from observation rather than inference: 'on watching user earlier, they didnt see it open up below'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). The rows panel is an overlay, fixed over the page and scrolling inside itself, rather than a block revealed below the table list. The panel CONTENT is untouched - the pager, the CSV import and the editor entry point are the same markup in a different container - so this moves where it renders without disturbing what it renders. Closing asks before discarding an unsaved row, via mgDirtyGuard.isDirty (the real method name; a page once guessed isSet and the guard silently never fired). It did NOT need the plugin page's modal shell shared across pages: the panel already existed and only its container changed, so no shell was duplicated to get here."
---

# What was observed

A user pressed Rows on a table and did not notice anything happen. `#rows-panel`
is a `display:none` block below the table list; opening it reveals content
underneath whatever the user is looking at. On a page with several tables, or a
short window, the thing that changed is off-screen.

This is a watched user, not a reported one. That is the strongest kind of
evidence this project gets and the hardest to argue with: the control worked
exactly as built, and the person did not know it had.

# It is the same finding as the plugin page, one page over

0.11.4 moved the Plugin Config page from inline expansion to a line list with a
MODAL per plugin (SM640/SM639), because rendering everything inline made the
page grow and a change to one plugin re-render all of them. This is the other
half of the same objection - inline expansion puts the result somewhere the
reader is not.

The mechanism now exists: `mgPluginModal` in `plugin-config.md` is a shared
shell that fetches its own content and owns its own close. Rows is the obvious
second consumer, and doing it that way is what SM640 meant by adopting the
pattern one surface at a time rather than sweeping.

# Why a modal is right here specifically

- A table's rows are a DIFFERENT SUBJECT from the list of tables, not more
  detail about one entry in it. A modal says "you are now looking at this
  table"; an inline panel says "here is more of the same page".
- The rows panel already has its own pager, its own filter and its own state.
  It is an application, and it is nested inside a listing.
- It is scrollable content of unbounded height inside a page that also scrolls,
  which is the layout that produces exactly the confusion observed.

# What to watch when moving it

Two things the plugin-page conversion had to be careful about, and this one
inherits:

- The rows panel's controls must not RELOCATE DOM between containers. The
  forms plugin's add-handler wizard does, which is why it stayed inline when
  SM639 converted the rest; anything here doing the same needs the same care or
  the node is lost when the modal closes.
- Unsaved edits. A modal that closes on a backdrop click must ask before
  discarding a row being edited - the plugin modal's dirty-guard check is the
  precedent, and it must use `mgDirtyGuard.isDirty`, which is the real method
  name.

# Related

[[SM640]] / [[SM639]] (the line-list and modal pattern, and the shell this
should reuse), [[SM664]] (the third consumer of the same mechanism), [[SM679]]
and [[SM678]] (the other two things the table listing should say).

# Not started
