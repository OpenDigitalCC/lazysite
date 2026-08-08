---
title: "SM263 - The docs-drift items that need judgement, not a lint"
subtitle: "The ten findings SM254 could not close mechanically: feature descriptions that no longer match the shipped model, statements that are true but read wrong, the site-package warts, and two behaviour inconsistencies."
brand: plain
status: candidate
status-note: "Split out of SM254 on 2026-08-08 at the operator's direction: SM254 shipped the lint and the four mechanically-checkable corrections, and carrying the rest as a 'partial' would force a later reader to pick through the doc working out what was and was not done. Two clean records instead. The theme-name collision question was DECIDED 2026-08-08 (both surfaces refuse) and is recorded below ready to build; everything else still needs the work."
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
the fact loses the record of what was planned. The better repair is an
implementation note at the top saying which parts shipped and which were dropped,
leaving the original text intact.

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

### Packaged-install channel default - still open

The packaged install defaults its registry to channel `edge` while the seeded
`lazysite.conf` says `stable`. Two defaults for one question, disagreeing.

No decision recorded yet. The safe reading is that a packaged install should
default to `stable` - a fresh install landing on `edge` opts a site into
pre-release code it never asked for, and the channel ladder means the mistake is
invisible until an edge build changes something. Whichever is chosen, they must
not differ.

## Site-package warts, still present

From the providers migration of 2026-07-24:

- token clients cannot download site packages;
- `apply` carries the source's `site_url` / `site_name` onto the target. SM193
  fixed the default on the control-API path, but the MCP and CLI paths still lack
  `adopt_identity`;
- `apply` installs the layout without creating the `/lazysite-assets` mirror.

That last is the same family as SM241, which fixed `domain-set`. Worth
establishing first whether SM193's mirror-on-apply covers it or whether a gap
remains - the report says it does not, and that is a five-minute check before any
work starts.

## Verification

- Every row above is either corrected, or recorded as a deliberate decision with
  its reasoning.
- The SM179 spec keeps its original text and gains an implementation note.
- "preview-only" is in the retired-terms lint.
- The channel default is the same in both places.
- The site-package mirror gap is confirmed or disproved before it is worked on.

## Not in scope

- The dead-path lint and the four corrections, which are SM254 and shipped.
- The public lazysite.io site, already corrected - it is what produced this list.
