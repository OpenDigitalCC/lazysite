---
title: "Work plan - 0.14.3"
subtitle: "One feature, one debt item already built, and the field backlog's cheapest and sharpest rows. Selected 15 September 2026 while 0.14.2 was still building, from SM888's nineteen findings plus SM659's residue and the claude.ai validation skill."
brand: plain
standard-margins: true
---

# What this release is

0.14.1 and 0.14.2 were both corrections to the same thing: a site serving code
or renders it no longer ran. That thread is closed, and what is left in the
queue is a backlog rather than an incident.

So 0.14.3 has a different shape. **One feature** (the claude.ai validation
skill), **one piece of debt that is already built and waiting**, and a
deliberate pass through the field findings that have been sitting in an inbox -
taking the ones that are cheap, the ones that are sharp, and leaving the rest
named rather than forgotten.

# The package

Refs are this plan's; the source ref is given so each row can be traced back.

## Already built, waiting on the queue

| Ref | Item | Source | State |
| --- | --- | --- | --- |
| P1 | The release tarball stops carrying the previous release - `download/ export-ignore`, 34.2 MB to 6.5 MB | [[SM884]] | **DONE** - landed on `main`. It takes effect at 0.14.3: the 0.14.2 build was already running when it went in, so that tarball still carries 0.14.1. |

P1 was listed first because F1 was thought to depend on it, and then because it
was finished and waiting. Neither is true now: the skill carries its own debs
rather than fetching a tarball, and P1 has landed. Kept as the record of what
0.14.3 already contains.

## The feature

| Ref | Item | Source | Notes |
| --- | --- | --- | --- |
| F1 | A claude.ai skill that installs lazysite locally, runs the dev server, pulls the editor's own theme and layout through their MCP connector, and validates content before it is published | [[SM887]] | Additional to MCP, required by nothing. Deliverables are a skill folder in the repo, a zip attached to each release, and a docs pointer. |
| F2 | A processor `--validate` mode: structured messages, non-zero exit | [[SM887]] Q5 | **BUILT 2026-09-15 - as `Lazysite::Validate` plus `lazysite validate`, NOT as a processor flag.** The processor is a request handler that reads its input from CGI environment and parses two arguments in 8,700 lines; bolting a file mode onto it would have added a second way in to serve one caller. The checks were already written and already good - they were locked inside `lazysite-mcp.pl`, reachable only by an authenticated partner over HTTP. So they moved, MCP became a consumer, and the shell got the entry point that carries the exit status. **Decide before F1 is built, build after.** The briefing asked for it to be raised separately rather than folded in, and it should be: a validation contract the engine owns beats a skill that greps for error text and breaks when the wording changes. |

**F1 carries an operator dependency** and it should be settled before the work
starts, not at acceptance: the acceptance test needs a clean Ubuntu 24.04
container with the allowlist applied. No OS packages can be installed on this
host, and docker here is bounded by the standing rule about the daemon.

## The audit trail - one cause, four symptoms

| Ref | Item | Source |
| --- | --- | --- |
| A1 | An action whose subject is not a path records `/` | [[SM888]] F1-F4 | **DONE, and smaller than this plan said.** |

**Three of the four were already fixed when I scoped this**, by N141B-C in
0.14.1: the connector family, `user-group-nest` and `user-group-settings-set`,
pinned by `t/unit/manager/158`. The walks reporting them ran on 0.13.15 and
0.13.16, and I digested those reports without checking whether the work had
since been done.

Only `handler-save` / `form-targets-save` was open — reported on the 0.14.1 edge
walk, *after* N141B-C, so it is the residue of the cause rather than a repeat.
Reproduced against the running API (`op | handler-save | / | fail`) and fixed
with a branch for the family; `t/integration/100`.

Worth keeping: the two actions spell their subject differently, and that was
**measured, not read off the dispatcher** — handler actions carry `id`, while
`form-targets-save` refuses *"form is required"* when sent one. A fix written
from the source alone would have covered half of it and passed a source check.

## The rollout report

| Ref | Item | Source | Why now |
| --- | --- | --- | --- |
| Q1 | The quiet fleet rollout prints ~200 lines to say "29 updated, 0 failed" - [[SM701]]'s contract held and every phase added since ignored it | [[SM889]] | Raised by the release manager watching the 0.14.2 deploy. It is a regression, it gets worse with each phase added, and the fix is structural (one reporter that owns the verbosity level) rather than more conditionals. |
| Q2 | One rollout message is truncated mid-sentence, ending in a colon with nothing after it, on all 29 sites | [[SM889]] D1 | A defect rather than noise, and independent of Q1. Whatever it was meant to say, nobody has read it for some time. |

