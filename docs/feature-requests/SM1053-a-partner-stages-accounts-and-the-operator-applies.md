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
status-note: "SHIPPED (PENDING): the core - stage (manage_users, either door), plan/apply (the operator, cookie only), claim links, existing groups only, audit, an Account import page (t/integration/212). The rest: links mailed if the operator chooses (n570, 253); remove a staged import (n571, 254); update existing accounts as ticked (n572, 255); MCP stage_accounts (n573, 256)."
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

1. **Mailing the claim links, if the operator chooses.** Built on n570: see
   "The rest, built" below.
2. **Removing a staged import** (or expiring old ones): removing built on
   n571, below; expiring old ones is not built.
3. **Updating existing accounts** from an import (an address or groups for an
   account that exists): built on n572, below.
4. **An MCP twin** of `accounts-import-stage` (recorded as undecided in
   t/lint/23): built on n573, below.

# Interaction

SM991 (landed): the operator is a member of the operator group, and
`manage_users` alone is user management. The review actions ask `_operator()`,
so a `manage_users` cookie session that is not the operator stages and does not
list, plan or apply - t/integration/212 holds it.

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

# The rest, built (n570-n573)

The release manager's ruling stands for all four: the partner prepares, the
operator approves; SM268's cookie-only account creation is unchanged.

## 1. Mailing the claim links, when the operator chooses (n570)

- **The choice is per apply, and off.** `accounts-import-apply` takes `mail`;
  only `true` (or `1`, `"true"`) turns it on - absent, `false` and the string
  `"false"` are all off. The Account import page carries it as a checkbox beside
  Apply, unticked each time.
- **To the address the row carries.** Each new account is mailed its own claim
  link at the address its row staged, which the apply has just recorded as the
  account's. A row with no address, or one that is not exactly one address
  (SM1017), is not mailed, and says so.
- **The site's one mail path.** The send goes through `Notify::send_mail`, which
  the bell notices' mail now calls too: the Form SMTP extension (installed,
  switched on, its settings saved - each named when it is not) and the per-hour
  bound counted from the site's own record, `mail.per_hour` in notify.conf
  (default 60). An import is held to the same bound as every other mail the site
  sends to an account, and an unreadable record refuses rather than counting as
  zero.
- **The link is absolute or it is not sent.** The users tool's `url`, else
  notify.conf's `base_url` / the expanded `site_url` with the claim path; with
  neither, the row says to set `site_url`. A host is never guessed for a link
  that carries a credential (SM863).
- **A failed send never blocks the apply.** Every account is created first;
  each row then carries `mailed` or `mail_error` (the transport's refusal, the
  bound reached naming `mail.per_hour`, no address, no SMTP settings), its claim
  link is still shown to the operator, and the reply counts `mail.sent` and
  `mail.not_sent`.
- **Audited.** One `accounts-import-mail` row per send asked for, ok or fail,
  naming the account and the import - never the address (SM877). The apply's
  own row adds "mailed N, not mailed N".

Trade, for a ruling if it matters: an import larger than what is left of the
hour's bound mails up to the bound and reports the rest "cap reached"; for
those rows the operator sends the link shown, or the person uses "forgot
password". Sharing the bound also means a large import can use the hour's
allowance that bell notices would otherwise have had. A separate bound for
imports would be a second setting for one transport, so it is not built.

Tests: t/integration/253 - no mail without the choice, nor with `"false"`;
with it, a link to each new account at its own address, carrying its own link;
no address, a transport refusal and the bound each reported on their row while
all five accounts are created; one audit row per send, none naming an address;
no SMTP settings reported per row. Sabotaged one at a time (backups in
`tmp/sab-bak/n570/`, restored with `cp`, compared with `cmp`), each red in 253:
mail sent without the choice; `"false"` read as yes; a failed send stopping the
apply; the bound not asked; no audit row per send; the link mailed to an
address other than the row's.

## 2. Removing a staged import (n571)

- **`accounts-import-remove`** (POST, `id` in the body), gated `manage_users`
  as staging is, and a Remove button on the Account import page.
- **Who.** The account that staged the import (its `staged_by`), by token or
  cookie, as it staged; or the operator, from a cookie session (`_operator()`,
  never a token). Holding `manage_users` is not enough, and neither is having
  staged a different import: "import X was staged by Y: it is removed by that
  account or the operator".
- **What.** The staged file is deleted. An applied import may be removed too:
  the file was its record of having run, and the trail already holds what it
  did; the accounts it created stay.
