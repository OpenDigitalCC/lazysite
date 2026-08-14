# Dimension 7 - Documentation - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: WARN (2026-08-14, at 0.10.8)

## Verdict

**WARN**. The largest item is closed - the feature timeline is current for the
first time in eight releases - and the compliance documentation set is
materially better than at any prior review. Two carried items remain, both
build-side and both named in the previous review's own recommendations, and one
new defect was found in this release's own documentation change.

## Findings

### F7.1 - The feature timeline is current: CLOSED

`docs/FEATURES.md` Part XIII now runs to **0.10.9**, and its closing statement
names the same version. At 0.10.8 it stopped at 0.9.14, eight releases back,
including a stable promotion.

It is now gated: `lazysite-compliance.pl` cross-references the newest release
version in FEATURES.md against the CHANGELOG's release headings - deliberately
not against any three-part number in the file, because an earlier draft of that
check reported "current" off a Perl version string.

### F7.2 - POLICY.md still cites the 2026-07-01 review (WARN, carried)

`docs/POLICY.md:34` and `:64` still point a reader at the 2026-07-01 review's
findings as work in progress. Those were resolved in July, and this is the fifth
review since.

The previous review named this alongside the FEATURES.md sweep as the two items
that would move D7 to PASS. One was done. This is the clearest single instance
of the projection finding in the overview: the remedy was identified, named, and
not scheduled.

### F7.3 - ADR 0001 still describes an arrangement it no longer has (WARN, carried)

ADR 0001 speaks of "one recorded copy" of the module-free render-path logic. The
tag carries several, each pinned by a lint that compares answers. The
engineering is sound and arguably stronger than the ADR describes; the ADR has
simply not been rewritten. Carried since 2026-07-18.

### F7.4 - The llms.txt defaults change missed a subdirectory (WARN, new)

Found by measuring the deployed service, not by reading the tree.

The change stopped bundled documentation registering for `llms.txt` so a
customer site's registry advertises the site rather than lazysite's manuals. It
worked: on the deployed host the registry went from 28 entries to 6, and bundled
docs from 26 to 2.

**The two survivors are the finding.** They are
`starter/docs/integrations/figma.md` and `starter/docs/integrations/index.md` -
the change globbed `starter/docs/*.md` and never reached the subdirectory.

This is the same failure family the project has now found six times: a pattern
that looked exhaustive and was not. It is notable that it was committed inside
the change fixing a different instance of it, and that reading the source would
not have caught it - the source says no docs pages register, and it is wrong
about two.

Remedy: extend to `starter/docs/*/`, and prefer a recursive walk to a glob.

### F7.5 - The compliance documentation set (PASS, noted)

New this release and worth recording: a dated obligations register anchored on
dates and versions, the Annex VII technical file as an index, a handover
document, and two operator templates using the pipeline's variable substitution
so an operator fills one block, validates and signs. All packaged, enforced by
`t/lint/41`, and `t/lint/44` asserts the templates substitute in both
directions.

### F7.6 - The mechanically-defended set continues to hold (PASS)

Every document defended by a mechanism is current: the generated capability map,
the access model pinned by `t/lint/36`, the manager guide pinned to the
navigation, documentation paths asserted real. The distinction the previous
review drew still separates cleanly - F7.2, F7.3 and F7.4 are all
hand-maintained.

## Evidence

- `docs/FEATURES.md` - newest timeline entry `**0.10.9**`.
- `docs/POLICY.md:34`, `:64` - the stale pointer.
- `curl https://edge.explore.lazysite.io/llms.txt` - 6 entries, 2 bundled docs.
