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

# The rulings: R1-R12 taken 2026-10-02, R13-R15 taken 2026-10-03

| Ref | Question | Ruling |
| --- | --- | --- |
| **R1** | A native form's declared field rules (`required`, `email`, `max:N`, `pattern:`) are rendered as HTML attributes and enforced by nothing on the server - measured: the handler checks only uploads and "not entirely blank". What should the server do? | **ENFORCE AND REFUSE, with a named reason.** The declaration becomes a contract |
| **R2** | SM747: both credential strategies need a session transport OOM does not have. Take OA3's key-in-cookie fallback, or wait? | **WAIT for OOM to gain the transport, and file to its inbox what is needed.** Filed 2026-10-02 |
| **R3** | SM933: `--fix` declines to set bits it did not create (SM274), so a fresh install cannot reach a clean report. Does that still apply to the installer's own output? | **BOTH**: provision gets it right, and `--fix` repairs the installed set |

| **R4** | [[SM941]] AV2: two human totals 2,870 apart on one report, and `status_codes` sums to the LARGER - so either 43% of human requests were 404s, or the status codes describe a population the report never names. Which counter is the human population? | **MEASURE THE GAP FIRST.** The 2,870 is a specific set of requests and can be characterised - agents, paths, intervals - so AV2 becomes a reading of data rather than a preference. Nothing is built on a guess |
| **R5** | [[SM941]] H1: the invariant test fails on commit, because the contradictions are live. Land it failing-but-marked, land it as a reporting diagnostic, or hold it? | **HOLD H1 until AV2 is ruled**, then write the test and the fix together so it is green on arrival. The arithmetic stays unchecked in the meantime, and that is accepted deliberately |
| **R6** | [[SM942]] FO3: a feed emits every dated page on every poll. Cap it? | **CAP AT 50, CONFIGURABLE.** The conventional shape, plus `lastBuildDate`. 50 costs no current site anything - xisl.com's 59 loses its 9 oldest from the FEED, not from the site |
| **R7** | [[SM824]] F1: the head meta variables reach a layout already HTML-escaped with no inverse and there is no `json` filter, so JSON-LD from front matter is unreachable. Expose a raw copy and ship a filter, or walk-and-escape `sections` and foreclose it? | **EXPOSE A RAW COPY AND SHIP A `json` FILTER.** The single-escape-point invariant gains a documented exception - it already has an undocumented one, because `sections` reaches layouts raw today |