- **Audited** as every mutating action is, the target "accounts import <id>",
  a success saying whose it was ("removed; staged by tks, 1 account(s), not
  applied"), a refusal recorded as a failure.
- Not built: expiring old imports. Nothing asked for it beyond the filing's
  "(or expiring old ones)".
- MCP: no twin; recorded as undecided in t/lint/23, as staging was.

Tests: t/integration/254 - a `manage_users` cookie account that did not stage
it, the partner on another account's import, and a session without
`manage_users` are refused and the file stays, the refusal in the trail; the
partner removes its own by token and a cookie account its own, each audited
naming the import; removed twice is not-found and a path for an id is invalid;
the operator removes the partner's, which then cannot be applied. Registered in
t/lint/98 (119 token-reachable), 218, 23 and t/unit/manager/226. Sabotaged (in
`tmp/sab-bak/n571/`), each red in 254: any `manage_users` holder removes any; a
token counts as the operator; ok without deleting the file; not declared
mutating (unaudited); the audit target without the import.

## 3. Updating existing accounts (n572)

- **The dry run shows the changes.** A row for an account that exists is
  `update` when its address or its groups differ, each change listed with the
  id the operator ticks: `USER:email` (from, to), `USER:+GROUP` (join),
  `USER:-GROUP` (leave). Otherwise `skip`, "the account exists and nothing
  differs".
- **A row's groups are the set the account should have.** Groups it names that
  the account is not in are joins; groups the account is in that it does not
  name are leaves. A row with no `groups` (a list row without the key, a CSV
  without the column) proposes no group change at all - staging now keeps that
  difference. An address only when the row carries one; an address is never
  cleared.
- **Only what is ticked.** `accounts-import-apply` takes `updates`, the list of
  change ids; none ticked, none made. A tick that is no change in the plan when
  it is applied is named in `unmatched` and not made. Each change goes through
  the users tool, the store's owner: `settings-set email` (the one writer of the
  address), `group-add`, `group-remove`. Never a password.
- **Groups that exist, never an operator group or a registration group** -
  in either direction: such a group is neither joined nor left, and the dry
  run says why (`groups_refused`). An operator group is one carrying the
  `manager` flag or nested in one (SM991's closure). Group settings that cannot
  be read leave no group an import may change.
- **An operator's own account is not changed by an import** (decided here, not
  in the brief): its address is where its reset link goes, and a staged change
  of address is the one row that would turn an import into a takeover of the
  operator's account through "forgot password". It is changed on the Users page.
- **Audited.** One `accounts-import-update` row per change made or refused,
  naming the account and the import - "address changed", "joined authors",
  "left editors" - never the address (SM877). The apply's row adds
  "updated N (M change(s))".

**Losing a group does not end the account's sessions.** Decided from the
rulings: SM1070's probe, ruled on, recorded "the groups-removed column is right
as it stands: groups are read fresh on every request (SEC-2026-07 M5), and an
account that still exists keeps its member's doors", and t/integration/243
holds it through the real cookie doors - the account loses the group's doors on
its next request and keeps its own. SM1040 signs the other sessions out when a
CREDENTIAL changes; an import changes no credential. Ending the sessions would
add nothing the next request does not already do, and would sign the person out
of what they may still use. t/integration/255 holds both halves: no revocation
is written, and the account's next request no longer carries the left group's
capability.

Tests: t/integration/255 - the dry run lists u1's address, join and leave, the
operator and registration groups and a missing group refused with the reason,
the operator's own account and an unchanged account skipped, a row with no
groups proposing none, and changes nothing; the apply makes only the two ticked
changes (the untaken leave stays, the operator's account is untouched, two
stale ticks named), the password line unchanged, one audit row per change and
no address; a second import's ticked leave takes the group's capability on the
next request with no revocation written; an account made an operator is not
changed. t/integration/212 passes unchanged (its existing row is the
operator's). Sabotaged (in `tmp/sab-bak/n572/`), each red in 255: every offered
change made whether ticked or not; an operator group changeable; a registration
group changeable; an operator's account changed; a row with no groups stripping
them; staging forgetting that a row named no groups; no audit row per change;
leaving a group signing the account out.

Open, for a ruling if it matters: a NEW account in an import still joins any
named group that exists, an operator or registration group included, as the
core built it; the operator sees it in the dry run. Recommendation: hold
creation to the same rule as updates.

## 4. An MCP twin for staging (n573)

- **`stage_accounts`**, declared once on the action (SM943: `mcp =>
  'stage_accounts'` on `accounts-import-stage`), built on the same
  `AccountImport::stage`: `accounts` (rows of username, email, groups) or `csv`,
  never a password, `manage_users`, the grant's account recorded as `staged_by`,
  audited as every MCP write is. t/lint/23 no longer lists staging as
  undecided.
- **Staging only.** No MCP tool lists, plans, applies or removes an import:
  the review is the operator's, cookie only, in the manager (SM268). Removing
  stays control-API only and is recorded in t/lint/23 as undecided for MCP.

Tests: t/integration/256 - a `manage_users` MCP grant is offered the tool and
no other import tool, a grant without it is neither offered nor allowed it; a
password refuses the list and stages nothing; a list stages one row and names
the invalid one, a CSV stages, nothing is created, the trail names the grant;
the operator plans it (staged by the MCP grant) and applies it in the manager.
t/lint/91 records `accounts` and `csv` as never a content path. Sabotaged (in
`tmp/sab-bak/n573/`): the tool without `manage_users` and the tool with no
actor, each red in 256; the twin undeclared on the action, red in t/lint/23.
