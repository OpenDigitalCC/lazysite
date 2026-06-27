---
title: "SM119 - audit log filters as value dropdowns"
subtitle: "Filter by a user/target that actually appears in the log"
brand: plain
---

## What

On the Audit page, make the User and Target filters dropdowns populated from the
distinct values present in the log, rather than free text:

- **User** filter: the set of users that have audit entries, plus **(none)** for the
  blank-user entries (public form submissions, install events).
- **Target** filter: the set of targets that appear, plus **(none)** for entries with
  no target.

So an operator picks from what is really there instead of guessing exact strings.

## Shape

- Client-side in `audit.md`: after loading entries, collect the unique `user` and
  `target` values (mapping empty to a "(none)" sentinel), sort, and populate two
  `<select>`s; filtering re-uses the existing filter logic.
- Keep "all" as the default option; "(none)" filters to blank-valued entries.
- Refresh the option lists when the log reloads (new values may appear).

## Status

Queued. Bounded `audit.md` change - build the option lists from the loaded entries and
swap the text inputs for selects.

## Status (reconciled)

**SHIPPED in v0.4.39.**
