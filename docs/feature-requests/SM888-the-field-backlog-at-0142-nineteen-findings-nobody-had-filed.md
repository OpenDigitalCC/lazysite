---
id: SM888
title: "SM888: the field backlog at 0.14.2 - nineteen findings that only existed in an inbox"
subtitle: "The 1315S stable-gate walks and the 0.14.x field reports between them produced nineteen engine findings that were read, acted on where they blocked a release, and otherwise left in the inbox. Ref-numbered here by family rather than by report, because four of them are one cause wearing four faces."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-09-15 at the release manager's direction - 'make sure all other items are digested and filed in the queue'. NOT NEW WORK: every row is a finding already reported by the sites agent, with its evidence, and in most cases with the fix the reporter proposed. The point of the filing is that an inbox is a queue of things to READ and a backlog is a queue of things to DO, and these had stayed in the first. GROUPED BY CAUSE, NOT BY REPORT: the F rows come from three different walks and one edge report and are one suspected defect - actions whose subject is not a path pass no target and fall through to '/'. Rows are classed ENGINE (this repo), ESTATE (a site or host, the sites agent's) or OPERATOR (needs a shell or credential nobody here holds); only ENGINE rows are candidates for a release. SELECTED FOR 0.14.3: see docs/feature-requests/WORK-PLAN-0143.md."
---

# Verified against the tree, 2026-09-15 — and most of it was already done

**Read this table before any row below.** Every row was checked against the
current tree after two of them were found already fixed by accident. Eleven of
nineteen had shipped in 0.14.1, from walks that ran on 0.13.15 and 0.13.16.

| Row | Status | Closed by |
| --- | --- | --- |
| F1 connector audit target | **FIXED** | N141B-C, 0.14.1 |
| F2 `user-group-nest` audit | **FIXED** | N141B-C, 0.14.1 |
| F3 `user-group-settings-set` audit | **FIXED** | N141B-C, 0.14.1 |
| F4 `handler-save` audit | **FIXED** | 2026-09-15, `t/integration/100` |
| S1 scanner class omitted from the bar | **FIXED** | N141B-F, 0.14.1 |
| S2 "Unique visitors" card | **FIXED** | N141B-F — **relabelled rather than recomputed**, deliberately. The value was a ruling, not an oversight. |
| S3 four unnamed denominators | **PARTIAL** | N141B-F built the `tile(label, value, note)` mechanism *for this row* and applied it to one tile. **Page views and Devices still carry no note.** |
| S4 "0 log lines scanned." | **FIXED** | N141B-F — deleted rather than implemented; the engine never sent the field |
| G1 `granted_by` names the wrong group | **FIXED** | N141B-D, 0.14.1 |
| G2 phantom member after delete | **FIXED** | N141B-E, 0.14.1 |
| C1 no no-CDN gate | **OPEN** | — |
| C2 `@import` invisible to a source scan | **OPEN** | — |
| P1 `list` needs a leading slash | **FIXED** | N141B-B, 0.14.1 |
| P2 assets count includes renders | **OPEN** (cosmetic) | — |
| A1 feeds emit the raw date | **OPEN**, re-measured on 0.14.2 | — |
| A2 includes are not render dependencies | **OPEN** | — |
| A3 protected page cannot include its partials | **OPEN** | — |
| A4 `page-pdf` on a gated page | **FIXED** | N141B-A, 0.14.1 |
| A5 single-box checklist + refusal copy | **OPEN**, both halves | — |
| A6 DAV PUT 403/502 | **OPEN**, cause now located | — |
| A7 form posted within a second | **FIXED in two halves** — the visitor is told why (K3), and the block is counted again (the K3 fix had broken the count; see below) | K3, then n145a |
| W1 Services holder tense | **FIXED** | N141-01, 0.14.1 |
| W2 Site settings blank without the capability | **FIXED / not a defect** | SM775 in 0.13.9 added the empty state; the padlock half was ruled out — you cannot padlock the page somebody *lands* on |

## Two causes this pass located, which the reports did not have

