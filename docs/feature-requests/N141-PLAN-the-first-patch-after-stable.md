---
title: "0.14.1 plan: the mop-up after the first stable"
subtitle: "Four items in, four out with reasons, and four pieces of admin that are not release content. The bar is the release manager's: low risk, provable, and currently wrong - no new features for two weeks, and stable kept in good shape rather than improved."
brand: plain
status: plan
raised: 2026-09-13
raised-by: dev, after the 0.14.0 cut
area: release
---

# What this is for

0.14.0 is the first stable of the 0.13 line and takes 20+ sites off 0.12.1.
There will be **no new features for two weeks**. So 0.14.1 is a mop-up, and the
bar every item below has to clear is:

- **low risk** - contained, and not in a path every page depends on;
- **provable** - it can be shown wrong before the fix and right after;
- **currently wrong** - not an improvement, a correction.

Anything that is merely a good idea is out, and said so.

# IN - four items

```datatable
columns: Ref | Item | Where
widths: 2cm | X | 6cm
bold: 1
tone: medium
---
N141-01 | the Services holder line keeps the future tense | `starter/manager/config.md`
N141-02 | a relative `--stage-dir` produces a wrong verdict | `tools/release.sh`
N141-03 | two manual checks describe furniture that was retired | `docs/MANUAL-CHECKS.md`
N141-04 | Site settings renders blank without `manage_config` | `starter/manager/config.md`
```

## N141-01 - the holder line tells an operator what would happen if they threw a switch they have already thrown

Found by the site agent walking tier-B B8 on 0.13.16, which otherwise passes
cleanly. `refreshServiceCounts()` builds a constant sentence:

> Held by **4** groups / **7** accounts. Switching this off makes those grants
> inert.

It renders identically whether the service is on or off. With MCP already
disabled, seven accounts were inert at the moment that sentence described them
as the consequence of a future decision.

**The counts are right; the sentence is false.** And it is false for the reader
who most needs it true - the one who arrives at an already-off service trying to
work out why an agent stopped working. The Users page gets the same fact right
one screen away (⚠ *"granted, but the service is OFF site-wide"*, present
tense), so the product already knows and only one of two screens says so.

**Why it is low risk:** `channel-services` is already fetched by this page
immediately before the holders call, and `refreshServiceCounts` runs after both
land - the state is in hand at the point the sentence is built. One branch.

**Provable:** render with a service disabled and assert the present tense; the
current code cannot produce it.

## N141-02 - a relative --stage-dir produces a wrong verdict, not an error

`tools/release.sh` reads its suite pass/fail from `.gate-output.txt`. Given a
relative `--stage-dir`, `tee` cannot create that file and the script concludes
**failure** from an empty read. Observed on the 0.13.16 cut: the suite printed
`All tests successful. Result: PASS` and the script reported `test suite failed;
not releasing.`

A bad path should be refused up front, not silently invert the result. Resolve
the stage dir to an absolute path, or refuse a relative one.

**Tooling only - this never reaches a site.** Verified end to end by fixing the
path and watching the `tee:` errors go to zero.

**Not a defect, and recorded so nobody re-files it:** `release.sh` exits 1 on
every refusal. `abort_build` ends in `exit 1` and the coverage-floor refusal at
:641 does too. I reported an exit-0 twice during the 0.13.16 cut and was wrong
both times - I had read the harness background task's status, not the script's.

## N141-03 - two manual checks describe furniture that was retired

Documentation, zero product risk, and it saves the next walker real time.

- **B5** speaks of the *Protected sections panel/card*. **SM635 retired it** -
  `loadProtectedSections()` says so in its own first line - and protection now
  shows as a padlock on the folder's own row. The check is right about the
  behaviour and wrong about where to look.
- **B4** should note that a **gated** section is also absent from the sitemap.
  The check only mentions draft, and the agent found the wider truth while
  discriminating it.

Both came from walks that PASSED. They are the check text drifting from the
product, which is the same class this project keeps closing in code.

## N141-04 - Site settings renders blank to an account that cannot use it