## Verified, 2026-09-15 - and most of what was here had already shipped

**Seven rows in the first draft of this plan shipped in 0.14.1.** They were
drawn from [[SM888]] without cross-checking the 0.14.1 CHANGELOG, and SM888 had
itself been drawn from an inbox without that check. Struck below with what
closed them, because a plan that overstates what is left is one somebody
budgets from:

| Was | Row | Closed by |
| --- | --- | --- |
| ~~C1~~ | `page-pdf` on a draft or gated page | N141B-A |
| ~~C2~~ | `list` requires a leading slash | N141B-B |
| ~~C3~~ | Services holder line keeps the future tense | N141-01 |
| ~~C4~~ | "0 log lines scanned." | N141B-F, deleted rather than implemented |
| ~~C5~~ | Site settings blank without `manage_config` | SM775 in 0.13.9; the padlock half was ruled out - you cannot padlock where somebody lands |
| ~~S1~~ | stats bar hides 58.7% of its traffic | N141B-F |
| ~~S2~~ | `granted_by` names the membership group | N141B-D |
| ~~S3~~ | phantom member after deleting a nested group | N141B-E |

## What is actually open

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| K1 | A refused DAV PUT answers 403 under ~100 KB and 502 above it | [[SM888]] A6 | **BUILT 2026-09-15, and the cause was exactly as located.** Reproduced first: a 512 KB refused PUT let the client write 65,536 bytes - one pipe buffer - and then broke the pipe, which is the ~100 KB the field measured. The drain is ONE call in `send_response`, the place every answer leaves through; putting it beside each refusal would be the same line in fifteen copies. `t/unit/dav/30`. **The cause was located before the fix and it is smaller than it looked.** `authorise()` returns 403 and sends the status before anything reads STDIN, and nothing drains the unread body - so under the socket buffer the client sees the 403, and above it the client blocks on a body nobody reads and the front end answers 502. One refusal, one missing drain. Re-measured on 0.14.2 with byte-identical re-PUTs of the site's own live bytes. |
| K2 | The shipped feeds emit the front-matter date raw | [[SM888]] A1 | **BUILT 2026-09-15.** RSS gets RFC 822, Atom gets RFC 3339, and the formatting is in the ENGINE rather than the template - the registry templates install under bucket `seed`, so an upgrade never replaces them and a template-only fix would have reached new sites only. An unparseable date is passed through rather than replaced with "now". `t/integration/102`. Re-measured on 0.14.2 with the stale-render explanation ruled out. Changes published output for every feed subscriber at once, so it goes in deliberately rather than quietly. |
| K3 | A form posted within a second fails with a generic error | [[SM888]] A7 | **No longer a guess.** `reject('Submission too fast')` dies plain, where `reject_user` dies `USER:...` and only `USER:` messages reach the submitter. SM252's token is refusing correctly and its reason is discarded one word away from being shown. |
| K4 | Editing an included partial does not refresh the pages that include it | [[SM888]] A2 | `_resolve_include` reads the file and never records it; SM311's dependency machinery has four call sites and none is in the include path. |
| K5 | A page in a protected section cannot include its own partials | [[SM888]] A3 | The include guard tests `_path_under($real, $REQUEST_CROOT)`, and the private store is a **sibling** of the docroot, not under it. |
| K6 | Two stats blocks still name no denominator | [[SM888]] S3 | Partially done: N141B-F built `tile(label, value, note)` for exactly this and applied it to one tile. Page views and Devices still carry none. |

K4 and K5 stay together: both are about includes, both touch the same guard, and
doing one without the other means reading that code twice.

**K3 first.** It is one word, the cause is located, and it is the only one of
these a visitor hits.

## Still deliberately out

| Item | Source | Why |
| --- | --- | --- |
| The no-CDN gate | [[SM888]] C1-C2 | Confirmed still open. Wants a rendered-page fetch that follows stylesheets - a new capability for `lazysite check`, not a check added to it. Its own slot. |
| The assets count including renders | [[SM888]] P2 | Confirmed still open, and cosmetic; the reporter said so. |
| `required` on a single-box checklist, and its refusal copy | [[SM888]] A5 | Confirmed still open, both halves. The second needs the refusal path read before anything changes. |

## The diagnostic the last two releases both wanted