| **R8** | [[SM941]]: `human` is the fall-through of `classify()` and means "no automation rule matched" - 43% of it is empty-UA or self-declared automation. Rename it? | **NEITHER OFFERED NAME. EXPLAIN IT INSTEAD**, in the release manager's words: "we can't know it is human, but we can know when it isn't, so whatever is human exists in this group." The group is an UPPER BOUND and the report says so. See **R12** |
| **R12** | Does parking the rename serve any purpose? | **NO - IT WAS A MISTAKE, AND `human` BECOMES `unattributed` IN THIS RELEASE.** The parking rested on a claim I never measured ("breaks every reader, dashboard and layout"): it is 8 usages in ONE file, none in `lib/`, `tools/`, any template or the front end. And this is the one release where consumers must look anyway - schema 2 -> 3, basis 3 -> 4, a class added. Renaming later would be a second breaking change for the same defect, and parking it would have made R8's explanation a compensation for a key we knew was wrong |
| **R9** | 4,227 requests with NO user-agent are counted as human, because the `human` return never consults the `_is_browser` that `classify()` computed | **A POSITIVE BROWSER TEST, AND `no_agent` AS ITS OWN CLASS.** An absent user-agent is a fact worth reporting, not a residual - the 4,227 become visible and separable. Buckets still sum |
| **R10** | `WP-Safe-Scanner`, `WordPress/6.4.3`, `UnifiedPaths`, `SeltzSitemapFetcher`, `GeedoShopProductFinder` and **our own `lzs-fetch`** all land in the human group | **MATCH SELF-DECLARATION, NOT A VENDOR LIST**: scanner, fetcher, crawler, spider, -finder, `WordPress/`, `curl/`, `wget/`, python-requests - so the next tool of this shape is caught before anyone notices it. `lzs-fetch` joins `$AGENT_RE` |
| **R11** | `/websocket`, 5,418 requests, all 404 | **COUNTED OUTSIDE THE GROUP.** Cause identified by the release manager: the domain replaced a site that used websockets and a browser is still reconnecting. Not this engine's defect, and not a visit - a persistent reconnect to a path that has never resolved is automation by behaviour whatever its UA says |
| **R13** | [[SM933]] A2: the private store is created BESIDE the docroot, so it takes the site root's group and the CGI cannot write it. `secure_write_perms` inherits from the immediate parent - the wrong source for that path. Which group should provision give what it creates? | **INHERIT FROM THE DOCROOT.** One rule for everything provision creates, siblings outside the docroot included. No new argument; correct wherever the docroot is already set up for the server |
| **R14** | [[SM933]] A3: measured, every directory provision creates already carries setgid (0 without, both runs), so the field report's five were pre-existing or reset afterwards. Proceed how? | **WITHDRAW A3**, with the measurement. PR5's rebuild warning and PR1's health check already cover the reset case |
| **R15** | [[SM939]] E1 content half: a fresh install ships lazysite's demo and ~70 docs pages onto the owner's domain. What should it ship? | **KEEP THE DEFAULT, ADD AN OPT-OUT FLAG (E2).** The reporter's own ranking and the smallest change; the permissions half closes with A2 |

**R4 IS DISCHARGED AND H0 IS WITHDRAWN.** It asked for the gap to be measured before
AV2 was ruled; the measurement found the answer in the SOURCE, so the diagnostic that
was scheduled for it is not built. AV2 is answered rather than ruled - see [[SM941]].

