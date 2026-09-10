---
id: SM817
title: "SM817: plugins are not plugged in by anyone, and every better word is already taken"
subtitle: "The release manager is right that `plugin` misdescribes what these are - they ship with the engine and the operator act is switching, not installing. This filing first recommended keeping the word and was WRONG: the core renderer provably requires no plugin, so `extension` names the real relationship, and the file-suffix collision is spelled `ext` in code and largely absent from the identifier namespace. Recommendation: rename to extensions, alias the seven plugin-* actions born deprecated, and keep `plugin` in reserve for the day something genuinely is pluggable."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-10
raised-by: release manager
area: vocabulary
status-note: "PARTIAL. STEP 1 SHIPPED 2026-09-10: the wire takes `extension-*` and `plugin-*` alike, normalised at the single point the action is read and before the capability gate, so the two spellings cannot drift - only one exists below that line. The old spelling logs an INFO naming the new one, INFO rather than WARN because a warning on every call trains an operator to ignore the log before the removal it warns about arrives. Our own thirteen call sites moved in the same change; the generated action table explains the split. WHAT REMAINS: the plugins/ directory and conf key, the capability names, the operator-facing surface in ONE pass (a half-renamed vocabulary is worse than either name), SM222 L0, and the constrained-enablement mechanism SM798 and the audit trail both need. Scheduled as one release with SM222, staying in the 0.13 series."
---

# The observation is correct

> They aren't plugs, they come plugged in, even if switched off.

That is accurate. `plugin` carries three implications, and the engine matches
none of them: that the thing came from outside, that somebody added it, and that
the host did not know about it until it arrived. All fourteen ship in the
package, the engine declares their capabilities, and the operator's act is
switching one off - not installing one.

# Both proposed replacements are already spoken for

Checked against the tree rather than judged by ear, because a rename that
collides is worse than a word that merely misdescribes.

**`extension` already means the bit after the dot.** In the engine's own prose:
"engine-owned paths, executable extensions", "19 of 25 extensions", "a
one-extension gated `.dat`". And [[SM797]] - ruled on 2026-09-09, the same day
this was asked - is *an extension denylist for the static serve*. An Extensions
page shipping alongside an extension denylist would put two meanings of the word
in one release.

**`feature` already means the whole engine, and would not distinguish.**
`docs/FEATURES.md` is subtitled "Everything lazysite has and does", and
`docs/feature-requests/` holds 170 filings - the entire backlog vocabulary is
"feature". Worse, it fails the job: search, aliases and themes are features and
are not plugins, so "Features" cannot name the switchable subset. It would be a
broader word standing in for a narrower thing, which is how a category stops
meaning anything.

**`service` was checked and will not unify them**, which was the hypothesis this
started from and it is wrong. The service switches govern *channels* - the
manager's own labels are "Services: web AI connector (Claude.ai, ChatGPT)" and
"Services: agent and CLI access (Claude Code, Desktop, scripts)" - which is who
may reach the site and how. Plugins are subsystems that do work. Merging two
distinct ideas under one label would make the vocabulary worse, not better.

`module` collides with Perl modules, which is what `owns.deps` and
`_missing_deps` are about. `component` is [[SM492]]'s mechanism. The only
candidate with no existing use at all is `add-on` - and it means *added*, which
is the exact thing the release manager is objecting to.

**So the free words are wrong and the right words are taken.** That is the
finding, and it argues against the rename rather than for a particular winner.

# What the rename would cost

Seven published API actions carry it: `plugin-list`, `plugin-read`,
`plugin-save`, `plugin-action`, `plugin-config`, `plugin-enable`,
`plugin-disable`. Those are the contract every partner agent is written
against, so renaming means either breaking them or carrying aliases and a
deprecation - the shape [[SM786]] already established. Plus the `plugins/`
directory, two manager pages, the config files, and 568 files that mention the
word.

And the timing counts against it. [[SM809]] shipped in 0.13.10 specifically to
make the daemon findable by the word the field actually uses, after a name cost
a reporter nine steps. Churning the category word immediately afterwards
re-teaches the field something it has just learned.

