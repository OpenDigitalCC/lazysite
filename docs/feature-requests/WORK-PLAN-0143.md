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
| P1 | The release tarball stops carrying the previous release - `download/ export-ignore`, 34.2 MB to 6.5 MB | [[SM884]] | **Committed**, `claude/n142f-sm884-export-ignore`. Handoff gate not yet run - it was held so it could not compete with the 0.14.2 build for memory. |

P1 was listed first because F1 was thought to depend on it. **It no longer
does** — the skill carries its own debs rather than fetching a tarball, so the
60-second budget is an `apt-get` against the Ubuntu archive. P1 stays at the top
because it is finished and waiting, not because anything is blocked on it.

## The feature

| Ref | Item | Source | Notes |
| --- | --- | --- | --- |
| F1 | A claude.ai skill that installs lazysite locally, runs the dev server, pulls the editor's own theme and layout through their MCP connector, and validates content before it is published | [[SM887]] | Additional to MCP, required by nothing. Deliverables are a skill folder in the repo, a zip attached to each release, and a docs pointer. |
| F2 | A processor `--validate` mode: structured messages, non-zero exit | [[SM887]] Q5 | **Decide before F1 is built, build after.** The briefing asked for it to be raised separately rather than folded in, and it should be: a validation contract the engine owns beats a skill that greps for error text and breaks when the wording changes. |

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

## The cheap and certain

Each of these was reported with its cause located or its fix quoted. They are
here because they are small, not because they are urgent.

| Ref | Item | Source | Size |
| --- | --- | --- | --- |
| C1 | `page-pdf` refuses any draft or gated page - move the `-f` docroot test after the resolver | [[SM888]] A4 | One line |
| C2 | `list` requires a leading slash where its siblings do not, and calls a valid folder missing | [[SM888]] P1 | Normalise as four sibling actions already do |
| C3 | The Services holder line keeps the future tense after the switch is thrown | [[SM888]] W1 | Copy |
| C4 | "0 log lines scanned." under a screen of populated charts | [[SM888]] S4 | Copy, and the honest wording is already written |
| C5 | Site settings offered unpadlocked and blank without `manage_config` | [[SM888]] W2 | Padlock, or an empty state naming the capability |

## The sharp

| Ref | Item | Source | Why now |
| --- | --- | --- | --- |
| S1 | The statistics panel hides 58.7% of its traffic and draws the remainder as a complete bar | [[SM888]] S1-S3 | A chart with a missing segment is worse than a table with a missing row. S2 and S3 come with it because they are the same screen and the same confusion: four denominators, none named. |
| S2 | `granted_by` names the group the user is a member of, not the group where the capability is set | [[SM888]] G1 | It diverges **only when groups nest**, which SM631 made the normal case - so this gets worse on its own. An operator following it to revoke a capability lands on a screen where the tick is already clear. |
| S3 | Deleting a nested group leaves the parent holding a phantom member and undeletable | [[SM888]] G2 | Same walk, same subsystem, and there is a workaround only because the reporter found one. |
| S4 | A refused DAV PUT answers 403 under ~100 KB and 502 above it | [[SM888]] A6 | Reported twice, ten weeks apart, and **re-measured on 0.14.2 with a control that removes every other variable**: byte-identical re-PUTs of the site's own live bytes, 77 KB → 403, 284 KB → 502. Split by body size alone. |
| S5 | The shipped feeds emit the front-matter date raw where RSS and Atom require a formatted timestamp | [[SM888]] A1 | **Moved IN, 2026-09-15.** It was held back because it changes published output for every feed subscriber at once - which is a reason to schedule it deliberately, not a reason to defer it indefinitely, and this plan is where that happens. Re-measured on 0.14.2: `<pubDate>2026-09-10</pubDate>` where RFC 822 wants `Thu, 10 Sep 2026 00:00:00 +0000`, and **a stale render cannot explain it** because the feed was regenerated by the PUT on the 0.14.2 engine. |

## The diagnostic the last two releases both wanted

| Ref | Item | Source | Why now |
| --- | --- | --- | --- |
| T1 | Nothing a token can reach names which service template a site runs | [[SM890]] | Asked for in the 0.14.1 test plan and again in the 0.14.2 one, and reported both times as the single fact the field cannot read. Each time it would have said whether a stale reading was a pooled worker or something else. **Every site is current now, so nothing is blocked - which is the moment to add a diagnostic**, rather than discovering for a third time that the question cannot be answered while something is broken. Carries one decision: public endpoint or partner-only. |

## The dependency-shaped one

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| D1 | Editing an included partial does not refresh the pages that include it | [[SM888]] A2 | The fix is to record each resolved include as a render dependency exactly as [[SM311]] records `json:` sources. The machinery exists and includes do not use it. |
| D2 | A page in a protected section cannot include its own partials | [[SM888]] A3 | The guard should accept a resolved path under the content root **or** under that root's private store. Same family as [[SM852]]. |

D1 and D2 are listed together because both are about includes and both touch the
same guard; doing one without looking at the other would mean reading that code
twice.

## Docs

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| X1 | The practice briefing gains a Part-two section - name the app, decide whether it is internal or public, give its parts one home - placed before *Start with the design system, not the pages*, because that section begins at the schema and this is the layer below it | sites agent, 2026-09-14, from building a real app whose parts ended up in three places | **The proposed text targets the wrong file, and it is an easy mistake to repeat.** `starter/docs/ai-briefing-practice.md` is GENERATED by `tools/import-field-practice.pl` and pinned by `t/lint/89`; an edit made there is overwritten at the next cut, which is a re-import that happens every release. The text goes into the importer's source. |

## SM659's residue

| Ref | Item | Source | Note |
| --- | --- | --- | --- |
| R1 | `perldoc lazysite-users.pl` still tells an operator to run `setup-manager`, a command the dispatcher no longer accepts - and calls it idempotent, which makes it sound safe to try | [[SM659]] | The only non-comment occurrence left in the tree. Every other hit is a `#` comment recording history and should stay. |
| R2 | The lint that swept the vocabulary does not read POD, which is why R1 survived it | [[SM659]] | Fixing R1 without this leaves the same gap for the next rename. |

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
