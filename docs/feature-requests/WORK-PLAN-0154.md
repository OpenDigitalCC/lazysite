---
title: "Work plan - 0.15.5"
subtitle: "What is open after 0.15.4, and what has landed since: the security reports from the field, the end of the SM944 split, engine bugs and requests from the dev inbox, a site partner's gaps, the account page, the testing model and the Odoo slices. Brought up to date with main 0ec4daa9 on 2026-10-12."
brand: plain
standard-margins: true
---

# How to read this

One row per item, by its filing or inbox report. **Status** says where it
stands: **landed** with the SM number and its short SHA on main (the item's
main commit; follow-up commits are named where they changed behaviour);
**built on nNNN, not landed**; or **open** with what it needs. Rulings are the
release manager's, quoted from the filing that records them. WORK-PLAN-0153 is
complete apart from P2 and P3, which continued here and are now closed; the
security rows held for it are recorded there as Q17a-Q17h.

Since 2026-10-12 branches do not edit WORK-PLAN files: each appends the row it
wants to `tmp/plan-rows-pending.md`, and one plan branch applies them (this one,
n555). Rows here are taken from git and the filings, not from those entries.

# Build queue - worked in this order (set 2026-10-11)

The release manager: "keep going with the queue, i will review as a batch
later". Each item is one branch, stacked, handed off READY; an item that needs a
ruling the plan does not hold is skipped and its question goes to the open
questions below.

## Security first

| P | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| P1a | `manage_users` alone lets a session write any file past the file permissions (inbox 2026-10-11, graded A) | "New approve capability" | landed, SM979 30861240 (n380); 0153 Q17a | M |
| P1b | An inline `auth_groups: [a, b]` list is ignored (inbox 2026-10-11, graded B) | "Parse it + fail closed" | landed, SM980 904aca3f (n381); 0153 Q17b | S |
| P1c | A `move` into a draft or read-restricted folder writes the file to the public docroot (inbox 2026-10-11, graded B) | "Land where save would" | landed, SM981 a6106bec (n382); 0153 Q17c | M |
| P1d | A `manage_data` holder reaches tables its permissions exclude; a published table serves hidden rows (inbox 2026-10-11) | "Table ACLs bind it + row filter" | landed, SM982 140d5870 (n383); 0153 Q17d | M |
| P1e | Found by P1a: `manage_users` passed every capability gate on the manager | "Operators bypass, others bound" | landed, SM991 e62da548 (n384): the operator is the group carrying the `manager` flag; 0153 Q17e | M |
| P1f | Found by P1a: `lock`, `renew-lock`, `unlock` asked no file rule | "Lock needs write access" | landed, SM992 c37798ad (n385); 0153 Q17f | S |
| P1g | Found by P1b: `auth_groups` bound only a signed-in request; `auth: manager` enforced nothing outside the manager | "Fix both as recommended" | landed, SM993 26958a46 (n386), decisions recorded f98b0e42; 0153 Q17g | S |
| P1h | Found by P1e: a `manage_users` holder could revoke the operator's sessions and keys | "Yes, protect operator sessions too" | landed, SM991 eec4b595 (n387); 0153 Q17h. `rotate-auth-secret` left for a ruling (open questions) | S |

## The end of SM944, carried from WORK-PLAN-0153

| P | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| P2 | S34, the CSRF write gate into Manager/Csrf.pm (0153 Q14) | "Yes, as planned"; "Audit refusals" | landed, SM944 S34: (a) f12eaec3, (b) 6454e568, (c) 30f30cb3, csrf-audit c16151ea. Its finding F-1 (a forged upload spent the budget) landed as upload-budget 3cf4d320 | M |
| P3 | Q16: retire the per-module log copies (0153 Q16) | "Close Q16 + MCP attribution" | closed with no move, 8d916e6b; MCP's Domains attribution landed, mcp-domain-attribution 2bcc4a7a (n368) | - |

## Engine bugs from the dev inbox

