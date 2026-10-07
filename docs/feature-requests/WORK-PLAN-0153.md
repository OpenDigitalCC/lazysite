---
title: "Work plan - 0.15.3"
subtitle: "The open filings after 0.15.2, sorted by what each needs next: built, ruled, reproduced, or waited for."
brand: plain
standard-margins: true
---

# How to read this

Every row is an open item in a filing, by the filing's own label. **Needs** says
what has to happen before it can be built. Sizes are the filing's where it gives
one. Rulings taken on this plan are recorded in the table at the end.

# Group A - ruled and ready to build

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| A1 | [[SM906]] T3 - the control API answers a distinct "cannot tell" state when the auth store is unreadable, with the repair in the message (ruled 2026-09-29; not built) | M | nothing |
| A2 | [[SM912]] P4 - a fixture that writes an ACL with an empty auth store exempts itself from SM901; make it visible (t/integration/43's fixture has no accounts) | XS | nothing |
| A3 | [[SM869]] - raw and escaped query values separated: escape at stash insertion, `%RENDER_QUERY` raw, the sink escapes unconditionally. Hostile-value render test first. XSS-adjacent, so the filing asks for an adversarial review | M | nothing - the release manager said "take it next" |

# Group B - needs a ruling

| Ref | Item | Size | The question |
| --- | --- | --- | --- |
| B1 | [[SM939]] SC2 - DELETE of a non-empty WebDAV collection answers 500 | S | Support recursive delete, or answer 405 saying "delete the contents first"? |
| B2 | [[SM913]] S2/S4/S5 - spam that passes quarantine | XS/S/XS | S2: ship a list of link-shortener hosts as a stronger signal? S4: show each form's quarantine on/off in the manager? S5: ship a default `spam_keywords` list, or say why not? |
| B3 | [[SM857]] read half - `(mine)` views of a table | M | Go-ahead to build it, with the filing's positions: an anonymous viewer sees no rows (never all rows), and a `(mine)` page bypasses the shared cache |
| B4 | [[SM858]] - approve an account from a button on the Submissions view | M | Build it? It needs the form to declare `account_email:` and allocates the username from the address |
| B5 | ~~[[SM863]] part 2~~ **declined (R5)** - offer a known alias host as a labelled suggestion when a claim link has no site_url | S | Is a suggestion the operator must confirm better than none? |
| B6 | [[SM932]] (2) - `lazysite check` writes a known line and reports which log sinks received it | S | Schedule it? (Item (1), an engine-owned diagnostic log, stays deferred on OP-29) |

# Group C - reproduce or measure first

| Ref | Item | Needs |
| --- | --- | --- |
| C1 | [[SM911]] LD4 - MKCOL on an existing collection answers 405 under /assets/ and 403 under /lazysite/layouts/ | Reproduce with live scope state; size XS once found |
| C2 | [[SM883]] - six operations uniformly 1.20-1.27x slower since ~0.14.0 | Check the machine, then bisect 2026-09-10..13 |

# Group D - waiting on something outside this plan

| Ref | Item | Waiting for |
| --- | --- | --- |
| D1 | [[SM923]] limit 1 - sections in a long form | A second long-form report (ruled 2026-09-30) |
| D2 | [[SM887]] A5, E2/E5/E7 - the claude.ai skill on a real site | The release manager running it in a real conversation |
| D3 | [[SM888]] C3 - fix the five sites; C1/C2 live sweep | The sites agent (C3 is estate work) |
| D4 | [[SM747]] - Odoo integration | Its ruling |
| D5 | [[SM942]] - status reads partial though FO1-FO3 are built | A read of the filing to confirm nothing remains, then `shipped` |

# Rulings taken on this plan

| Ref | Question | Ruling |
| --- | --- | --- |
| R1 | B1: a non-empty collection DELETE | **405 with a "delete the contents first" body**; no recursive delete |
| R2 | B2: SM913 S2/S4/S5 | **Ship S2** (link-shortener hosts as a stronger signal) **and S4** (show each form's quarantine state). **S5 not shipped** - no default keyword list |
| R3 | B3: SM857 read half | **Build it in 0.15.3**, with the filing's positions: an anonymous viewer sees no rows; `(mine)` pages bypass the shared cache |
| R4 | B4: SM858 approve from a submission | **Build it in 0.15.3** - `account_email:` on the form, username from the address |
| R5 | B5: SM863 part 2 | **No.** The message names the path and the cause; setting site_url is the fix |
| R6 | B6: SM932 sink probe | **Schedule for 0.15.3**; item (1) stays deferred on OP-29 |
| R7 | A3: SM869's release | **In 0.15.3 with the rest**; the adversarial review still runs on its own branch |
