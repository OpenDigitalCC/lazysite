---
title: "Work plan: 0.15.2"
subtitle: "The remedial work after the 2026-10-02 install, the three rulings taken the same day, and the disposition of seven reports in the dev inbox. Sizes are mine; the ordering is forced by dependencies where it is forced at all."
brand: plain
standard-margins: true
---

# What 0.15.2 already is

Sixteen entries in `## Unreleased`, SM915 to SM932, **every one a fix** - the
notification path, the quarantine, the request address, the tel pattern, the link
audit. The release manager's own reading on 2026-10-01: "this is mostly fixes so
far".

Two things then changed its shape. A real install on a new Hestia domain produced a
site that answered 500 while reporting success ([[SM933]]), and the dev inbox turned
out to hold seven reports, two of which ask questions only this side can answer.

`VERSION` still reads `0.15.1`, which is burned on origin - a version is never
reused (SM064), so the next cut is **0.15.2**. The field-practice briefing is already
stamped for it.

# The three rulings taken 2026-10-02

| Ref | Question | Ruling |
| --- | --- | --- |
| **R1** | A native form's declared field rules (`required`, `email`, `max:N`, `pattern:`) are rendered as HTML attributes and enforced by nothing on the server - measured: the handler checks only uploads and "not entirely blank". What should the server do? | **ENFORCE AND REFUSE, with a named reason.** The declaration becomes a contract |
| **R2** | SM747: both credential strategies need a session transport OOM does not have. Take OA3's key-in-cookie fallback, or wait? | **WAIT for OOM to gain the transport, and file to its inbox what is needed.** Filed 2026-10-02 |
| **R3** | SM933: `--fix` declines to set bits it did not create (SM274), so a fresh install cannot reach a clean report. Does that still apply to the installer's own output? | **BOTH**: provision gets it right, and `--fix` repairs the installed set |

R2 is already discharged: `/srv/projects/odoo/oom/inbox/2026-10-02-the-session-transport-lazysite-needs-from-oom.md`
states the five outcomes OOM needs to provide, why the transport cannot live in
lazysite (it would put Odoo RPC knowledge in the engine and break the
no-Odoo-knowledge rule on the first thing built under it), and what is **not** being
asked.

# Group A - the install, and it is all ruled

[[SM933]]. No further decisions; R3 settles the only one that was open. **A4 is the
row that matters** - it converts every future instance of this class, including ones
nobody has met, from a silent 500 into a named line at install time.

| Ref | PR | The work | Cx | Blocked on |
| --- | --- | --- | --- | --- |
| A1 | PR0 | **Measure first**: provision into a fixture and record owner, group and mode of every path it creates. Three candidate mechanisms are on the table and the filing refuses to assume between them | S | nothing |
| A2 | PR2 | Provision leaves the tree reachable by the CGI, or refuses naming the path it could not place | M | A1 - the remedy depends on which mechanism it is |
| A3 | PR3 | Setgid on the directories provision creates, so the model it declares is the model it produces | S | A1 |
| A4 | PR1 | **Provision ends by running the check it already ships with**, and prints the result. A fresh install either says healthy or names its own fault | S/M | nothing |
| A5 | PR4 | `--fix` may correct modes on paths the install state declares - the engine's own output, not somebody's choice (R3) | S | nothing |
| A6 | PR5 | Next steps names the rebuild hazard: any vhost rebuild can reset modes, so re-run the check after one | S | nothing |
| A7 | PR6 | A repair line records the prior value - `chmod 2775 (was 0755)` | S | nothing |

A4, A5, A6 and A7 are independent of the measurement and can go first. A1 then A2
and A3 close the cause.

# Group B - the form surface

Two of these come from one inbox report, and the third is a measurement I made
answering its questions.

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| B1 | [[SM934]] - declared field rules enforced server-side, a breach refused with the field and the rule named (R1) | M | nothing. **Carries a hazard, below** |
| B2 | [[SM935]] - the form rate limit buckets on a **calendar hour** (`"$ip:$hour"`, `$hour = int(time/3600)`), so five submissions at 10:59:59 and five at 11:00:00 is ten in one second within the rules. A rolling window, or the boundary stated as deliberate | S | nothing |
| B3 | The SQLi report's five candidate detection signatures. **Not ruled, and offered as signatures rather than a request.** Two of the five are already covered: the own-domain sender ([[SM930]]) and "a value in a field declared `email` that does not parse" (B1) | - | a ruling, if ever |

**B1's hazard, which must be designed for rather than discovered.** Refusing on a
declared rule means a form whose rule is wrong refuses *everybody*, and
[[SM921]] is the precedent in the other direction: the shipped `tel` pattern did not
compile, so a browser **ignored the attribute in full** and the field validated
nothing. The server must not be stricter than the browser in the one case where the
browser gives up:

- a `pattern:` that does not compile is **ignored**, as the browser ignores it, and
  the condition is reported where an author will see it - never a refusal;
