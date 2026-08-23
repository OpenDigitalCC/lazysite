---
title: "Data tables"
brand: plain
---

# Data tables

A table holds **site** data -- a product list, an events calendar, a directory.
Each is declared by a *descriptor*: a short YAML file naming its fields and
their types. Per-visitor state is not a table; a basket or a login session
belongs to an application.

The menu item appears only when the Data tables plugin is enabled **and** your
group holds **Data**.

## See what tables the site holds

Where
: Content -> Data tables

Do
: Open the page on a site with at least one table declared. Then declare a new
  one through the API or over MCP and press Refresh.

Expect
: Each table lists its name and whether it is **published** or **not
  published**, plus **needs migrating** when the descriptor exists but the
  stored table has not been created or updated to match it. A table you have
  just declared reads *not published* and *needs migrating* -- both are the
  expected state of a new table, not a fault.

Negative
: With the plugin disabled the menu item is absent entirely, and the page - if
  reached by its URL - says the plugin is disabled and where to enable it,
  rather than showing an empty list that looks like a site with no data.

## Read a table's rows

Where
: Content -> Data tables -> Rows

Do
: Open a table that has rows, including one with a field left blank in some
  rows and set to an empty value in others.

Expect
: The columns come from the **descriptor**, not from the rows, so a column that
  is empty in every row is still shown -- a column that vanished because no row
  filled it would read as data loss. *not set* and *empty* are shown
  differently, because "never recorded" and "recorded as nothing" are different
  facts.

Negative
: The grid shows what the STORE holds, whoever may read it. It is not a preview
  of what a visitor sees: an unpublished table is fully visible here and
  invisible to the public. Do not use this page to check whether something is
  exposed.

## What an under-privileged user sees

An account **without** `manage_data` does not get the menu item. A manager who
can administer users sees it greyed with a padlock and a tooltip naming the
grant that would enable it -- the same treatment Files, Navigation and Domains
get -- so an administrator can tell "not permitted" from "not installed".
Anyone else sees nothing at all.

The page itself is capability-gated as well as hidden: reaching `/manager/data`
directly without `manage_data` is refused rather than served.

## Download a table

Where
: Content -> Data tables -> JSON or CSV

Do
: Download both formats for a table that has a decimal field, a row with a
  value left unset and another with it set to empty, and - if you can put one
  there - a row whose text begins with `=`.

Expect
: **JSON** is the exact copy: types survive, a decimal keeps its trailing
  zeros, and unset and empty stay distinguishable. It is the format that goes
  back in.
: **CSV** is for the spreadsheet you actually work in. It has no types, cannot
  tell unset from empty (both are an empty field), and any cell beginning `=`,
  `+`, `-` or `@` is **prefixed with an apostrophe**. A spreadsheet reads such
  a cell as a formula and will run it, and since rows can arrive from a public
  form that is a stranger's content in your spreadsheet. The prefix changes the
  value, which is the trade: use JSON when you need the data back unaltered.

Negative
: Neither download is capped at the page size the grid shows. A download that
  quietly stopped at the read ceiling would be a backup missing rows nobody
  was told about.

## What is not here yet

Editing, adding and deleting rows, downloads and CSV import. Rows are written
through the API, over MCP, or by a form pointed at a table. To change a table's
shape -- its fields, or whether it is published -- edit its descriptor; a change
that would lose data is refused and explained rather than performed.
