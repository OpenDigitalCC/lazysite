---
title: "SM263 - The docs-drift items that need judgement, not a lint"
subtitle: "The ten findings SM254 could not close mechanically: feature descriptions that no longer match the shipped model, statements that are true but read wrong, the site-package warts, and two behaviour inconsistencies."
brand: plain
status: partial
status-note: "PARTIAL 2026-08-09: the operator decided all four open questions. THREE ARE DONE (SM179 implementation note; site_apply adopt_identity now reachable from MCP and the CLI; the package-download question recorded as deliberate). The FOURTH was withdrawn - the channel-default row was WRONG: a build channel and a site update_channel answer different questions and both defaults are correct, so there was nothing to change. Two audit rows turned out to be overstated on inspection, which is worth knowing about the rest of the list. Still open: the remaining feature-description rows, the three true-but-reads-wrong rows, and the /lazysite-assets mirror-on-apply gap (confirm before working it). Split out of SM254 on 2026-08-08 at the operator's direction: SM254 shipped the lint and the four mechanically-checkable corrections, and carrying the rest as a 'partial' would force a later reader to pick through the doc working out what was and was not done. Two clean records instead. The theme-name collision question was DECIDED 2026-08-08 (both surfaces refuse) and is recorded below ready to build; everything else still needs the work."
---

# SM263 - the docs-drift items that need judgement

## Why this is separate

SM254 shipped `t/lint/27-docs-reference-real-paths.t` and corrected the four
findings a machine can verify. The remaining ten are judgement calls: they need
someone to read the code, decide what is actually true, and write it down. No
lint will catch them, and their real defence is that a claim gets re-validated
when the feature next changes.

## Statements that are wrong

| Claim | Reality |
|---|---|
| Preinstall snapshot attributed to `install.pl` | It lives in `install-hestia` |
| `FEATURES.md` quotes `Lazysite::Git`'s `@EXCLUDE` list | The real list is longer - the shipped one has 15 entries including `/lazysite/aliases.json`, `/lazysite/git/` and `.install-state*` |
| `FEATURES.md` describes SM155 delegation | The shipped model is SM165 domain-derived scopes |
| SM179 P8 chrome i18n marked deferred | It shipped |
| SM179 spec names a `lang_source` front-matter flag | No such flag exists - the term appears only in the spec and in these filings |
| SM140 analytics field list | Predates the implementation |

The SM179 rows are worth separating from the rest: they are a **spec** describing
what was intended, not a guide describing what exists. Correcting a spec after
the fact loses the record of what was planned.

**DONE 2026-08-09**, by the operator's decision: SM179 gains an "As built"
section at the top naming what shipped (P8 chrome i18n did, despite being
described as deferred) and what never existed (`lang_source`, which appears
nowhere in the engine - the shipped model derives language from `lang` and
membership from `lang_group`, with no designated source). The original text is
untouched, so a later reader asking "why not `lang_source`?" still has the design
to read.

## Statements that are true but read wrong

| Claim | The misreading |
|---|---|
| SM133 static fallback wording | Can be read as doing SSI; it serves `.html` only |
| `::: include` described per the P4 claim | The shipped version is content-root-confined, i.e. stricter than described |
| SM120 source comment calls the per-page `theme:` pin "preview-only" | `FEATURES.md` and the code treat it as a general per-page override |

A wrong-but-plausible statement costs more than an absent one. SM242 was exactly
this failure: "re-activate to rebuild the mirror" was correct for one site and
damaging for another, and the reader had no way to tell which they were.

The SM120 one is cheap and adjacent to the existing retired-terms lint
(`t/lint/08-retired-terms.t`) - adding "preview-only" to that list costs a line
and stops the term coming back.

## Behaviour worth a decision

### Theme-name collision - DECIDED 2026-08-08: both refuse

A theme upload installs under a date-prefixed name; `create_theme` (SM205)
refuses. An agent cannot predict which it will get.