| P | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| P4 | `users-detail` reads every account, so approving a request times out | - | landed, SM983 c1f332f1 (n390): 0.27 s for 700 accounts, from 26.7 s | S |
| P5 | `&&` in a page body is a template parse error | - | landed, SM984 140baad1 (n391), 2802fd4b | S |
| P6 | A fenced code block that shows `:::` syntax is expanded | - | landed, SM985 4f8ade64 (n392) | S |
| P7 | A setup link refused over plain HTTP says "invalid or expired" | - | landed, SM986 800c0874 (n393) | XS |
| P8 | The development server cannot receive a form post | - | landed, SM987 c9874e31 (n394) | XS |
| P9 | A `scan:` stops at 200 pages with no warning | revised: "Keep, add per-scan limit=" | landed, SM988 035822f0 (n395) `scan_limit`, `_total`; SM995 b5ab1ce4 (n401) `limit=`/`offset=` | S |
| P10 | `lazysite provision` prints uninitialised-value warnings | - | landed, install-plan 4d187eb5 (n396) | XS |
| P11 | `acl set --draft` over a folder already held: a rewrite leaves the private copy and `reapply` refuses | - | open: skipped for P1c, which has landed (a6106bec); needs a reproduction on main, then a fix if it still fails | XS |

## Requests from the dev inbox

| P | Item | Ruling | Status |
| --- | --- | --- | --- |
| P12 | Registry objects carry only seven fields of front matter | "Full front matter + general lists" | landed, SM999 9f529b64 (n405), with P13 |
| P13 | YAML list keys other than `tags` arrive as raw text | with P12 | landed, SM999 9f529b64 (n405) |
| P14 | An alias host names itself as canonical | "Render from the canonical"; then "Keep" (a rootless domain names the primary) | landed, SM1000 3d19b097 (n406); "Keep" recorded baac228e (n414) |
| P15 | The visitor log cannot answer per-domain questions | "Record host" | landed, SM1001 5afe5399 (n407) |
| P16 | The CSP has no way to allow one external host | "Add allow-lists" | landed, SM1002 64b50259 (n408) |
| P17 | `(mine)` cannot read the viewer's own rows from a table they may not otherwise read | "Allow own rows"; with SM982, "Apply where: too" | landed, SM1003 459074b3 (n409); the row condition kept, fc3b4064 (n412) |
| P18 | A handler that mails recipients taken from data | "Yes, engine = mechanism"; "New 'manage_notifications' cap"; "Per rule, default on" (SM1010 "Ruled") | landed: phase 0 SM1017 25c7f06f; phase 1 SM1018 9b6f584f, SM1019 b36a89f0, SM1020 89a839a1 and e2cf858e; R2 as SM1044. Open: SM1010 R1, R3, R4, R6, R7 (below); R5 built on n504 |
| P26 | A member home page in the site theme, outside the manager (SM1010 R2) | "Accept, build phase 1" (SM1034 "Ruled") | phase 1 landed - see "The account page" below; phases 2-3 open |

## Follow-ups noted while working WORK-PLAN-0153

| P | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| P19 | The coverage floor names only the CGIs, not the parts and modules that left them | coverage floors per moved file | landed, coverage-parts 6fb617e6 (n410): per-file floors. Open: the floors are unverified until the next gate | S |
| P20 | `_render_form`, `main` and `render_content` are each hundreds of lines | "_render_form now, hold main" | landed, SM1012: tools 56550bca; `_render_form` characterised 2c86550e, S1-S6 537d7281..37d08ee6; `render_content` characterised 197879c2, S7-S11 a5a9af14..244782f1. Open: `main` held | L |
| P21 | Lint 137 reads only the top-level `*.pl` files | revised: "Keep original authors"; then "(1) restore auto-key tables, (2) keep row_policy, (3) keep original timestamps" | landed, SM989 1615ac72 (n398); SM996 7b55ca34 (n402); SM1036 d4ec4ff4 (n413) | XS |
| P22 | 31 filings still say "SHIPPED (PENDING)" after their release | the release step stamps; a sweep fixes the 31; then "Fix both" (ids) | landed, filing-stamps c2a25a00 (n411); filing-ids 5d025a4e and 80c27b44 (n415), lint 244. Open: the 34 archived filings | S |
| P23 | The nav parser stores a `javascript:` URL as written | refuse or neutralise unsafe schemes; then "Fix both" (the doc) | landed, SM997 42b545e0 (n403); SM1037 74651ae2 (n415) | XS |
| P24 | A failed `users` read, and a crashed handler, write no audit row | under SM943's audit rule | landed, SM998 4de84e87 (n404) | S |
| P25 | The scan's page read dies on a page it cannot open | - | landed, SM990 ed416939 (n399) | XS |

## From the 0.15.4 upgrade of sites.lazysite.io (release manager, 2026-10-12)

"adding group to domains, then press save - message: Nothing had changed. also
- groups should be prefixed with something say @ so they can be distinguished
from users, and this should be consistent anywhere a group is picked. lets have
cli command to add the domain group."

