---
id: SM888
title: "SM888: the field backlog at 0.14.2 - nineteen findings that only existed in an inbox"
subtitle: "The 1315S stable-gate walks and the 0.14.x field reports between them produced nineteen engine findings that were read, acted on where they blocked a release, and otherwise left in the inbox. Ref-numbered here by family rather than by report, because four of them are one cause wearing four faces."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-09-15 at the release manager's direction - 'make sure all other items are digested and filed in the queue'. NOT NEW WORK: every row is a finding already reported by the sites agent, with its evidence, and in most cases with the fix the reporter proposed. The point of the filing is that an inbox is a queue of things to READ and a backlog is a queue of things to DO, and these had stayed in the first. GROUPED BY CAUSE, NOT BY REPORT: the F rows come from three different walks and one edge report and are one suspected defect - actions whose subject is not a path pass no target and fall through to '/'. Rows are classed ENGINE (this repo), ESTATE (a site or host, the sites agent's) or OPERATOR (needs a shell or credential nobody here holds); only ENGINE rows are candidates for a release. SELECTED FOR 0.14.3: see docs/feature-requests/WORK-PLAN-0143.md."
---

# Why a digest and not nineteen filings

Three of these families are one defect each, reported from different angles by
different walks. Filing them separately would have produced nineteen items, of
which four would be fixed four times or - more likely - once, with the other
three left looking open.

The F rows are the clearest case: a connector audit, a group-nest audit, a
group-settings audit and a handler-save audit, from four separate reports,
which the reporter had already noticed share a shape.

# F - the audit trail cannot name its subject

**Suspected one cause**: an action whose subject is not a path passes no target,
and everything without a target falls through to `/`. `user-group-remove`
already proves the `a@b` format works, so the shape exists and is not reached.

| Ref | Finding | Class | Evidence |
| --- | --- | --- | --- |
| F1 | Every connector audit event records its target as `/`, so the trail cannot say which connector sent data out, received a credential, or was saved | ENGINE | Five events (2 `connector-save`, 1 `connector-secret-set`, 2 `connector-call`) all `target=/`. `connector-calls` DOES record `connector: s08-req`, so the identifier exists and is simply not passed. Sharpest case is `connector-secret-set`. |
| F2 | `user-group-nest` audits with no target and no detail - the operation that hands one group's whole capability set to another records no subject at all | ENGINE | `remove` records `s05-child@s05-parent`; `add` records `ui-test-2@s05-delegate`; `nest` records nothing. |
| F3 | `user-group-settings-set` records the group but not the capability or the value, so consecutive grants are indistinguishable | ENGINE | Five consecutive rows against one group; one of them may have granted `api` and the trail cannot say which. Reporter's fix: `<capability>=<value>` in `detail`. |
| F4 | `handler-save` and `form-targets-save` name `/` as their subject | ENGINE | Seen during the 0.14.1 edge walk; not in that report's do-not-refile list. |

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
| A1 | The shipped feeds emit the front-matter date raw, where RSS and Atom require a formatted timestamp | ENGINE | Fix: format at the registry, not in front matter - a `date_rfc822` / `date_rfc3339` pair. |
| A2 | Editing an included partial does not refresh the pages that include it | ENGINE | Fix: record each resolved include as a render dependency exactly as [[SM311]] records `json:` sources. The dependency machinery exists; includes do not use it. |
| A3 | A page in a protected section cannot include its own partials | ENGINE | Fix: the guard should accept a resolved path under the content root **or** under that content root's private store. Same family as [[SM852]]'s gated-path rows. |
| A4 | `page-pdf` refuses any draft or gated page - the `-f` docroot test runs one line before [[SM738]]'s resolver | ENGINE | Fix, quoted: move the `-f` test after the resolve callback. One line. |
| A5 | A single-box required checklist submits unticked, and the visitor is then told delivery is off | ENGINE | Two defects in one report: the `required` attribute is omitted for a single-box group, and the refusal copy names the wrong cause. |
| A6 | A refused DAV PUT answers 403 under ~100 KB and 502 above it | ENGINE | The same ask as the 0.13.13 cutover report ten weeks earlier: *"not a status code for a size limit - a write that fails"*. Two reports, one defect, and the older one is why this should not wait again. |
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
