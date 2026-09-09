---
id: SM806
title: "SM806: the connectors page uses the vocabulary it was given, and the record it shows is its own"
subtitle: "Three findings from the release manager reading the shipped page: the call record showed another connector's history, Delete could not be found, and the page had styled itself. All three are mine, from the page I added in 0.13.9."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm804-a-row-source-call-is-a-connector-call. The call record filtered on `id`; the action's parameter is `connector`, so the filter never applied and every panel listed every connector's calls. The row expander was hand-rolled with innerHTML instead of the `hidden` attribute the stylesheet keys on. The page borrowed the permissions editor's mg-perms-* components as generic layout. And the fields whose values the engine can enumerate - the two data tables and the caller groups - are now chosen, not typed, with an unreadable list falling back to a text box rather than an empty select."
---

# What the release manager found

**The record showed somebody else's history.** The page fetched
`connector-calls&id=…`; the action's parameter is `connector`. Sending the
wrong name did not fail - the filter simply never applied - so every
connector's panel listed **every** connector's calls, and a newly created
connector opened showing a history it could not have. A filter that silently
matches everything is worse than one that errors.

**Delete could not be found.** It was in the expander, but the expander was
hand-rolled: `.mg-expand` is shown and hidden with the `hidden` attribute the
stylesheet keys on, and this page emptied `innerHTML` instead. That is the
inconsistency the style guide names in its own words - eight pages had already
rolled their own show/hide - and I added a ninth in the release that was
supposed to read the guide first.

**The page had styled itself.** Not with inline styles - lint 108 would have
caught those, and did - but by borrowing `mg-perms-rights-label` and
`mg-perms-actions`, the permissions editor's own components, as generic layout.
They are registered classes, so nothing complained. That is how two idioms
become four.

# And the fourth, which was asked for rather than found

**A value the engine knows should be chosen, not typed.** The row table, the
answer table and the caller groups were free text. A mistyped group name
silently grants nothing; a mistyped table name is a connector that saves
cleanly and fails at call time, which is the worst place to learn of it.

All three are now pickers. Two things about how, because both are the
four-states rule again:

- **An unknown list is not an empty one.** Groups need `manage_users` and
  tables need `manage_data`, and a `manage_connectors` holder may have neither.
  Where the list cannot be read the field stays a text box and says so - an
  empty select would be a statement about the site, and would stop a connector
  being configured by somebody entitled to configure it.
- **A configured value absent from the list is kept and marked**, never
  dropped. A table since deleted still shows, labelled, because silently
  changing what a connector points at is worse than showing something odd.

# What now holds it

`t/unit/manager/161` asserts that every class on the page is registered in the
style guide, that no component is borrowed from another page, that the expander
is the `hidden`-attribute idiom, that Delete is in the control row beside Save,
and that the call record filters on `connector`. Each was broken deliberately
to confirm it fails.

# Provenance

Reported by the release manager while reading the page on edge, in three
messages. The style-guide half is the one to learn from: I read the guide
before building and still hand-rolled the one idiom it exists to enforce, so
the test now asks the question rather than my remembering to.