- `required` is enforced only on fields the form actually declares, so a visitor
  cannot be refused for a field they were never shown;
- the refusal names the field and the rule, because "invalid submission" sends
  somebody to the wrong place - the lesson from SM923's cap message.

# Group C - access control, from two reports on the same surface

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| C1 | [[SM936]] - a deleted page's ACL outlives it and is inherited by the next page written at that path. Observed failing safe (draft, so a 404) - *the direction of the accident is not a property of the mechanism*: a `read:` list on a reused path grants a read nobody granted, as silently. Two fixes: a content delete takes the path's rule with it or says it has not; a create at a path carrying a rule reports it. Also worth checking for `data-table-acl-set` on a dropped table, and for `rename_page`/`move_file` | M | nothing |
| C2 | [[SM937]] - `acl_set` with `draft: true` answers `reads_unrestricted: 1` and "anyone may still fetch these pages" while the pages 404 to the public. The note measures the read **list** and reports it as the read **outcome** | S | nothing |

C1 is the one with a security direction. C2 is the shape the reporter named well:
"the shape of defect that makes a correct operator do the wrong thing."

# Group D - notification is invisible from the manager

Two reports, and the second declares them one problem: "Same operator, same
underlying problem: notification is invisible from the manager."

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| D1 | **ANSWERED 2026-10-02, in [[SM938]]**: a submission notice carries `url => '/manager/handlers'` today. On 0.14.4 the operator saw `/manager/plugins`; SM928 defect 4 moved it. So an upgrade improves it and does NOT close it - both are a manager section, and nothing addresses a single submission, so the rest is an addressable view rather than a changed string | - | done |
| D2 | [[SM938]] - whether a submission reaches XMPP is decided in three places and only one has any UI. The reporter's own ranking puts "the smallest change" first | M | nothing now D1 is answered |
| D3 | [[SM938]] - bell read state is implicit and whole-list: opening the panel marks everything seen. The report calls this "a design gap, not a bug" and ranks three asks | M | nothing |

# Group E - what a fresh install puts on somebody's domain

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| E1 | [[SM939]] - a fresh install ships lazysite's own demo and ~70 docs pages **on the owner's domain**, and `docs/features/` (plus three subdirectories) and `docs/integrations/` are created non-writable by the server, so that content **cannot be removed through any token surface**. Three of four sitemap pages on a named live site cannot be taken out of it | M | **likely shares A1's cause** - measure once, fix both |
| E2 | [[SM939]] SC3 - an install flag for no starter content. The reporter's own priority: "Low priority next to item 1" | S | E1 |

E1's permissions half is a defect and is almost certainly the same mechanism as
[[SM933]]: directories created with a group or mode the server cannot write. A1's
fixture measurement should cover `docs/` as well as `lazysite/`, so one measurement
answers both.

# Group F - held, and one of them asks a question

| Ref | What | Why held |
| --- | --- | --- |
| F1 | **FOLDED INTO [[SM824]] 2026-10-02** - three measured obstacles to a layout emitting JSON-LD: head meta vars are HTML-escaped with no inverse, there is no `json` filter reachable from a layout, and `sections` reaches the layout raw against the single-escape-point invariant. Input to [[SM824]], self-graded B, measured locally | **Asks a ruling**: expose a raw copy plus a `json` filter, or walk-and-escape `sections`. The reporter's words: "One of the two. Not neither, and not both silently." Park until SM824 is picked |

# Not in 0.15.2

| What | Why |
| --- | --- |
| [[SM747]] slices B, C and D | R2: waiting on OOM's session transport. Slice E (the MCP surface) is unblocked but delivers an agent-facing surface and no page UI |
| The OOM delivery shape | Left open by the release manager while OOM is under test; it is a decision for all of OOM's consumers |
| [[SM923]] limit 1, the section construct | Waiting for a second long form to ask |
| B3's detection signatures, F1 | Not ruled |

# What this plan is honest about

**All seven inbox reports are now filed** - [[SM934]], [[SM935]], [[SM936]],
[[SM937]], [[SM938]] (two reports, merged because the second says they are one
problem) and [[SM939]], with the JSON-LD measurements folded into [[SM824]] because
the report that carried them asked for that rather than a filing of its own. The
reports have moved to `inbox/archive/`.

One of them closed a question on the way past: D1 is answered rather than scheduled.

**Two reports were explicit about what they do not claim**, and the sizes above
respect it: the bell report is "not reproduced on a test instance" and says part of
it may already be closed, and the notification-routing report says "not that
notification is broken. The path works; this is about it being unobservable." Neither
is a defect hunt.

**One measurement in this plan is mine and not a report's**: B2, the calendar-hour
bucket. The SQLi report reasoned that the timing floor was the wrong control and was
right; the limit itself was within its default of five an hour, and the boundary is
the sharper finding.