**Weigh that against the evidence of harm, which is thin.** Nobody has filed
confusion about the category word. What HAS been filed - twice, in SM809 and
[[SM816]] - is a control or a component whose *own* name or label did not say
what it was. The costly naming defects here have been specific, not categorical.

# The better question underneath

The fourteen are not one category:

| Reach outside the box | Engine facilities that merely switch off |
| --- | --- |
| `pandoc`, `notify-xmpp`, `git-sync`, `form-smtp`, `payment-demo` | `audit`, `log`, `content-history`, `stats`, `data`, `briefs`, `daemon`, `bad-url-blocker`, `form-handler` |

The left column is genuinely adapter-shaped - it talks to something the operator
also has to install or configure elsewhere. The right column is the engine's own
machinery, switchable for good reasons but not "plugged in" in any sense.

**"Why is the audit log a plugin?" is a sharper question than "what should we
call plugins?"** If the operator's page separated the two, the category word
would carry much less weight and the present one would stop grating - because the
left column IS plugin-shaped, and only the right column is misdescribed.

# The recommendation

1. **Keep `plugin-*` on the wire and in the code.** The contract cost is real
   and the benefit is a word.
2. **If the operator-facing word grates, change only the label** - the manager
   page title and its prose. Two files, no contract, reversible.
3. **Neither `extensions` nor `features`**, for the collisions above.
4. **Spend the release on the split instead.** It addresses the actual
   discomfort, it is a better page for the operator, and it makes the naming
   question smaller whichever way it is eventually answered.

# Provenance

Asked by the release manager on 2026-09-10 while reviewing SM816. The word
counts, the seven API actions, the service labels and the fourteen scripts were
read from this tree; the "services would unify them" hypothesis was tested here
and abandoned.

# RECOMMENDATION REVERSED 2026-09-10, on two facts and one argument

The release manager pushed back, and the position above was wrong. Recorded
rather than quietly replaced, because the reason it was wrong is the useful part:
**it weighed a contract against "a word", and the word encodes an architectural
principle.**

## The principle, verified

> To avoid bloat, the core renderer must continue to run standalone and simply -
> everything else is an extension of this.

That is checkable, and it is true. `lazysite-processor.pl` requires nothing from
`plugins/` - not one load - and mentions the word ten times in the whole file,
once in a comment about where two subs were lifted for a test. **The renderer
runs standalone today.** So "extends the core renderer" is not a metaphor for
these things, it is their actual relationship, and a name that says so makes the
principle visible every time anybody reads the page. A name that says
"pluggable" instead describes a mechanism the engine does not have.

## The collision is smaller than the count suggested

The earlier objection - that `extension` means the bit after the dot - measured
the wrong thing. In code the file-suffix sense is spelled `ext`: 240 identifier
occurrences against 156 uses of the whole word, and 47 of those 156 are in
comments. **The identifier namespace is effectively free**, and the remaining
overlap is prose, where "file extension" or "suffix" disambiguates at no cost.
The two senses also live in different places - paths and static serving on one
side, subsystems and the manager on the other - so they rarely meet in a
sentence.

## And the timing argument is right

> Now is the least hard time we will ever have to change this.

Seven API actions and fourteen scripts is the smallest this gets. Every release
that adds a fifteenth makes it dearer, and nothing about the cost curve bends the
other way.

## One thing this BUYS, which the first pass missed

If third-party authoring ever becomes feasible - a subsystem written elsewhere
and dropped in - **`plugin` is the correct word for that, and it would then be
free.** Spending it now on things that are bundled burns the accurate name for
the thing that would actually be pluggable. Renaming the bundled set to
extensions keeps `plugin` in reserve for the case that would earn it.

# The word, and the test it passes

The release manager's own test is the right one: **does the word imply the thing
can be added or removed independently?**