**R9/R10/R11 CARRY A MANDATORY CONSEQUENCE: counting basis 4 and schema_version 3.**
They move traffic out of the reported group, so counts DROP per site on the upgrade
date - a metric change wearing the clothes of a traffic change. `stats.pl:140` carries
the basis ladder precisely because this went wrong once before ("an operator asked why
traffic dropped on 27 July"). The bump ships with them or they do not ship.

**R4 and R5 interlock, and the order is the point:** measure the gap, rule AV2 on
what it shows, then H1 and the fix land together. R5 is the one ruling here that
accepts a known gap rather than closing it, and it is recorded as a choice so that
nobody later reads "no test" as an oversight.

**What R4 cost, and what it bought.** It needed data this tree cannot see, and the
release manager supplied one day's user-agent distribution. That, plus the source,
answered AV2 outright and found three defects nobody had asked about - including our
own `lzs-fetch` counted as a human visitor. The scheduled diagnostic was never
written: measuring first removed the need for the instrument.

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
| A1 | PR0 | **MEASURED** (n233). Candidate 2, and wider than the filing supposed: `install.pl` never sets a group on anything - the kernel decides. Candidates 1 and 3 refuted (run A gave the PRIMARY group on all 202 paths, uniformly, from the first created directory). `secure_write_perms` works and is **never called** from the install path | S | nothing |
| A2 | PR2 | **BUILT** (n236), to R13: every path the installer creates takes the docroot's group, the private store included; existing paths untouched. The field-shape fixture now passes its own health check | M | nothing |
| A3 | PR3 | **WITHDRAWN (R14).** Premise contradicted by A1: every directory provision creates already carries setgid. The reset case is PR5's warning plus PR1's check | - | done |
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
| B1 | **BUILT** (n233). Enforced from a RENDER-TIME SIDECAR, which was a ruling: the rules were not available to the handler at all, and `_page` is visitor-supplied so it could not locate them. The hazard is closed properly - a pattern the browser could not compile is asked about by name (lint 204's helper) rather than judged again. A validation refusal is counted under its OWN outcome, not as an anti-spam block | M | nothing |
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
| C1 | **MEASURED AND BUILT** (n234). Three answers, not one: AO1 (pages) does NOT reproduce - CF-2 already takes the rule with the content; AO4 (move) already re-keys correctly; **AO3 (tables) REPRODUCED in the GRANT direction** and is fixed in `drop_table`; AO2 (the create notice) built, narrowed to the ancestor-rule case that remains. Both already-correct halves are pinned by test, because nothing asserted them | M | nothing |
| C2 | **SHIPPED** earlier in 0.15.2 (the small-batch commit, with a new SM937 subtest in t/integration/65): `_acl_gates_public` is consulted, so `draft` is no longer reported as an unrestricted read. Row corrected here - it shipped and the plan still said `nothing` | S | nothing |

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
| E1 | [[SM939]] - permissions half **CLOSED by A2** (n236): the directories were always 2775 and are now in the docroot's group. Content half ruled R15 -> E2 | M | done |
| E2 | [[SM939]] SC3 - an install flag for no starter content. **RULED R15: build it; the default stays as today** | S | nothing |

E1's permissions half is a defect and is almost certainly the same mechanism as
[[SM933]]: directories created with a group or mode the server cannot write. A1's
fixture measurement should cover `docs/` as well as `lazysite/`, so one measurement
answers both.

# Group G - the front-matter parser

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| G1 | [[SM940]] - a quoted scalar in a block sequence under `sections:` is read as a mapping, so `- 'https://x'` becomes `{ "'https" => "//x'" }`. Silent: the layout gets maps where it expected strings and the page merely renders wrong. **Reported against 0.14.4 and reproduced here against 0.15.1** | S | nothing |

G1 is an ordering change in one sub with one definition and no pinned copy, so ADR
0001 does not apply. The filing records why the obvious spelling of the fix is wrong:
a line that merely starts and ends with a quote also describes `'a': 'b'`, a
legitimate quoted-key mapping, so the test must be that the opening quote CLOSES at
the end of the line. That case has to be in the tests or the fix trades one defect
for another.

# Group H - what the reports tell a site owner

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| H0 | ~~Measure the gap~~ **WITHDRAWN**: R4 is discharged and the diagnostic was never needed - the split was in the source. Kept as a row so the plan records that an instrument was scheduled and then not built |  | done |
| H1 | **BUILT** (n232). The invariant test, `t/unit/plugins/46-one-report-does-not-contradict-itself.t`, GREEN. Writing it found a row that was not in the plan: `status_codes` counts ONE class and the report named that nowhere, so every counter now declares its population | S | H2, H3 |
| H2 | **BUILT** (n232). Three-way split in `_apply_event` - `error_hits`, `asset_hits`, `hits` - all three published, and they sum to the class by construction. An asset 404 used to reach `hits`, because the old branch needed `$st < 400` to get to `asset_hits` at all | M | nothing |
| H3 | **BUILT** (n232). `unique_visitors` reads `cls_ips{unattributed}`; `traffic_classes[].visitors` added so nothing is lost; `totals.human_visits` REMOVED (one scalar, one name); `window_scoped` enumerated per field, with `events` deliberately absent from it | S+S+S | nothing |
| H6 | **BUILT** (n232). Renamed, with the upper-bound explanation in `notes`, the manager tiles and the agent briefing. `no_agent` returns BEFORE the visit split. The cache is MIGRATED on load - a comment I wrote claiming schema 3 would discard it was measured false, and without the migration that traffic would have left every breakdown while staying in `hits` | M | nothing |
| H7 | **BUILT** (n232), with H6 in one commit as required. Basis 4, schema 3, the ladder entry - and `counting_basis` + `counting_basis_in_window` **published in the report**, which they never were: the instrument SM338 built could not be read from the output that raises the question | S | H6 |
| H4 | [[SM942]] FO1/FO2 - feeds sorted newest-first **in the engine, on the raw ISO date**. Not in the template (bucket `seed` - an upgrade never replaces it, so a template fix reaches no existing site) and not on `page.date` (already RFC 822 by then, so the sort would order by weekday name) | S | nothing |
| H5 | [[SM942]] FO3 (R6) - `feed_items` capping at 50 by default, plus `lastBuildDate`. Same template and the same sort as H4, so it goes with it | S | H4 |

**Every row in this group is now unblocked.** H2, H3, H6 and H7 follow from the
measurement; H4 + H5 are one piece of work (the sort and the cap are the same template
and the same pass, settled by R6); and H1 lands last, green, which is what R5 held it
for.

**H6 and H7 are one schema change, not several.** The renamed key, the new class, the
tightened rules and the moved traffic all land together with basis 4 and schema 3 -
because a consumer should adapt once. The release manager's position on the numbers
falling is that operators seeing facts instead of fantasy is the point; the basis
marker stays for the engineering reason only, which is that a day counted one way is
not comparable with a day counted another.

# Group F - held, and one of them asks a question

| Ref | What | Why held |
| --- | --- | --- |
| F1 | **RULED R7, so it is no longer held** - see Group I below |

# Group I - JSON-LD from a layout becomes possible (R7)

| Ref | The work | Cx | Blocked on |
| --- | --- | --- | --- |
| I1 | A RAW copy of the head meta values beside the escaped ones. `_esc_html` is applied in stash assembly over `page_meta_title`, `page_meta_desc`, `page_title`, `page_subtitle`, `page_author` and `page_<key>`, and there is no inverse - so a layout cannot recover the author's text | S | nothing |
| I2 | A `json` filter in `%tt_opts` FILTERS, which ships `markdown` and no JSON encoder today. Hand-rolled quoting in a template is the thing this exists to avoid | S | nothing |
| I3 | The documented exception: the single-escape-point invariant now has a named one, written where the invariant is stated rather than only in this plan. `sections` already reached layouts raw, so the exception describes what was true as well as what is new | S | I1, I2 |

**The security angle is de-rated by the reporter and that matters for sizing:** an
XSS-shaped payload in front matter renders through the shipped `bio-modest`
components, and they say plainly *"it is not an escalation. Only the page author can
write front matter, and that same author can already put raw HTML in the page body."*
Nothing becomes reachable that was not reachable before.

# Not in 0.15.2

| What | Why |
| --- | --- |
| [[SM747]] slices B, C and D | R2: waiting on OOM's session transport. Slice E (the MCP surface) is unblocked but delivers an agent-facing surface and no page UI |
| The OOM delivery shape | Left open by the release manager while OOM is under test; it is a decision for all of OOM's consumers |
| [[SM923]] limit 1, the section construct | Waiting for a second long form to ask |
| B3's detection signatures | Not ruled, and offered as signatures rather than a request |
| *(nothing - the rename came off this list under R12)* | |

# What this plan is honest about

**Ten inbox reports are now filed** - the eighth, ninth and tenth arrived while
group A was being built. [[SM941]] and [[SM942]] are both grade A on live sites, and
both needed a correction rather than straight transcription: SM942's proposed fix
would have reached no existing site (the registry templates are bucket `seed`), and
SM941's three findings include one that is probably correct behaviour reading as
broken, which is recorded as a presentation row rather than an arithmetic one.

**All eight earlier inbox reports are filed** - [[SM934]], [[SM935]], [[SM936]],
[[SM937]], [[SM938]] (two reports, merged because the second says they are one
problem), [[SM939]] and [[SM940]], with the JSON-LD measurements folded into
[[SM824]] because the report that carried them asked for that rather than a filing of
its own. The reports have moved to `inbox/archive/`.

The eighth arrived after the other seven were filed and is the same class as the
JSON-LD measurements it follows: **quoting loses.** It was reported against 0.14.4,
and the thing worth carrying is that it reproduces against the current tree - a
report against a released version is checked before it is scheduled, because the
answer is sometimes "already fixed", and here it is not.

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
