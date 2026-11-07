---
id: SM1410
title: "SM1410: a staging run that stages no account is not kept, and a kept one says how to discard it"
subtitle: "AccountImport::stage wrote a staging record with staged 0 when every row was invalid, answered ok with its id, and named no way to discard it. Such a run now writes nothing and is refused, listing each invalid row; a kept run's reply names accounts-import-remove with its id."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.7 (T-107, brief n774)"
area: users
status-note: "SHIPPED (0.16.8) on n774: AccountImport::stage writes no record when no row is stageable and its note names accounts-import-remove; stage_accounts' description says both. t/integration/369. UPGRADE.md note under Unreleased (0.16.8)."
---

# What happened

On the 0.16.7 edge run (T-107, R9 W7) `stage_accounts` with one invalid row
answered `ok: 1`, `staged: 0` and a staging id. `AccountImport::stage` wrote the
record whatever the rows were, so the operator's import list then showed a run
with nothing to apply, and no MCP door discards one. The control API has
`accounts-import-remove` (n571: by the account that staged it, or the
operator; open to a token with `manage_users`), and the reply did not name it.

# The change

In `Lazysite::Manager::AccountImport::stage`, shared by `accounts-import-stage`
and `stage_accounts`:

- A run with no stageable row writes nothing. The answer is `ok: 0`, `kind:
  invalid`, `staged: 0`, `invalid` listing each row with its reason as before,
  no `id`, and the error "No row could be staged: every row is invalid (each is
  listed under invalid, with its reason). Nothing was staged and nothing was
  written; correct the rows and stage them again." A refusal, because nothing
  was done; the rows are still all there for the caller to correct.
- A kept run's `note` adds "To discard this run, send accounts-import-remove
  with id ID (the control API, as the account that staged it), or the operator
  removes it on that page."

`stage_accounts`' description says both. A run with one valid row and any
number of invalid ones is kept as before, and the invalid rows are kept in the
record for the operator's dry run.

# Tests

t/integration/369-an-empty-staging-run-is-not-kept.t, over MCP and the control
API: a run whose rows are all invalid is refused, staged 0, each invalid row
listed with its reason, saying nothing was staged, with no id and no record
written; a kept run's note names accounts-import-remove with its id, and that
action removes it. With the change reverted all four subtests fail.
t/integration/212, 254 and 256 pass unchanged.

# Upgrade

A caller that staged a list of only invalid rows was answered ok with an id;
it is now refused, with the same `invalid` list. UPGRADE.md says so under
Unreleased (0.16.8).