**A6 — the 403/502 split has an explanation.** `lazysite-dav.pl:180-200`:
`authorise()` returns 403 and sends the status **before anything reads STDIN**,
and nothing anywhere drains the unread request body. Under the socket buffer the
client's write completes and it sees the 403; above it the client blocks on a
body nobody is reading and the front end answers 502. So it is one refusal and
one missing drain, not two code paths — which makes it smaller than it looked.

**A7 is no longer a guess.** `plugins/form-handler.pl:669` calls
`reject('Submission too fast')` — and `reject` is `die "$_[0]\n"` (`:789`) while
`reject_user` is `die "USER:..."` (`:792`). Only `USER:` messages reach the
submitter (`:258-262`). So SM252's time token is refusing correctly and its
reason is discarded one word away from being shown. The filing recorded this as
*"likely, and that is a guess"*; it is now the cause, and the fix is one word.

**And the one-word fix broke the count, 2026-09-21.** K3 reworded the two
timing refusals so a person could read them. `_block_reason` — SM216-2's
classifier that turns a refusal into a reason code for the stats day-buckets —
recovered the code by matching the refusal's *prose*: `/Submission too fast/`,
`/Submission expired/`. After the reword those words existed nowhere in the
tree, both refusals fell through to `''`, and the caller reads `''` as "not an
anti-spam control" and records **nothing** — not even a `blocked` line with an
empty reason, which `stats.pl` would have bucketed as `other`. So "controls
stopped N" silently lost two of its five reasons. Reproduced against the
handler (a POST inside the floor: the new message, the correct refusal, and no
form-events directory at all; a successful POST in the same run wrote its
`stored` line). No test named `_block_reason` or any of the five codes, so
nothing caught it. The code now travels *with* the refusal — set by the control
that fires, read once at the catch — and the matcher is gone; `t/unit/forms/16`
drives all five controls and reads the bucket off disk.

## What this says about the filing itself

The digest was drawn from the inbox without cross-checking the 0.14.1 CHANGELOG,
so it presented eleven closed items as open work. An inbox records what was true
when it was written; a backlog is supposed to record what is true now, and the
gap between those two is exactly what this filing was created to close. It
reproduced the fault it was documenting.

# Why a digest and not nineteen filings

Three of these families are one defect each, reported from different angles by
different walks. Filing them separately would have produced nineteen items, of
which four would be fixed four times or - more likely - once, with the other
three left looking open.

The F rows are the clearest case: a connector audit, a group-nest audit, a
group-settings audit and a handler-save audit, from four separate reports,
which the reporter had already noticed share a shape.

# F - the audit trail cannot name its subject

**CORRECTED 2026-09-15: three of these four were already fixed when I filed
them.** F1, F2 and F3 were closed by N141B-C in 0.14.1, with a resolver branch
for the whole connector family and explicit cases for `group-nest` and
`group-settings-set`, pinned by `t/unit/manager/158`. The walks that reported
them ran against 0.13.15 and 0.13.16.

I digested those reports without checking whether the work had since been done,
which is the reading half of the same mistake this filing exists to fix: an
inbox tells you what was true when it was written. **Only F4 was open**, and it
is the one reported *after* N141B-C landed — the residue of the cause, not a
repeat of it. Fixed, with `t/integration/100`.

**The one cause**: an action whose subject is not a path passes no target, and
everything without a target falls through to `/`. `user-group-remove` already
proves the `a@b` format works, so the shape exists and is not reached.

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| ~~F1~~ | **ALREADY FIXED** (N141B-C, 0.14.1). Every connector audit event recorded its target as `/`, so the trail cannot say which connector sent data out, received a credential, or was saved | ENGINE | Five events (2 `connector-save`, 1 `connector-secret-set`, 2 `connector-call`) all `target=/`. `connector-calls` DOES record `connector: s08-req`, so the identifier exists and is simply not passed. Sharpest case is `connector-secret-set`. |
| ~~F2~~ | **ALREADY FIXED** (N141B-C, 0.14.1). `user-group-nest` audited with no target and no detail - the operation that hands one group's whole capability set to another records no subject at all | ENGINE | `remove` records `s05-child@s05-parent`; `add` records `ui-test-2@s05-delegate`; `nest` records nothing. |
| ~~F3~~ | **ALREADY FIXED** (N141B-C, 0.14.1). `user-group-settings-set` recorded the group but not the capability or the value, so consecutive grants are indistinguishable | ENGINE | Five consecutive rows against one group; one of them may have granted `api` and the trail cannot say which. Reporter's fix: `<capability>=<value>` in `detail`. |
| F4 | `handler-save` and `form-targets-save` named `/` as their subject | ENGINE | **FIXED 2026-09-15.** The only row of this family that was genuinely open - reported on the 0.14.1 edge walk, AFTER N141B-C. Reproduced against the running API: `op | handler-save | / | fail`. Two keys, measured not assumed: handler actions carry `id`, `form-targets-save` carries `form` and refuses "form is required" when sent an id. `t/integration/100`. |