The one worth real care. An account holding `ui` but not `manage_config`:

- sees **"Site settings" with no padlock**, while Domains, Audit log, Connectors
  and Data tables are all correctly padlocked in the same nav;
- follows it to a 200 that renders **nav chrome and nothing else** - 480
  characters of body text, requesting only `csrf-token` and `version`;
- is told nothing. No refusal, no empty state, no capability named.

**The padlock is NOT the fix.** `href="/manager"` with the active state matching
`^/manager/config` means this is the manager **landing page** - you cannot
padlock where somebody lands. So an account with `ui` and no `manage_config`
lands on a blank page **at every login**, and a blank page is indistinguishable
from a broken one. That shape cost this line a release at 0.13.13, when the
Handlers page loaded, requested nothing, populated nothing, and the suite was
green.

The fix is the page's own empty state naming the capability that opens it - the
agent's second suggestion, and the better one: *the padlock tells a reader they
cannot; the empty state tells them what to ask for.* Every control-API refusal
already names the capability that would work; this page says less than its own
API does.

**Pre-existing, live on all 14 beta sites, and NOT new in 0.14.0** - which is why
it did not block the stable cut. It is additive, but it is on the page every
manager user lands on, so it wants the most care of the four.

Two people independently concluded the Services panel did not exist because of
this - the site agent nearly filed it as missing, and the operator's words were
*"there isn't such a page AFAIK"*. That is the cost of a silent empty page.

# OUT - and why, so nobody re-opens them by accident

```datatable
columns: Item | Why not 0.14.1
widths: 6cm | X
bold: 1
tone: medium
---
[[SM871]] quote truncation in `value:` | touches the tokeniser that parses EVERY field rule on EVERY form. Medium, not low
A4's marking clause | threads a known-principal set through three sheets of shared JS that every manager page loads
[[SM873]] `store_*` kinds built at run time | needs the reasons enumerated and a 400-vs-500 semantic decision first
[[SM844]] `db:` + `\| html` double-escape | option 3 was declined at filing because it needs a marker type on every escaped value
```

**SM844's mitigation is a rollout step, not code.** `lazysite check` names the
affected files and reads front matter only - so each remaining 0.12.1 docroot can
be surveyed with the new checker **before** it is upgraded, turning a silent
post-upgrade surprise into a list. That is worth doing as the stable rollout
reaches those sites.

# Admin, which is not release content

1. **Transcribe the site agent's six register rows.** The operator has ruled that
   the agent's working directory is theirs and `docs/` is ours, so they have
   withdrawn the rows they added and handed them over verbatim. Their earlier
   report of the register being overwritten is retracted with them - the
   regeneration was working correctly and there was no defect.
2. **Correct the 0.14.0 notes on B8.** The tarball says B8 "has not been run"; it
   was walked and PASSED while the build was cutting. The statement is
   conservative rather than overclaiming, so the cut was allowed to finish, and
   main gets the correction.
3. **The register attribution problem is unsolved.** The agent's point stands: *"a
   row you paste from here is still a row transcribed by you."* They asked for
   somewhere they can write that we read - a drop file, or an inbox the register
   is built from. Small, and it is the difference between a record that names who
   walked a check and one that names me.
4. **One pre-cut step that regenerates all four generated files** - the action
   reference, the capability docs, the practice briefing, the doc index. Finding
   them one gate-failure at a time turned the 0.13.16 pre-cut into three rounds.

# Where Tier B ended up, for the record

All five walked on 0.13.16. **B4, B5, B7, B8 pass; B6 failed and is fixed in
0.14.0 ([[SM876]]).** B8's pass is the strong one - all four channel counts
recomputed independently from the Groups data and matched to the digit, group
names included, with the dormant flag appearing on holders only and clearing
when the service was switched back.

# Related

[[SM876]] (B6's fix, in 0.14.0), [[SM874]], [[SM872]],
[[feedback_a_boolean_has_four_states]], [[feedback_a_declaration_the_code_ignores]].
