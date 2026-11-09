---
id: SM1417
title: "SM1417: a broken store refuses, and is made fixable"
subtitle: "Ruling 206: a damaged store or broken install is a fault whose impact cannot be guessed. The engine refuses and never works around it; lazysite check and the log name the fault and its remedy, and the sysadmin repairs it from the command line. Ruling 207 applies it to the 21 places the 0.16.9 fault survey found."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-09
raised-by: "release manager, rulings 206, 207, 211 and 212"
area: auth
status-note: "SHIPPED (PENDING): all 21 survey items refuse (cannot-tell) on a store that exists and cannot be told, never on an absent one, and lazysite check names each with its repair. Items 1-8 (access) on n789, 9-21 (writes, sends, display) on n790; one wording, Util::store_fault. docs/SECURITY.md, UPGRADE (0.16.9)."
---

# What was ruled

Ruling 206 (standing, 2026-11-09): a damaged store or broken install is a fault
condition whose impact cannot be guessed. The engine refuses - sign-in refused for
all, the action refused - and never works around it: no fallback that guesses, no
special-case exception (it withdraws ruling 197's operator exception). Instead it
makes the fault fixable: `lazysite check` and the log name the fault and its remedy,
and the sysadmin repairs it from the command line. A site running as expected needs
no sysadmin except for upgrades; a damaged site, the sysadmin resolves.

Ruling 207 applies it to the 21 places in the read-only survey of main 8a2806723
(tmp/fault-survey-0169.md). Item 1 is a data-loss fix; item 8 refuses an
out-of-range setting rather than defaulting. Ruling 211 gives the work this number;
ruling 212 asks for this filing.

# The rules every item follows

Refuse
: when the state cannot be told, as cannot-tell (503 where a request is answered).

One wording
: names the store, says it is a fault on the host and not a decision about the
  request, and names `lazysite check --docroot <docroot>`; the log line names the
  repair. Items 9-21 share `Lazysite::Util::store_fault`.

Absent is legitimate
: a store that does not exist yet is a site with nothing recorded, and works as
  before. Only an unreadable, undecodable or invalid store is a fault.

Left as found
: a damaged file is never rewritten - no self-healing rewrite (items 13-15), and no
  write over it (item 1).

Nothing is lost on a send path
: a refused run sends nothing, and its queue keeps every entry until the store is
  repaired (items 10-12).

# What each item refuses, and the check line that names it

## Access (n789, `claude/n789-a-broken-store-refuses-access`)

1. **A rule is never written over a broken acls.json** (data loss). Refuses: every
   rule set or removal, file copy, `.url` migration and table rule while
   `lazysite/auth/acls.json` will not read or decode; `save_acls` itself refuses as
   the last line, and the file is left byte-identical. Check: the existing FAIL for
   an undecodable acls.json now says every rule change and file copy is refused.
2. **The operator is refused too.** Refuses: the operator's (and on an unsecured
   site every account's) file read and write, and table-row reads, past a broken
   acls.json - the `file_rule_bypass` and `_is_operator` exceptions are withdrawn.
   Check: the same acls.json line.
3. **The auth store lock fails closed.** Refuses: every account change and every
   single-use secret redemption (a reset link, an invitation) when
   `lazysite/auth/.consume.lock` cannot be opened or locked. Check: the lock joins
   the auth files the CGI must be able to write, saying what an unwritable one stops.
4. **The login rate limiter fails closed.** Refuses: every sign-in
   (`?error=unavailable`, 503 on the token doors) when DB_File is missing or
   `lazysite/auth/.login-rate.db` will not open. Check: the two limiter lines are
   FAILs saying every sign-in is refused, and a new line tie-opens the counter
   read-only and names one that is not a database, with its removal as the repair.
5. **The render path refuses a group store it cannot read.** Refuses: every
   signed-in request (503) while `lazysite/auth/groups-settings.json` will not open
   or decode, so address-limited groups cannot be lost. Check: the existing SM1024
   line for the undecodable file.
6. **An unreadable groups file refuses sign-in and sessions.** Refuses: sign-in
   (`?error=unavailable`) and every existing session while `lazysite/auth/groups`
   will not open (`session_store_fault` names it). Check: section 5b FAILs a groups
   file the CGI cannot read, with the chown/chmod repair (`--fix` applies it).
7. **A rejected content_root is refused.** Refuses: every request to a host whose
   `content_root` the confinement rejects (503), never serving the docroot root.
   Check: `report_content_roots` runs the same tests on the primary's and every
   `alias.<host>.content_root`, one FAIL per bad root with its repair.
8. **An out-of-range setting is refused.** Refuses: sign-in and sessions for a
   `session_lifetime` outside 300..31536000, and every password set for a
   `password_min_length` outside 8..128, instead of the default. Check:
   `report_auth_numbers` FAILs each invalid key with its range and the repair.

## Writes, sends and display (n790, `claude/n790-a-broken-store-refuses-writes`)

`lazysite check`'s `report_store_faults` (one table, by shape) holds the check line
for items 9-17, 20 and 21; items 18 and 19 use the SM1024 lines that already existed.

9. **A broken upload counter refuses the upload.** Refuses: every file upload and
   site-package upload (503) when DB_File is missing or
   `lazysite/manager/.upload-rate.db` will not open; a budget of 0 on both axes is
   the operator's choice and still allows. Check: FAIL "does not open as a DB_File
   database, so every upload is refused"; repair, remove it.
10. **A damaged unsubscribe store sends nothing.** Refuses: the notify-outbox run,
    which sends nothing and keeps its queue, when a line of
    `lazysite/notify/suppressed.jsonl` is not an unsubscribe record. Check: FAIL
    naming the line; repair the line, never remove the file.
11. **A damaged ledger sends nothing.** Refuses: the notify-outbox run (and its prune)
    when a line of `lazysite/notify/ledger.jsonl` is not a record; the queue is kept.
    Check: FAIL naming the line; repair or remove it.
12. **A send cap with a bad line refuses.** Refuses: a form's acknowledgement to the
    submitter, a notice mail, and a capped connector call, when
    `lazysite/forms/submitter-mail.jsonl`, `lazysite/logs/notice-mail.jsonl` or
    `lazysite/connectors/calls.jsonl` holds a line that is not a record. Check: a
    FAIL per file naming the line; repair or remove it.
13. **A damaged run record stops the scheduler.** Refuses: every scheduled job (no
    tick runs and nothing is written) when `lazysite/daemon/scheduler-runs.json`
    will not open, does not decode, or holds an entry that is not a job record.
    Check: FAIL; repair, remove it (every job then runs once).
14. **A damaged notify status is not written over.** Refuses: the status write, when
    `lazysite/notify/status.json` does not decode; the notices still go. Check: FAIL;
    repair, remove it.
15. **The connector sweep leaves a damaged record as found.** Refuses: the
    connectors-sweep job (nothing expired, nothing rewritten) on a line of
    `lazysite/connectors/calls.jsonl` that is not a record. Check: the calls.jsonl
    line of item 12.
16. **A failed query is not an empty table.** Refuses: a data migration's unique
    pre-flight, a rebuild's pre-flight (null count, duplicates, stored values), and
    an import's existing-key read, when the query against `lazysite/db/data.sqlite`
    fails. Check: FAIL when the store does not pass SQLite's quick_check (opened
    read-only); repair, restore from a backup.