| Word | Implies removable? | Verdict |
| --- | --- | --- |
| `plugin` | Yes - that is its whole image | Wrong now; correct later if drop-in authoring arrives |
| `module` | Yes - a separable unit | Same defect, as the release manager said |
| `add-on` | Yes, most strongly | Worst of the three |
| **`extension`** | **No - it names a relationship, not a package** | **Recommended** |
| `facility` | No. Precise, almost no collision (14 files) | Viable; reads institutional |
| `subsystem` | No. Accurate | Viable; too cold for an operator page |
| `built-in` | No, and it says "comes plugged in" exactly | Accurate, awkward as a plural noun |

`facility` and `subsystem` are the honest runners-up and both are duller.
`extension` is recommended because it is the only candidate that states the
architecture rather than describing the shipping arrangement.

# What "services" becomes

Left alone. A service is a **channel** - "Services: web AI connector",
"Services: agent and CLI access" - which is who may reach the site and how. An
extension is a **subsystem that does work**. Both are non-core, so both extend
the renderer in the loose sense, but collapsing them would lose a distinction the
manager already draws usefully. One-for-one: plugin becomes extension, service
stays service.

# How to land it

The [[SM786]] shape, which is already the house pattern for a vocabulary change:

1. **`extension-*` actions added**, answering identically to their `plugin-*`
   twins. `plugin-list`, `plugin-read`, `plugin-save`, `plugin-action`,
   `plugin-config`, `plugin-enable`, `plugin-disable` keep working and are **born
   deprecated** - documented as the old spelling from the day the new one ships.
2. **The loader accepts `extensions/` and `plugins/`**, preferring the new name,
   so a site's own tree does not have to move on the same day the engine does.
3. **The operator-facing surface moves in one release** - page title, prose,
   nav, the practice document - because a half-renamed vocabulary is worse than
   either name.
4. **A lint pins the pair**, so an action added to one spelling and not the other
   fails rather than drifting - the same guard [[SM773]] uses for the parameter
   table.
5. **The split from the section above still stands**, and is now easier: the five
   that reach outside the box (`pandoc`, `notify-xmpp`, `git-sync`, `form-smtp`,
   `payment-demo`) are the ones a future drop-in mechanism would serve first.

Not started. This is a release's worth of care and it needs scheduling rather
than squeezing in beside a cut.

# `component` weighed, and why `extension` still wins

The release manager put `component` forward alongside `extension`, and rejected
`subsystem` on a spatial reading worth quoting because it is the sharpest test in
this filing:

> subsystem feels like it's inside or under, rather than to the side - a
> sidesystem would work, if it were a word.

That test decides it, and it decides against `component` too.

- **`subsystem` is UNDER.** Agreed. The prefix says so.
- **`component` is WITHIN.** A component is a constituent part of the thing it
  belongs to - more inside than a subsystem, not beside it. On the release
  manager's own test it fails harder than the word they rejected.
- **`extension` is OUTWARD.** A house extension is built onto the side of the
  house. It is the same house, it shares the foundations and the front door, it
  was not delivered on a lorry - and it is unmistakably *to the side*.
  **"Sidesystem" is a word, and it is `extension`.**

`component` also collides in the surface that matters most. The manager style
guide IS the component catalogue - "Every component", "style everything named",
"the guide has to show every component" - and [[SM806]]'s defect was borrowing
`mg-perms-*`, "the permissions editor's own components", as generic layout. A
Components page listing `audit` and `daemon`, shipping beside a guide that
enumerates every component and means CSS, puts two meanings of the word on the
same screen for the same reader.

`extension`'s collision is with file suffixes, which live in paths and static
serving - a different part of the engine, read by a different person, and spelled
`ext` in code.

So: **`extension`**, and the spatial argument is the one to put in the
documentation, because it explains the architecture in one image. Core renders.
Everything else is built onto the side of it.

# SCHEDULED 2026-09-10: one release, with SM222

The release manager has ruled that the rename and [[SM222]]'s truly-off work land
in **one release together**, rather than the rename alone or the lifecycle first.

That is the right pairing and the reason is the files: both follow from the same
principle - the core renders, everything else is built onto the side of it - and
both touch the same set. SM222's L0 moves the access-log write out of the core
renderer and introduces the registry a disabled unit is absent from; this renames
the things in that registry. Doing them in one pass means the registry is built
under its final name, and the operator surface changes once rather than twice.

