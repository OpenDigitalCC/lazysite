---
title: "SM144 - Users page: selecting an account vs configuring it"
subtitle: "Make main-account vs sub-account editing unambiguous"
brand: plain
status: shipped
status-note: "delivered in the Unreleased line (2026-07-12); tree = selecting (identity banner + Configure button + tinted sub-users), full-width editor sheet = configuring (coloured header, same size at any depth)"
---

# SM144 - Users page: selecting an account vs configuring it

## Why

Field feedback: sub-accounts work well, but operators found it hard to tell
whether they were editing a **main account or a sub-account**. On the Users
page a sub-user's card was nested inside its parent's expanded body, so with a
parent and a child both open the page showed two identical stacks of settings
sections (Notes / Access / Groups / Credentials ...) with nothing marking whose
was whose. Two problems: "selecting a user" and "configuring a user" were the
same click, and **each level of nesting made the edit panel narrower**.

## Shape

Two separate surfaces - the names may nest, but the editor never does:

- **Selecting (the tree).** Opening a row shows an **identity banner** - the
  account name, human/AI, and lineage (`top-level account · N sub-users`, or
  `sub-user of <parent>`) - and, below, its sub-users. Sub-user rows are tinted
  so they read as nested at a glance. The tree carries no settings; it is purely
  a browser for *which* account to work on.
- **Configuring (the editor sheet).** An explicit **Configure &lt;name&gt;**
  button opens that account's settings in a single **full-width editor sheet** -
  a centred, fixed-width overlay with a **solid accent-coloured header** naming
  the account and its lineage ("Configuring &lt;name&gt; · human · top-level
  account"). Because the sheet is not part of the tree, it is the **same size
  and position however deep the account sits** - the "less width each time you
  nest" problem is gone, and it is never ambiguous whose settings are on screen.
  Esc, the × button, or a backdrop click closes it; a save reloads the tree and
  refreshes the open sheet in place.

## Implementation

Entirely in `starter/manager/users.md` (`renderUserRow` builds the tree row;
`accountSettingsHtml` builds the settings; `configureUser` / `renderConfigSheet`
/ `closeConfig` drive the sheet; deep links open the target's sheet) and
`manager.css` (`.mg-acc-ident`, `.mg-acc.mg-sub`, `.mg-sheet*`). Only one
account's settings exist in the DOM at a time, so the per-field ids stay unique.
No engine or API change - the account model and endpoints are untouched. Guarded
by `t/lint/10-users-select-configure.t`.