17. **A damaged service state file starts no service.** Refuses: the daemon
    supervisor's start (exit 4, nothing adopted, nothing started) when a
    `lazysite/daemon/<service>.state.json` will not open or decode; Status says
    `failed` with the remedy. Check: FAIL per file; make sure no copy runs, remove it,
    restart the host service.
18. **The manager door says cannot-tell.** Refuses: `/manager/` with a 503 "Cannot
    tell right now" page, not the 403 "ask for the ui grant", when
    `lazysite/auth/groups-settings.json` will not open or decode. Check: the SM1024
    line for the undecodable file.
19. **A reset the host cannot match says unavailable.** Refuses: a forgot-password
    request (`?error=unavailable`, the same for every identifier; nothing minted)
    when `lazysite/auth/user-settings.json` will not open or decode. Check: the
    SM1024 line for the undecodable file.
20. **An undecodable install state says so.** Refuses nothing (the site serves): the
    version answer carries the cannot-tell sentence beside its null, and the MCP
    whoami's lookup logs it. Check: FAIL for `lazysite/.install-state.json`; repair,
    run the upgrade again.
21. **An unreadable notice template is said.** Refuses nothing (the built-in wording
    carries the notice): a WARN names the file. Check: FAIL for each unreadable
    `lazysite/notify-templates/*.tt`; repair, make it readable.

# Records

- docs/SECURITY.md: one hardening entry per branch (items 1-8, items 9-21), drafted
  for the release manager's confirmation; no ADR 0007 trigger fires.
- CHANGELOG: `SM1417 (PENDING)` under Unreleased.
- UPGRADE.md, "Unreleased (0.16.9)": what an operator sees for each store, and how
  to repair it.