**Decision: make upload refuse too.** One rule, predictable from either surface,
and no theme ever appears under a name nobody chose - which is how an operator
ends up with entries they cannot account for. The refusal names the existing
theme and says what to do:

> A theme named 'house' already exists. Choose another name, or delete it first.

The cost is real and accepted: an upload workflow that relied on auto-renaming
now has to choose a name up front.

Related: SM262 gives an agent the ability to delete a theme it created, which
makes "delete it first" an action an agent can actually take rather than an
instruction to fetch a human.

### Packaged-install channel default - NOT a defect (corrected 2026-08-09)

The original audit row read "packaged install defaults its registry to channel
`edge` while the seeded conf says `stable` - two defaults for one question,
disagreeing." **That framing is wrong, and it was carried into this filing and
then into the decision put to the operator.** Recording the correction here
because the wrong version was believed for two releases.

The two values answer DIFFERENT questions, and both defaults are right:

- `build-manifest.pl --channel` declares what a build **is** - its maturity.
  Defaulting to `edge` is correct: an uncertified build is edge until somebody
  certifies it.
- `update_channel` in the seeded conf declares the **minimum a site accepts**.
  Defaulting to `stable` is correct: a fresh site should take only certified
  releases.

They are the two ends of one ladder, compared by `channel_refuses` in
`install.pl`:

```perl
return $CHANNEL_RANK{$release_channel} < $CHANNEL_RANK{$site_channel} ? 1 : 0;
```

Making the build side default to `stable` would label every uncertified build as
certified and let untested code install on production sites - the exact opposite
of what a stable default is chosen for.

**The only real interaction** is that a locally built deb (channel `edge`) is
refused by a freshly seeded site (`stable`). That is the ladder working, not a
fault. Released stable debs are cut from `release.sh --final` trees with
`channel: stable`, so real installs are unaffected. Worth knowing when a
dev-built deb appears to install and change nothing.

Nothing to change.

## Site-package warts

### site_apply identity - DONE 2026-08-09, and the row was overstated

The audit row said `apply` "carries the source's `site_url`/`site_name` onto the
target (SM193 fixed the default on the control-API path, but the MCP and CLI
paths still lack `adopt_identity`)". The second half is true; the first is not,
and the two together read as a live defect that did not exist.

SM193 set the default in `SitePackage::apply_and_configure`, which is the single
place all three channels call. MCP and the CLI therefore already got the SAFE
behaviour by inheritance - the target keeps its own identity. What they lacked
was any way to **opt in** to the other behaviour.

Both now have it: `adopt_identity` on the MCP tool, `--adopt-source-identity` on
the CLI. The default is unchanged everywhere and remains "keep the target's
identity", which is right for the common case of migrating a package onto a new
domain; adopting the source's is right when cloning a site as-is to hand over.

`t/unit/manager/58` pins that the rule lives in ONE place and that each channel
can reach it, including that the CLI registers its flag AS a flag - a hand-rolled
parser that treats a flag as a value option silently swallows the next argument.

### Token clients cannot download packages - DECIDED: deliberate

Settled 2026-08-09 so it stops being re-asked. WebDAV is the file channel for a
token client; the control API and MCP are for structured actions, and an action
API is the wrong shape for a byte stream. Recorded as the reason in
`t/lint/23`'s `%API_ONLY` entry rather than left as "undecided".

### The /lazysite-assets mirror on apply - still open

The report says `apply` installs a layout without creating the mirror, the same
family as SM241. **Confirm before working on it**: SM193's mirror-on-apply may
already cover this, and the check is minutes rather than the fix being hours.

## Verification## Verification

- Every row above is either corrected, or recorded as a deliberate decision with
  its reasoning.
- The SM179 spec keeps its original text and gains an implementation note.
- "preview-only" is in the retired-terms lint.
- The channel default is the same in both places.
- The site-package mirror gap is confirmed or disproved before it is worked on.

## Not in scope

- The dead-path lint and the four corrections, which are SM254 and shipped.
- The public lazysite.io site, already corrected - it is what produced this list.