| P | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| U1 | The Domains page's Access pickers never save | - | landed, SM1013 ee93c190 and dbf5f52d (n430) | XS |
| U2 | Groups are named plainly on some pages and `@name` on others | the quote above | landed, SM1014 76a6c505 (n431) | S |
| U3 | A command to add one group to a domain from the shell | the quote above | landed, SM1015 2d403e12 (n432) | XS |
| U4 | A domain's access keys accept a group or account the site does not have | "lazysite-domains.pl should reject invalid groups"; "keep the design choice" | landed, SM1016 9f8de4cb (n433), confirmation ce42b2a6 | XS |
| U5 | `lazysite check` as a user that cannot read groups-settings.json says "unconfigured" | absent is unconfigured; unreadable a named finding; undecodable a FAIL | landed, SM1023 372aef0f (n435) | S |
| U6 | An undecodable groups-settings.json makes every signed-in account a manager (found by U5) | "Fail closed everywhere"; "Close all three" | landed, SM1024 - see "An undecodable store" below | S |

# Arrived 2026-10-12

## Security from the field: a member saved pages (SM1057)

Inbox 2026-10-12 (sites.lazysite.io, tprf-news): a signed-in account in no group
wrote pages through the manager API's cookie door. Exposed: v0.14.4,
v0.15.0-0.15.4.

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| SEC-1 | The cookie door never asked for `ui` | - | landed, SM1057 b1c2469a (n540): a non-operator cookie session needs `ui` | S |
| SEC-2 | A `ui` holder without `manage_content` still wrote any unruled path | "Require manage_content" | landed, SM1057 ceace878 (n541): the `content_write` actions need it, the file's rule on top | S |
| SEC-3 | A `ui`-only account could create the first rule on a content path | "Require manage_content" | landed, SM1057 1fddc26a (n542), test contract c180326f | S |

## An undecodable store (SM1024 and its follow-up)

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| ST-1 | An undecodable groups-settings.json read as unsecured by the manager API and sign-in | "Fail closed everywhere" | landed, SM1024 375c8fe8 (n437) | S |
| ST-2 | acls.json, revoked.json and user-settings.json failed open on both faults | "Close all three" | landed, SM1024 c8ba9e41 (n439) | S |

## A site partner's gaps (inbox 2026-10-12)

From the report "What a site-building partner could not do over the API, MCP or
WebDAV, and needed a human for" (its P-1 to P-12 are SP-1 to SP-12 here). Worked
on n520-n526.

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| SP-9 | `acl-set`'s scope check reads the query path, the handler the body's | as asked: "Check the scope against the path that will be used." | landed, SM1047 2975f26f (n520) | S |
| SP-9a | Found by SP-9's sweep: `form-submissions` read another domain's store | - | landed, SM1047 2975f26f | - |
| SP-9b | Found by SP-9's sweep: `brief-read`/`brief-append` reached another domain's brief | - | landed, SM1047 2975f26f | - |
| SP-8 | `/login`, `/claim`, `/forgot` 404 on a domain without copies | as asked: "Fall back to the engine's system pages when the domain has none." | landed, SM1048 ef8c6834 (n521) for /forgot and /logout. Open: the /login and /claim 404 on edge is not reproduced | S |
| SP-10 | A write-only rule on a domain root answers `partial` | as asked: "Report `ok:true` when no move was due." | landed, SM1049 f748ff2a (n522) | S |
| SP-1, SP-2, SP-3 | A partner cannot create a group, list the groups, or set a group's capabilities | "Yes, within the delegation limit" | landed, SM1050 e356926b (n523). A risk recorded (open questions) | M |
| SP-4 | A confined partner cannot create the handlers its forms need | "Domain-scoped handlers" | landed, SM1051 fee70911 (n524) | M |
| SP-6, SP-7 | Bulk-loading a `writable_by` table meant clearing it; 1,745 owner rules took 1,745 calls | "acl-set with a path list, Import respects writable_by, Owner bypass on import" | landed, SM1052 5e09ff0e (n525) | M |
| SP-5 | Login accounts for ~700 migrated members need the operator | "Operator-run import" | landed, SM1053 80c18383 (n526), the core. Open: the rest (below) | L |
| SP-11 | 504 on large WebDAV PUTs | an operator item | OP-48 filed | - |
| SP-12 | A partner cannot test a rule as a signed-in member | - | being supplied by the operator for this migration (an operator-issued test login) | - |

