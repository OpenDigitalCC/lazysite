---
id: SM1053
title: "SM1053: a partner stages accounts, and the operator applies them"
subtitle: "accounts-import-stage writes a list of accounts (no passwords) for review; the operator plans and applies it on a new manager page; each account is created without a password and given a claim link, in the groups that exist."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-5)
area: security
status-note: "SHIPPED (PENDING): the core - stage (manage_users, either door), list/plan/apply (the operator, cookie only), claim links, existing groups only, per-account audit, an Account import page; mailing the links is left for later (t/integration/212)."
---

# The report and the ruling

P-5: login accounts for about 700 migrated members. Account creation is
cookie-only by design (SM268), and the partner did not ask to lift it: "An
`accounts-import` the operator runs once from the manager, from a file the
partner uploads: the partner prepares, the human approves."

The release manager, 2026-10-12, in their words: "Operator-run import": a
partner uploads an accounts file (usernames, emails, groups; NO passwords) to a
staging location; the operator reviews a dry-run diff in the manager (a new
screen or the Users page) and applies; accounts get claim links (set their own
password; mailed only if the operator chooses); groups limited to those that
exist; audited; SM268's cookie-only account creation unchanged for partners.
Size it; if it is larger than M, build the staging + dry-run + apply core and
list the rest.

# Size

L as specified: the core (staging, dry run, apply) is M; the manager screen, and
mailing the claim links with an operator's choice, take it past M. Built: the
core, and a small manager screen, since without one the operator could not
review in the manager at all. Not built: the mailing (below).

# What was built (Lazysite::Manager::AccountImport)

| Action | Who | Does |
| --- | --- | --- |
| `accounts-import-stage` (POST) | any `manage_users` holder, token or cookie | validates the rows and writes one file to `lazysite/auth/import/<id>.json` (the auth store's directory: it holds addresses); answers the id, the count and the invalid rows |
| `accounts-import-list` (GET) | the operator, cookie only | the staged imports: id, by whom, when, counts, whether applied |
| `accounts-import-plan` (GET, `id`) | the operator, cookie only | the dry run, writing nothing: per row create or skip (the account exists), the groups it will join and the ones that do not exist; the invalid rows |
| `accounts-import-apply` (POST, `id`, `confirm` = the id) | the operator, cookie only | creates each new account as a registration approval does (`account-approve`): no password, the address recorded, the named groups that exist and no others, a claim link; marks the file applied, so a second apply is refused |

- **No passwords.** A row carrying any key that looks like a credential
  (`password`, `secret`, `hash`, `token`, ...) refuses the whole file and stages
  nothing.
- **Rows**: a username (letters, digits, `.`, `_`, `-`; not `local`; once per
  file), an optional address, groups as a list (or `;`-separated in CSV). At
  most 5,000 per file. Invalid rows are kept beside the valid ones, named, and
  never applied.
- **Groups that exist** (SM1045's `group_names`) only; the users tool's
  `account-approve` gains a `groups` list, so an import never falls back to the
  registration-flagged groups an approval otherwise joins.
- **Claim links**: returned to the operator by the apply and shown on the page.
  The address is recorded, so `/forgot` sends a person their own link - the
  self-service route that needs no mail from this.
- **Audited**: one row per account created (`user-account-approve`, the
  account, "accounts import <id>; placed in ..."), one per failure, and one for
  the apply (`accounts-import-apply`, "created N, skipped N, failed N"); the
  stage is audited as a mutating action.
- **SM268 unchanged**: a partner stages; only the operator (`_operator()` on a
  cookie session) lists, plans or applies. The three review actions are
  cookie-only.
- **The page**: /manager/accounts-import, linked from the Users page - the
  staged imports, Review (the plan), and Apply with a confirmation.

# Not built (the rest)

1. **Mailing the claim links, if the operator chooses.** The ruling's
   "mailed only if the operator chooses": a checkbox on apply that sends each
   new account its link through the site's mail (as `forgot` does). Until then
   the operator sends the links, or tells members to use "forgot password".
2. **Removing a staged import** (or expiring old ones): the files stay in
   `lazysite/auth/import/` until removed by hand.
3. **Updating existing accounts** from an import (an address or groups for an
   account that exists): rows for existing accounts are skipped.
4. **An MCP twin** of `accounts-import-stage` (recorded as undecided in
   t/lint/23).

# Interaction

On main `_operator()` is any `manage_users` session; the unlanded security stack
(n385, SM991) makes it the operator group. The review actions ask
`_operator()`, so they follow that change when it lands: a `manage_users`
partner on a cookie session will then stage and not apply.

# Tests

t/integration/212: a row with a password refuses the file and stages nothing; a
list stages three rows and names the invalid one, creating nothing; a CSV
stages; the token is refused list, plan and apply, and a cookie session without
`manage_users` the plan; the plan counts two to create and one to skip, names
the missing group and writes nothing; apply without confirm is invalid; apply
creates both with no password, the address recorded, a claim link, the
existing group only and not the registration group; a second apply is refused;
the trail holds the apply's row and each account's. Sabotage: a password
staged, the registration fallback, missing groups kept, a re-apply - each fails
212.