Sequence within the release, so it is not a wide simultaneous edit - which
[[SM726]] and [[SM728]] both record the cost of:

1. `extension-*` actions added beside the seven `plugin-*`, which are kept and
   born deprecated. Lint pins the pair.
2. The registry (SM222 L0), built under the new name, with the access-log write
   moved behind it and a test per member asserting **no output** when disabled.
3. The operator surface - page title, prose, nav, practice document - in one go,
   because a half-renamed vocabulary is worse than either name.
4. The loader accepting `extensions/` and `plugins/`, so a site's own tree need
   not move on the same day the engine does.

[[SM823]]'s ingestion work follows this, not the reverse, so it is named
correctly on arrival - and the taxonomy it lands into is extensions for the
bundled units, plugins for things authored elsewhere and dropped in.
# Version, ruled 2026-09-10: it stays in the 0.13 series

Not 0.14.0. **Promotion is expensive**, so the campaign continues as 0.13.x edge
runs and promotes once - which means a structural change rides the series rather
than opening a new one. Which patch carries it is undecided until the release
manager has reviewed the backlog.

That overrules the recommendation to bump the minor. The reasoning is worth
keeping because it is about the release process rather than about semantics: a
minor bump would say the shape changed, and it would also imply a promotion
boundary that is not being taken. The tag list showing less than the architecture
did is the accepted cost.

# THE BATCH, assembled 2026-09-10

The release manager asked for other candidates for the extensions batch, and for
[[SM798]] to be added to it. Searched rather than guessed, and the useful result
is that there is **no pile of hidden extension-shaped work** - the batch is what is
already named, plus one mechanism that turns out to serve three filings at once.

**What is in it**

1. **[[SM817]]** - `extension-*` actions beside the seven `plugin-*`, born
   deprecated; the loader accepting `extensions/` and `plugins/`; the operator
   surface moved in one pass; a lint pinning the pair.
2. **[[SM222]] L0** - core calls through a registry a disabled unit is absent
   from, and the first-party access-log write moves out of the renderer behind it.
   Plus a lint that core does not reach into an extension's file directly, which
   is the `_stats_export` shape.
3. **[[SM222]]'s audit ruling** - the trail stays switchable, the disable and
   re-enable are both recorded with the actor, and a separate group governs the
   act.
4. **Content history**, which SM222 notes deserves the same treatment as audit:
   a site that turns it off and finds a page's past gone has lost something the
   switch implied it was only hiding.
5. **[[SM798]]** - see below, and it needs the same mechanism as 3.

**THE MECHANISM THAT SERVES THREE OF THEM.** SM798's recorded answer was **no**:
a rate limiter must not be disableable, so making it an extension is wrong if
extension means switchable. Adding it to this batch resolves that rather than
overruling it, because the batch has to invent the missing idea anyway -
**an extension whose enablement is constrained**:

- the **audit trail**, switchable but only by a separate grant, and recording the
  switch;
- **content history**, the same;
- the **login rate limiter**, arguably not switchable at all.

Three filings asking for the same thing from different directions. If "extension"
means only "on or off by anyone with `manage_config`", none of them can be one. If
enablement can carry a constraint, all three can, and the rate limiter's objection
disappears - it becomes an extension that reports itself and cannot be turned off,
which is what it should be.

**What is NOT in it, having looked**

- Conf-gated optional behaviour in the core renderer is just the service
  killswitches - webdav, mcp, oauth, control api, token exchange - which are
  SM222's services and already in scope, plus two size limits, the CSP, and
  SM786's new `db_render_raw`. No hidden extension candidates.
- **The discoverability registries** - sitemap, `llms.txt`, `robots.txt` - are
  generated in the core processor and referenced from eight surfaces. They are
  extension-shaped in principle and too deeply core to move as part of this;
  worth knowing because [[SM824]] and [[SM825]] join that family.
- **[[SM824]] is the registry's first real consumer** and should follow the batch,
  not join it. Building L0 for the access log proves the registry can stop work
  happening; building it for JSON-LD proves it can make work happen, which is the
  harder half and the one a later extension will use.
