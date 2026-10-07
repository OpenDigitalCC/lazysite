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
| D5 | ~~[[SM942]]~~ **closed 2026-10-07** - FO1-FO3 built; R11 passed on edge; status `shipped` | - |

# Group E - development cost (filed 2026-10-07)

From the cost analysis: 98 of 529 commits since 2026-09-01 were bookkeeping, a
gate is ~90 minutes and 0.15.2 needed three, and an ordinary new action touches
13 files. In build order - E1-E3 first because they pay back inside this
release, E5 before the new actions R3 and R4 add.

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| E1 | [[SM950]] (1) - the gate suite runs with -j4 (17 min -> ~6); the host has the memory now | XS | nothing |
| E2 | [[SM948]] - handoff regenerates the generated docs instead of failing on them | S | nothing |
| E3 | [[SM949]] - a one-minute pre-check (lints, related tests, changed-line tidy) before the full suite | S | nothing |
| E4 | [[SM947]] - landing keeps the branch's SHAs (fast-forward), or stamps refs itself | M | the toolchain - vcs-review is theirs; brief filed |
| E5 | [[SM943]] - one declaration per control-API action, the rest derived | L | before R3/R4 add actions |
| E6 | [[SM950]] (2)(3) - gate run on landing; coverage reused when its inputs are unchanged | M | E1 |
| E7 | [[SM946]] - prose caps; the changelog keeps one minor, older ones archived | S | nothing |
| E8 | [[SM945]] - comments state the invariant; history to git and the filing | ongoing | applied as files are touched |
| E9 | [[SM944]] - the processor and the manager API split into modules, one area per branch | L | E5 for the manager API half |

# Group F - from the 0.15.2 edge walk (filed 2026-10-07)

| Ref | Item | Size | Needs |
| --- | --- | --- | --- |
| F1 | ~~[[SM951]]~~ **built (n247)** - the manager bell is never wired: its script runs in `<head>` before the bell exists (since at least 0.10.0); blocks R1 | S | - |
| F2 | ~~[[SM952]]~~ **built (n248)** - a form's rate limit counts the address's posts to every form, and refused-as-invalid posts spend it | S | nothing - ruled (R8) |
| F3 | ~~[[SM953]]~~ **built (n249)** - a missing submission's message names the store file | XS | nothing |
| F4 | ~~[[SM954]]~~ **built (n250)** - the submissions table shows "quarantined" without the stored reason | XS | nothing |
| F5 | [[SM955]] - the XMPP test says sent when the server bounces it; delivery failures are not audited | M | nothing - ruled (R9) |
| F6 | [[SM956]] - a visit of more than five pages at under ten-second gaps is a bot (owner rule 2026-10-06) | S | nothing - ruled |
| F7 | [[SM957]] - menu review: Submissions page and menu entry with an unread count, Handlers off the menu, daily vs setup groups | M | nothing - ruled (R11) |


| Ref | Question | Ruling |
| --- | --- | --- |
| R1 | B1: a non-empty collection DELETE | **405 with a "delete the contents first" body**; no recursive delete |
| R2 | B2: SM913 S2/S4/S5 | **Ship S2** (link-shortener hosts as a stronger signal) **and S4** (show each form's quarantine state). **S5 not shipped** - no default keyword list |
| R3 | B3: SM857 read half | **Build it in 0.15.3**, with the filing's positions: an anonymous viewer sees no rows; `(mine)` pages bypass the shared cache |
| R4 | B4: SM858 approve from a submission | **Build it in 0.15.3** - `account_email:` on the form, username from the address |
| R5 | B5: SM863 part 2 | **No.** The message names the path and the cause; setting site_url is the fix |
| R6 | B6: SM932 sink probe | **Schedule for 0.15.3**; item (1) stays deferred on OP-29 |
| R7 | A3: SM869's release | **In 0.15.3 with the rest**; the adversarial review still runs on its own branch |
| R8 | F2: SM952's rate-limit scope | **Per form**, and **only accepted submissions count** - a post refused by validation spends nothing |
| R9 | F5: SM955's delivery reporting | **The test button reports a refused recipient** (it waits for the bounce); **every delivery failure goes to the audit log** so it can be exported |
| R10 | Net::DNS's SBOM licence | **Keep MIT, with a note** naming the extra advertising clause |
| R11 | F7: SM957 menu review | **M1-M7 accepted; Handlers off the menu** (reached from forms and Extensions); **the Submissions entry shows an unread count** |