| Ref | Item | Source | Why now |
| --- | --- | --- | --- |
| T1 | Nothing a token can reach names which service template a site runs | [[SM890]] | Asked for in the 0.14.1 test plan and again in the 0.14.2 one, and reported both times as the single fact the field cannot read. Each time it would have said whether a stale reading was a pooled worker or something else. **Every site is current now, so nothing is blocked - which is the moment to add a diagnostic**, rather than discovering for a third time that the question cannot be answered while something is broken. Carries one decision: public endpoint or partner-only. |

## Docs

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| X1 | The practice briefing gains a Part-two section - name the app, decide whether it is internal or public, give its parts one home - placed before *Start with the design system, not the pages*, because that section begins at the schema and this is the layer below it | sites agent, 2026-09-14, from building a real app whose parts ended up in three places | **The proposed text targets the wrong file, and it is an easy mistake to repeat.** `starter/docs/ai-briefing-practice.md` is GENERATED by `tools/import-field-practice.pl` and pinned by `t/lint/89`; an edit made there is overwritten at the next cut, which is a re-import that happens every release. The text goes into the importer's source. |

## SM659's residue

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| R1 | `perldoc lazysite-users.pl` still tells an operator to run `setup-manager`, a command the dispatcher no longer accepts - and calls it idempotent, which makes it sound safe to try | [[SM659]] | **ALREADY CLOSED at N141B-G - the row was stale when it was written.** The Bootstrap entry names `setup-sysop`, and the paragraph beside it says the name changed and that there is no alias. The only occurrences left in the tree outside `#` comments are that paragraph, `docs/FEATURES.md` recording the deletion, `UPGRADE.md` describing what an old deploy script used to do, and `debian/changelog` - all record, none instruction. Verified by listing every tracked occurrence outside the historical record. |
| R2 | The lint that swept the vocabulary does not read POD, which is why R1 survived it | [[SM659]] | **Half closed at N141B-G, and the other half is now closed.** `t/lint/144` reads the users tool's POD and fails on exactly this defect - confirmed by putting it back and watching it fail. But `t/lint/138`, the check that reads EVERY shipped file, passed on the same sabotage: its proximity rule wants the tool's name within 120 characters of the dead verb, and a manual names its own tool once at the top. So the same mistake in any OTHER tool's POD was caught by nothing. 138 now reads POD as POD, with `t/lint/144`'s excuse rule in the same words, and the sabotage fails it. |

**R3 - the 322 code comments and ~2,079 documentation uses stay staged**, as
SM659 decided and for its stated reason: `operator` genuinely means sysadmin in
some of them and sysop in others, and a batch replace would encode the wrong
principal in an unknown fraction of the security documentation. That is reading
work, not release work.

# Deliberately not in 0.14.3

| Item | Source | Why |
| --- | --- | --- |
| The no-CDN gate | [[SM888]] C1-C2 | Worth doing and not small: it needs a rendered-page fetch that follows stylesheets, which is a new capability for `lazysite check` rather than a check added to it. Wants its own slot. |
| The five sites breaching no-CDN | [[SM888]] C3 | ESTATE. The sites agent has claimed it. |
| `required` on a single-box checklist, and its refusal copy | [[SM888]] A5 | Two defects in one report; the second needs the refusal path read before anything is changed, and neither is reproduced here yet. |
| ~~The feeds' raw date~~ | [[SM888]] A1 | **Moved into the release as S5** after the 0.14.2 walk re-measured it with the stale-render explanation ruled out. |
| A form posted within a second fails generically | [[SM888]] A7 | **Not reproduced.** Likely the SM252 time token refusing correctly and explaining nothing, but that is a guess and this project does not fix guesses. |
| The assets count including renders | [[SM888]] P2 | Cosmetic, and the reporter said so. |
| [[SM881]] / [[SM882]] | ruled 2026-09-14 | Ruled, not built. One piece of work, wanting the ACL-aware resolver first, and it is bigger than this release. |

# Order

1. **P1** - land it; it is finished and waiting.
2. **F2 decision**, then **A1**, then the C rows. All are independent of the
   skill and can be worked while F1's container dependency is being settled.
3. **F1**, once the container question is answered.
4. **S** and **D** rows as the release allows; each is independently droppable.
5. **R1/R2** with whichever pass touches `lazysite-users.pl`.

The only ordering constraint is **F2 before F1**: the skill should be built
against the validation contract, not against whatever text the processor
happens to print today.

# Related

[[SM887]] (the skill), [[SM888]] (the backlog these rows are drawn from),
[[SM884]], [[SM659]], [[SM311]], [[SM852]], [[SM631]].