## Two more from the partner's migration (inbox 2026-10-12)

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| G-1 | An ACL calls a group unknown until it has a member | - | landed, SM1045 ad361042 (n510) | - |
| G-2 | A partner with `manage_domains` cannot create the first domain it would manage | "Allow, own group only"; D-1 "Direct members only", D-2 "Allow adoption", D-3 "Not required", D-4 "Accept" | landed, SM1046 8f654c69 (n511), D-2 ebaa8269 (n512) | - |

## The account page (SM1034 phase 1)

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| AC-0 | The brief: a member home page outside the manager | "Accept, build phase 1" | landed, SM1034 e2e3e0f2 (n445), rulings 361d2140 | - |
| AC-1 | A changed credential leaves the account's other sessions signed in | "Fix now" | landed, SM1040 3d273e89 (n446) | - |
| AC-2 | A password has no minimum length | "Min 12, configurable" | landed, SM1041 12b275bc (n500) | - |
| AC-3 | Phase 1a: `/account` and `me-*` | Q1-Q3 as recommended | landed, SM1043 522c0c1e (n501) | S |
| AC-4 | Phase 1b: a member's own notices | "Accept, build phase 1" | landed, SM1044 5e3de77f (n502) | S |
| AC-5 | Phase 1c: self-enrolled 2FA, manager enrolment removed | "Self-enrol only" | landed, SM1042 3fe14ea1 (n503), confirmations de5fa7ae | S |
| AC-6 | SM1010 R5: `manage_notifications` reaches the handler door, and only its own | SM1034 Q9, as recommended | built on n504, not landed | - |