**Why it matters beyond tidiness:** `connector-secret-set` and
`user-group-nest` are the two operations in this set that move authority. An
audit trail that cannot name their subject cannot answer the question it exists
to answer.

# S - the statistics panel counts four populations and names none

All four from the same screen. S1 is the one to fix first; S3 is the one that
makes the screen misleading rather than incomplete.

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| S1 | The "Who's calling" breakdown omits the `scanner` class - the largest - while drawing the remaining four as a complete segmented bar with no remainder | ENGINE | Five classes sum to 14,848; scanner is 8,714, **58.7% hidden**. The panel shows 6,134 and presents it as the whole. |
| S2 | The "Unique visitors" card renders the human-class IP count, not the API field of that name | ENGINE | Panel 48, API `totals.unique_visitors` 153, same payload, same moment. Fix: show 153, or label it *people, by address*. |
| S3 | Four different denominators share one screen with none of them named, so "People 1,608" sits above "Page views 1,061" and reads as more people than page views | ENGINE | Page views 1,061 (`human_visits`), People 1,608 (`human` class), Devices 795, the bar's implied whole 14,848. Each block needs to say which population it counts. |
| S4 | The panel prints "0 log lines scanned." under a screen of populated charts, reading as though it found nothing | ENGINE | True - `source` is `first-party`, so the log correctly was not read. Reporter's wording: *"Server log not read - statistics came from the first-party record"*. |

# G - groups

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| G1 | The permissions grid's `granted_by` names the group the user is a MEMBER of rather than the group where the capability is set, so an operator trying to revoke is sent to a screen where the tick is already clear | ENGINE | Grid said `analytics granted by: ['s05-child']`; the store had `s05-parent analytics=True members=['s05-child']` and `s05-child analytics=False`. **Diverges only when groups nest** - which is exactly what SM631's three-layer model made normal. |
| G2 | Deleting a nested group leaves the parent holding a phantom member, making the parent undeletable | ENGINE | `s05-parent members: ['s05-child']` with `s05-child still a group? False`; the parent's delete refuses *"Remove all members before deleting this group (1 remaining)"*. Workaround is `group-remove` naming the dead group as a username. |

# C - the no-CDN rule is a promise with no gate

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| C1 | Nothing in the repo checks the no-CDN rule, and nothing notices when a site is left behind across upgrades | ENGINE | Five live sites fetch fonts from a third-party origin on every page view and survived repeated engine upgrades unreported. The reporter's own framing: months of silence is *"the actual defect here; the fonts are a symptom"*. |
| C2 | A source-only scan cannot see the breach: the reference is inside a stylesheet `@import`, so a markup scan certifies the page compliant | ENGINE | Line 1 of one theme's stylesheet is an `@import` of a Google Fonts URL. Reporter's fix: fetch a rendered page and flag absolute URLs to another origin in the HTML **and in every stylesheet it names**, which catches this without a browser. |
| C3 | The five offending sites themselves | **ESTATE** | The sites agent claims this as theirs: bundle the faces as every current theme does, replace remote images with local copies. Not a release item. |

