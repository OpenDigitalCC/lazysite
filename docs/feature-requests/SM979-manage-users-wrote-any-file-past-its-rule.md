---
id: SM979
title: "SM979: manage_users wrote any file past its rule"
subtitle: "A group holding only manage_users - made to approve account requests - saved and overwrote files no rule gave it, because the per-file bypass was the operator test. Approving gets a grant of its own, and group-reach says what a group can do."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox, 2026-10-11-manage-users-alone-lets-a-signed-in-session-write-any-file.md (a members' area on a local 0.15.3 site)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-11, New approve capability. A file's rule binds a manage_users holder like anyone (read, write, re-rule); move and copy ask the target's rule, mkdir and the multipart upload ask the path's rule; approve_accounts approves account requests and reads only account-request forms; group-reach names the operator and the files by rule. t/integration/124."
---

# What was wrong

Reported: a group holding ONE capability, `manage_users`, made so its members
could approve account requests. Signed in through the browser, a member called
`save` on the site root (rule `write @authors,@sysops`) and on another author's
post (rule `write GeekRuthie,@editors,@sysops`): 200 both, both files written.
An account holding only `read_submissions` was refused (403). `lazysite-users.pl
group-reach` reported the group as `0 callable` on every surface.

## Root cause

`lib/Lazysite/Auth/Acl.pm` `_acl_denied` (the per-file allow check every manager
file action calls) began `return undef if _is_operator();`, and `_is_operator`
(`Acl.pm`, the `$caps->{manage_users}` clause) answers true for every holder of
`manage_users`. That clause is right for what `_is_operator` is for - passing
the manager's capability gates - and it was also the per-file bypass. So a
`manage_users` holder passed every file's rule, read and write, on the cookie
channel. `action_acl_set` and `action_acl_remove` (`lib/Lazysite/Manager/Files.pm`)
asked the same `_is_operator()`, so the holder could also rewrite or remove any
owner's rule - a second route to the same files.

## Reproduced on main (41967751)

`tmp/sec-evidence/sm979-probe1.pl` against an export of main (`tmp/sec-evidence/sm979-probe1.main.out`), and
t/integration/124 run against main (`tmp/sec-evidence/sm979-t124.main.out`, 42 assertions fail):

| Who | Call | main | after |
| --- | --- | --- | --- |
| manage_users only | save at the root | 200, written | 403 |
| manage_users only | save another author's post | 200, overwritten | 403 |
| manage_users only | read a file in a members-only folder | 200 | 403 |
| manage_users only | acl-set / acl-remove another owner's rule | 200 | refused |
| manage_users only | move / delete another author's post | 200 | 403 |
| ui + read_submissions | mkdir at the root (rule names neither) | 200, made | 403 |
| ui + read_submissions | file-upload over a file the rule does not name | saved | refused, per file |
| an author | move or copy into a folder whose rule names someone else | done | 403 |

Found beside it: `action_mkdir` and the multipart `file-upload` asked no file
rule at all, and `action_move` and `action_copy` asked the SOURCE's rule only,
never the target's. Each is a file write past the path's rule, so each is inside
this ruling and closed with it.

# The ruling

Release manager, 2026-10-11, "New approve capability":

(a) find WHY a manage_users-only session bypasses the file write ACLs on `save`
(likely an operator/manager check - prove it from the code) and close it: every
file write applies the path's write rule to a manage_users holder like anyone
else; (b) add a new capability `approve_accounts` that is enough to approve an
account request (form-submission-approve / account-approve) without manage_users
and without read_submissions - decide from the code what approving must read
(the submission row it approves) and confine it to exactly that; existing groups
holding manage_users+read_submissions keep approving (no regression); (c)
`lazysite-users.pl group-reach` reports what each capability can actually do,
including file writes - it said "0 callable" for a group that could write any
file. Check: does manage_users bypass anything else (WebDAV, MCP, other write
verbs)? Inventory and close within "file ACLs apply".

# The fix

## (a) A file's rule binds a manage_users holder

- `Lazysite::Auth::Acl::file_rule_bypass` is the per-file bypass: `local` (the
  CLI's break-glass identity) and an unsecured site (no group grants manager
  access - the dev/first-run mode `_is_operator` also honours). Never a token,
  and not a `manage_users` holder. `_acl_denied` asks it in place of
  `_is_operator`, so `read`, `save`, `save-binary`, `delete`, `move`, `copy`,
  `migrate-to-local`, `git-restore` (through `save`), `file-download` and the
  zip all apply the path's rule to a `manage_users` holder.
- `action_acl_set` and `action_acl_remove` ask the same bypass: only the rule's
  owner changes or removes it, and only `local` names an owner for a new rule.
  Reading any rule (`acl-get`, SM464's audit half) is unchanged.
- `action_move` and `action_copy` ask the TARGET's write rule; `action_mkdir`
  and the multipart upload (per file, reported in `errors`) ask the path's.

A sysop group reaches a file the way any group does: by being named in its rule
(the starter's rules name `@sysops`), or by the CLI as `local`.

## (b) approve_accounts

Approving reads ONE thing: the row it approves, which is a row of a form whose
conf declares `account_email:` (`Plugins::action_form_submission_approve` reads
the row by id from that form's own store, and refuses any other store). So the
grant reaches the rows of those forms and nothing else:

- `form-submission-approve` is gated `approve_accounts|manage_users` (was
  `manage_users+read_submissions`; a `manage_users` holder is the operator and
  passes the gate either way, so a group that approved before still does).
- `form-submissions`, `form-submission` and `form-list` accept
  `read_submissions|approve_accounts` on the cookie channel. A caller holding
  `approve_accounts` without `read_submissions` (and not the operator) is
  confined by the dispatcher: a store that is not an account-request form's is
  refused 403 naming `read_submissions` (`_refuse_beyond_account_requests`, which
  asks `Plugins::account_request_store` - the approval's own test), and
  `form-list` shows it only those forms.
- The Users API's `account-approve` is NOT reached: it takes a username of the
  caller's choosing rather than a request somebody sent, so it stays full user
  management.
- Manager UI only, off by default; a manager group is topped up with it as with
  every capability. The Submissions menu entry, the start-page table, the Groups
  and Users grids and the capability map know it.

## (c) group-reach

`group-reach` prints, after the per-channel table, what the table does not say
(`Lazysite::Capabilities::group_reach_notes`, kept out of the users tool, which is
compiled on every credential check):

- for `manage_users` on `ui`: "operator: manage_users passes EVERY capability
  gate on the manager (ui) channel - every manager action, not only those
  listed. File rules still apply to it."
- for a group with `ui` or `webdav`: "files by rule - a path's access rule
  decides, never a capability", the rules naming the group (directly or through
  a group it is nested in) for write and for read, and what happens where no
  rule governs a path.

# Inventory: does manage_users bypass anything else?

| Surface | Before | After |
| --- | --- | --- |
| Manager file actions (cookie) | every file rule, via `_acl_denied` | the rule applies |
| acl-set / acl-remove (cookie) | any owner's rule | owner only |
| acl-get (cookie) | reads any rule (SM464) | unchanged (reading a rule is the audit half) |
| WebDAV | no bypass: `lazysite-dav.pl` `acl_allows` calls `_acl_allows` directly; MOVE/COPY authorise the destination | unchanged |
| MCP / control-API token | never an operator (`$token_auth`) | unchanged; `move_file` now asks the target's rule through `action_move` |
| Manager capability gates (cookie) | `manage_users` passes every gate (`lazysite-manager-api.pl`, the `!_operator()` block): measured, a `manage_users`-only session ran `config-set` (200) | **unchanged, reported** - outside "file ACLs apply"; group-reach now says so |
| Table ACLs (`Manager::Data`, data-table-acl-set) | operator re-rules any table | unchanged here (SM982's ruling: "operator unaffected") |
| `lock` | asks no rule: any manager account may lock any file, blocking its writers until the lock expires | **unchanged, reported** - a lock writes no file |

# Behaviour changes

- A `manage_users` holder (a sysop group included) no longer reads, writes,
  moves, deletes or re-rules a file whose rule does not name it. The starter's
  rules name `@sysops`; a rule naming only an author now binds a sysop too. The
  break-glass is the CLI: `lazysite acl ... --actor local`.
- `acl-set` names an owner (`owner`) only as `local`.
- A move or copy into a folder whose write rule excludes the caller is refused,
  as are `mkdir` and an upload there.
- `approve_accounts` is new, off by default.

# Evidence

t/integration/124 (reproduction first: 42 assertions fail on main; all pass
after), t/unit/manager/15-acl (the operator-bypass walk, now asserting the
rule binds the operator), lints 14, 76, 87 and 116 (the new capability in the
gate tables), `dist/config/bench-baseline.json` `work_users_tool_statements`
3378 -> 3379 (the one `print` group-reach gained in the users tool; lint 216).
Sabotage: 22 cases (`tmp/sec-evidence/sm979-sab*.out`), each bit; the first run found
acl-remove unasserted (an assertion was added) and two anchors re-laid by tidy
(re-run).