## Queued or found while working, 2026-10-12

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| F-1 | SM1012's finding: a TT engine that cannot be built leaves umask 0002 | "Fix so the umask is restored on every path" | landed, SM1035 b4897d85 (n416) | XS |
| F-2 | MCP `preview_page` renders a draft against the site's real layout, writing nothing | "yes queue the preview_page draft change" | landed, SM1030 028622af (n480) | S |
| F-3 | Found working F-2: a text save writes non-UTF-8; a saved preview is a visit; it renders under the MCP Host | "Fix all three" | landed, SM1031 d87b98f1 (n481) | S |
| F-4 | Do the other preview doors record a visit? (SM1031's open question) | SM1031's rule | landed, SM1064 36bf553a (n554). Its findings: `preview_public`'s path built on n556 (SM1065); the processor lookup open (below) | XS |
| F-5 | `Connectors::sweep`'s counters: a sweep that expires nothing reports `expired: null` (found in SM747 CU) | - | landed, SM1063 0ec4daa9 (n553), lint 257 | XS |

## The testing model (SM1061, SM1062)

| Ref | Item | Ruling | Status | Size |
| --- | --- | --- | --- | --- |
| T-1 | Four handoffs ran the whole suite at once and caught nothing the precheck missed | quoted under "Process" | landed, SM1061 33a4a067 (n551), filing d4e0ed28. The gate's suite lock ruled 2026-10-12: "i think neither - becuase a release cant run when there isnt  suite run, so it simply manages itself" | - |
| T-2 | The overnight run tests what is about to land | "maybe the suite runs on its own branch, not main, then the review process checks that in to main" | landed, SM1062 18a79e91 (n552) | - |

## SM747 (Odoo), by slice

Ruled 2026-10-12, and Q1-Q3 the same day (56ab59e0, a774bcd2). Building runs
against the OOM tree; shipping waits on the deb carrying the Ops layer.

| Ref | Slice | Status | Size |
| --- | --- | --- | --- |
| O-A | A: the declaration, the connection, the URL rule, fault kinds, the call record, the mode gate, lint 240 | landed, a3c86e97 (n471) | M |
| O-CU1 | CU, the engine: the connection user's key, the binding as a handler type, parameter rules, the visitor key, the call, caps, plans, confirm | landed, 4d2e8e69 (n472) | L |
| O-CU2 | CU, the surfaces: `lazysite-odoo.pl`, the `odoo:` page binding, the key and status actions | built on n473, not landed | - |
| O-R | R: the portable-type interface; its wiring stopped on R-Q1 | built on n474, not landed; the wiring waits on OOM | S-M |
| O-E | E: every Odoo action an MCP tool; a grant may run as its own Odoo account | built on n475, not landed | M |
| O-F1 | F1: SECURITY.md, FEATURES.md, the extension's page | open: after A, CU, E | S |
| O-BCD | B, C, D, F2: the per-user path | open: wait on OOM's session transport | - |

# Not in the queue, and why

- C1 SM911 LD4 - TEST-PLAN-0154 R45 (f83d67e9) reproduces it whenever a WebDAV
  account with layout capabilities is to hand on edge.
- D1 SM923 limit 1 - waits on a second long-form report.
- D2 SM887 - the release manager's real session (285c0a6c) confirmed A5 and E2
  in a Claude Code cloud container; its status-note: "Closes on one run in the plain claude.ai
  chat sandbox (E2, E7). The release manager decides."
- D3 SM888 C3 - the sites agent's estate work.
- E4 SM947 - the toolchain's; brief filed.
- SM747 B, C, D - OOM's session transport; R's wiring - OOM's answer to R-Q1;
  shipping - the deb carrying the Ops layer. Both asks filed to OOM's inbox.
- The catalogue layouts' `| url_safe` - the layouts repository, not this one.
- OP-46, OP-47, OP-48 - host items on the operator list (edge's install user,
  its web template, the gateway timeout for large WebDAV PUTs).

# Open questions and work still to do

Each from its filing; none is in the queue until it is ruled or picked up.

**To build (ruled, not yet built)**

- **SM1034 phases 2-3.** Phase 2: R4's suppression store and one-click
  endpoint, `me-messages`, `me-settings` (`notify_email`, Q4's display name).
  Phase 3: confirmed address change, digests with R1's folding, `mfa_required`.
- **SM1010 R1, R3, R4, R7.** R1 Q7 folding; R3 the handler's last outcome and the
  outbox in the manager; R4 one-click unsubscribe; R7 phases 2-3 (event points,
  `chains.conf`, row events, XMPP, digests). R6 (the operator group carries
  `manage_notifications`) is still listed in the filing; SM991 has since
  landed, so it needs checking against main.
- **SP-5 (SM1053), the rest.** Mailing the claim links on the operator's
  choice; removing a staged import; updating existing accounts from an import;
  an MCP twin of `accounts-import-stage` (undecided in t/lint/23).
- **P11.** Reproduce on main now that P1c has landed.

**Waiting on a ruling**

- **SM1012 `main` held.** "hold main": `main` (S12-S15) is decided after seeing
  the other two splits, which have landed. Also recorded for a ruling "if it
  matters": `_render_form` alone is 1.14-1.17x after S6, from copying `%rules`.
- **SM991 R8, `rotate-auth-secret`.** It ends every session, the operator's
  included, and needs only `manage_config`; listed in SM991 "so it can be ruled
  on".
- **SM1064, the processor found two ways.** MCP and the manager modules find
  the processor differently (Common.pm `processor_path` versus beside
  lazysite-mcp.pl); n556 reports whether one way can serve both. Its other
  finding - `preview_public` renders a domain's page at its docroot path (404) -
  falls under SM1031's "Fix all three" and is built on n556 (SM1065).
- **P22, the 34 archived filings** (SM434-SM682) still say "SHIPPED (PENDING)":
  stamp them once by a sweep against CHANGELOG-archive.md, have the release step
  read archive/ too, or both.

**Waiting on someone outside**

- **SP-8, /login and /claim on edge.** Not reproduced; SM1048: "What would
  settle it: the status and the component that answered (the processor's log
  line for the request, or its absence) for one `/login` on that domain."
- **SM747 R wiring** - OOM's answer to R-Q1 (where a report carries its rows'
  descriptors); `manage_odoo` (OM3) left unbuilt on n475 as "a decision to take
  on its own".
- **SM887 closure** - see D2.
- **P19's floors** - verified by the next gate of a tree carrying 6fb617e6.

**Recorded, not changed**

- **SM1050's risk.** "the group binds a domain only if a domain names it":
  whoever later adds members to a partner's group should name it in the
  partner's domain (`domain-set allowed_groups`), which confines its members.

# Process (2026-10-12)

The release manager on testing, as relayed in SM1061: "a targeted subset on
each commit and handoff (precheck); the whole suite ON DEMAND (tools/suite.sh);
the whole suite REQUIRED for a release (the full gate and `handoff --release`);
and, as safety nets, 'Area subset + nightly'." The nightly run: "After
midnight". Heavy handoffs: "kill these off and run over night". And in SM1062:
"maybe the suite runs on its own branch, not main, then the review process
checks that in to main".

How that is run - the tier ladder, `tools/precheck.sh`, `tools/suite.sh`, the
overnight queue (`tools/overnight.sh --queue`) and where READY comes from - is
in SM1061, SM1062 and docs/DEVELOPER.md ("Which tests to run when"); the gate
on "prepare a release" or "cut X" is in CLAUDE.md.