- **[[SM823]]** (ingestion) follows, so it is named correctly on arrival.

# STEP 1 BUILT 2026-09-10: the name, aliased at one point

`extension-*` is the name. `plugin-*` still works and says it is the old one.

**Normalised where the action is read**, in `lazysite-manager-api.pl`, rather
than by declaring every verb twice. That choice is the whole of the design: the
risk in an alias is two declarations drifting apart, and this codebase has a
filing for each time that was tried - [[SM666]], SEC-2026-07 F3, [[SM662]]. Below
the normaliser only one spelling exists, so they cannot drift, and a verb added
next year gets its alias for free.

It runs **before the capability gate**, because a new-spelling call would
otherwise be refused as an unknown action before anything looked at it. There is
an assertion for that ordering, not just for the substitution.

**The deprecation notice is INFO, not WARN**, and that is deliberate enough to be
tested: the old name still works and is correct today, and a warning on every
call trains an operator to ignore the log before the removal it warns about ever
arrives. "Make it louder" is the obvious later edit, so the test says why not.

**Our own pages moved in the same change** - thirteen call sites across
`plugins.md`, `stats.md` and `plugin-config.md`. Leaving them on the old name
would have fired the notice on every manager page load, which is exactly how a
deprecation notice becomes furniture. Only `action=` values were touched: the
page name `plugin-config`, and the classes and ids `plugin-modal`,
`plugin-registry`, `plugin-status`, share the prefix and are not actions - 26
such occurrences were deliberately left alone.

**The published table says so through its generator, not by hand.** The first
attempt edited `docs/reference/control-api-actions.md` directly and
`t/tools/26` refused it: that file is generated by
`tools/gen-capability-docs.pl` from `lib/Lazysite/ControlApi/Actions.pm`, and
`t/lint/58` re-extracts it from the dispatcher and fails on any difference. The
note now lives in the generator, which is the only way it survives the next
regeneration - and the note is honest about the split: the names in the table
are the internal ones, which have not moved, while the wire accepts both.

## What is NOT done, and is the rest of the batch

- The `plugins/` directory, the `plugins:` conf key, the capability names and the
  internal vocabulary: untouched. Only the wire name has moved.
- The operator-facing surface - page titles, nav, prose, the practice document -
  is a single pass and has not been made, because a half-renamed vocabulary is
  worse than either name.
- [[SM222]]'s L0 registry, which is the other half of the batch and the thing
  [[SM824]] then consumes.
- The **constrained-enablement** mechanism that [[SM798]], the audit trail and
  content history all need.

# The capability question, answered 2026-09-10

The release manager asked whether each extension gets its own capability, packaged
behind a system-settings group. **Both halves of that mechanism already exist**,
which makes this smaller than it sounds.

**Per-extension capabilities**: the `owns` block already carries a `capabilities`
list, and four of the fourteen use it - `daemon` (`run_jobs`), `data`
(`manage_data`), `briefs` (`manage_briefs`) and `pandoc`. The other ten declare
none, because nothing about them is separately gated today. So the shape is
there; it is a question of which units should claim one.

**The system-settings group is `cap-services`**, one of six shipped `cap-*`
bundles (content, design, data, site, services, people). Its description is
almost exactly the question: "The WebDAV, MCP, OAuth, control-API and
token-exchange switches. Decides whether the remote surfaces answer at all, for
everyone already connected." It carries `manage_services`.

**So the recommendation is:**

- **Turning an extension on or off** is `manage_services`, in `cap-services`.
  That is what the bundle is already for, and adding a seventh bundle for the
  same authority would split one idea in two.
- **Except where the constraint is the point.** The audit trail's switch is not
  the same authority as turning MCP on - it is the authority to stop recording
  what an operator does - so it wants its own capability rather than sharing
  `manage_services`. That is the [[SM798]] constrained-enablement mechanism, and
  it is the ONLY reason to add a capability rather than reuse one.
- **A unit's own actions** keep declaring their own capability through `owns`
  where they need one, exactly as `data` and `briefs` do now. Switching the unit
  and using it are different grants and should stay so.