# P - paths and counts in Files

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| P1 | `list` requires a leading slash on `path` where its sibling actions do not, and reports a valid folder as *"does not exist, or it resolves outside the site tree"* | ENGINE | Cause located by the reporter: the handler strips slashes into its relative form but concatenates the ORIGINAL argument onto the root. `acl-get`, `acl-set`, `acl-remove` and `protected-sections` all normalise already. The shipped page always sends a leading slash, so the UI never trips it - an API caller does. |
| P2 | The assets count includes the engine's own rendered `.html`, so a folder with six uploaded files reports eight assets | ENGINE | `pages: 2` correct and recursive; `assets: 8` = 6 uploads + two renders. Cosmetic, and explicitly not a failure of the check. |

# A - authoring, rendering and delivery

| Ref | Finding | Class | Evidence / proposed fix |
| --- | --- | --- | --- |
| A1 | The shipped feeds emit the front-matter date raw, where RSS and Atom require a formatted timestamp | ENGINE | **RE-MEASURED ON 0.14.2, 2026-09-15, and it stands.** A probe page with `date: 2026-09-10` and `register: [feed.rss]` produced `<pubDate>2026-09-10</pubDate>`; RFC 822 wants `Thu, 10 Sep 2026 00:00:00 +0000`. **A stale render cannot explain it** - the feed was regenerated by the PUT, on the 0.14.2 engine, which is the discriminator that matters now that [[SM886]] exists. Fix: format at the registry, not in front matter - a `date_rfc822` / `date_rfc3339` pair. |
| A2 | Editing an included partial does not refresh the pages that include it | ENGINE | Fix: record each resolved include as a render dependency exactly as [[SM311]] records `json:` sources. The dependency machinery exists; includes do not use it. |
| A3 | A page in a protected section cannot include its own partials | ENGINE | Fix: the guard should accept a resolved path under the content root **or** under that content root's private store. Same family as [[SM852]]'s gated-path rows. |
| A4 | `page-pdf` refuses any draft or gated page - the `-f` docroot test runs one line before [[SM738]]'s resolver | ENGINE | Fix, quoted: move the `-f` test after the resolve callback. One line. |
| A5 | A single-box required checklist submits unticked, and the visitor is then told delivery is off | ENGINE | Two defects in one report: the `required` attribute is omitted for a single-box group, and the refusal copy names the wrong cause. |
| A6 | A refused DAV PUT answers 403 under ~100 KB and 502 above it | ENGINE | **RE-MEASURED ON 0.14.2, 2026-09-15, and it stands** - with the sharpest possible control: byte-identical re-PUTs of the site's own LIVE bytes (GET then PUT), so nothing about the content differs. `main.css` at 77 KB → **403**; `hero-plate-v3.jpg` at 284 KB → **502**. Same refusal, two status codes, split by body size alone. The same ask as the 0.13.13 cutover report ten weeks earlier: *"not a status code for a size limit - a write that fails"*. |
| A7 | A form posted within a second of page load fails with a generic error | ENGINE | Seen on the 0.14.1 edge walk. Likely the time token ([[SM252]]) refusing correctly and saying nothing useful; needs reproducing before it is called either. |

# W - wording

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| W1 | The Services holder line keeps the future tense after the switch has been thrown | ENGINE | One line of copy; reported twice. |
| W2 | Site settings is offered unpadlocked and renders blank to an account without `manage_config` | ENGINE | Fix: padlock it like the others, or render the page's own empty state naming the capability that opens it. |

# Not in this filing, and why

| Item | Where it belongs |
| --- | --- |
| The beta sites' "old file still served" after a gate change | **ESTATE** - measured as front-end cache, not engine. The engine's own warning already cites 60 seconds on a default nginx. |
| `lazysite check --domain` / `--check-acl` unexercised | **OPERATOR** - needs a shell nobody here holds. |
| [[SM496]]'s new-capability banner unwalked | **OPERATOR/ESTATE** - all thirteen groups on edge report `pending: []`, so it cannot be triggered without fabricating a store entry. |
| The surviving `setup-manager` reference in POD | [[SM659]], which is still `partial`. Recorded there, not here. |

# Related

[[SM852]] (the same digest shape, and A3's family), [[SM311]] (A2's mechanism),
[[SM738]] (A4), [[SM252]] (A7), [[SM631]] (why G1 diverges now), [[SM659]].
