---
id: SM1470
title: "SM1470: a user row with many groups keeps its Edit button"
subtitle: "On the manager Users page an account holding many roles ran its chips off the row and pushed the Edit button out of view, so the account could not be edited. The row now wraps at every width and the button never shrinks."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the release manager, with a screenshot of the Users page"
area: manager
status-note: "BUILT, not yet released (n861). Target 0.17.2. Manager stylesheets only (all three styles); no engine change. t/tools/745 holds the rule."
---

# What happened

On the manager Users page an account with many roles or groups showed its chips running off
the row. The Edit button was pushed out of view and could not be clicked, so the account could
not be edited. Accounts with few chips were fine.

# Cause

`renderUserRow` (starter/manager/users.md) builds one `.mg-acc-line` row: name, tags, a chip per
role, a spacer, flags and the Edit button. `.mg-acc-line` in the three manager stylesheets is a
flex row that did not wrap, and `flex-wrap: wrap` was applied only inside the narrow-width media
query. At any wider width the chips and the button shared one line; the button, the last item,
was the one pushed past the edge.

# The request

R1 - the Edit button stays visible and clickable at every width
: However many chips a row carries, the row wraps (the chips take further lines) and a button in
  the row does not shrink or leave it. The three styles (modern, classic, accessible) are kept
  in step. The groups page and the style guide use the same row and keep their look: a row that
  fits on one line is unchanged.

# Settled when built

- A top-level `flex-wrap: wrap` on `.mg-acc-line` and `.mg-acc-line .mg-btn { flex: 0 0 auto }`
  in each style. The narrow-width rule that already wrapped the row stays; it is now redundant
  for wrapping but still carries its comment about the tag margin.
- t/tools/745 reads the three stylesheets and fails on the old CSS (no top-level wrap, no
  unshrinkable button, in each style).
- No register entry: layout only.
