---
id: SM920
title: "SM920: theme-activate declares two names for one argument, and discards the loser in silence"
subtitle: "Reported from a live site: theme-activate&path=odcc&theme=odcc-b answers ok:true, names the OLD theme in its response, and serves the old theme. The field diagnosis was SM911's - a parameter read but not declared. The code says otherwise: BOTH names are declared and real, `path` takes precedence, and a caller who supplies both has the more specific one dropped without being told."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, from opendigital.cc (0.14.4), reproduced twice
area: control-api
status-note: "SHIPPED (018b634f) 2026-10-01 - `path` is retired for `theme-activate` and `layout-activate`, and `theme=`/`layout=` are the only spelling. EVERY SITE IN THE MEASURED SCOPE WAS CHANGED: the two dispatch branches; both `params` entries in Lazysite::ControlApi::Actions, where the surviving name is now `required => 1`; our own Appearance page, which was a `path=` caller in three places including the deactivation call (`theme=&deactivate=1` now); the layouts briefing; the generated action reference, regenerated so it lists one parameter; and twelve test calls across t/unit/manager/10, 11, 12, 53, 56 and 98. ONE THING THE RULING DID NOT NAME AND THE BUILD FOUND: the SM247 refusal said "the theme name goes in the `path` parameter", so a caller who hit it was being sent back to the parameter that had just been retired - it names `theme` now, and t/unit/manager/53 asserts that rather than the old wording. t/unit/manager/56 WAS the test for the alias pair and now asserts the opposite for `path`: that it names nothing, and that the dispatch branch contains no `$path` fallback at all - read from the BRANCH, because the first draft of that assertion scanned the whole script with /s and failed against correct code. `layout-delete` is untouched, as the ruling says: its pair has the OPPOSITE precedence and is its own question. Four sabotages, four refusals. Original ruling follows. RULED 2026-09-30. The release manager declined all three shapes this filing offered and asked the prior question: `why do we have the option of both? is there a reason that there isnt only one way to ask for this?` There is not - checking found SM261 (96934c5d) added the specific spelling to remove SM247's trap and never retired the generic one, so the pair is residue rather than a design. RULING: retire `path` for `theme-activate` and `layout-activate`; `theme=` and `layout=` become the only spelling. Breaking for a token client that sends `path=`, and mitigated by the channel ladder - it lands on edge and has a beta and a stable gate in front of it. Precedent: SM903 retired `theme-rename` outright on 2026-09-26 with no deprecation window, and SM261 itself was a breaking rename. SCOPE MEASURED (not yet done): the two dispatch branches at lazysite-manager-api.pl:2035-2042; the two `params` entries in Lazysite::ControlApi::Actions (:458, :511); THREE call sites in the shipped manager UI at starter/manager/appearance.md:288, :315, :327 - our own Appearance page is a `path=` caller and upgrades with the engine; starter/docs/ai-briefing-layouts.md:489-490; the generated docs/reference/control-api-actions.md and capability-map.md; and eleven test calls across t/unit/manager/10, 11, 12, 56, 98. DOES NOT COVER `layout-delete`, whose pair has the OPPOSITE precedence and is named below as the open neighbour."
---

# The ruling

The release manager declined all three shapes offered below and asked the prior
question instead:

> *"why do we have the option of both? is there a reason that there isnt only one
> way to ask for this?"*

**There is not.** `git log -S` on the alias puts it at 96934c5d, SM261, *"a list
response names its contents, and activate takes the obvious parameter"* - the
specific spelling was added to remove the trap SM247 had found, and the generic
one was left reachable because leaving it cost nothing at the time. No decision
was ever taken about which wins, which is why this filing found none to cite.
The pair is residue, not a design.

**RULED 2026-09-30: retire `path` for `theme-activate` and `layout-activate`.**
`theme=` and `layout=` become the only spelling. That is shape (3) below, the one
this filing argued against on the grounds that it breaks callers in the field -
and the argument does not survive the question, because the two names never
carried different meanings for anyone to depend on.

Not built. The scope is measured in the status-note above and the work is a
release of its own, not a tail on this one.

# What the measurement added after the ruling

Three facts found while scoping it, none of which were in the report:

**The engine already contains both precedences, ten lines apart.** In the same
dispatcher, `theme-activate` and `layout-activate` let `path` win, and
`layout-delete` - `$params{layout} // $path`, added by SM911 LD2 - lets the
specific name win. A caller who learns the rule from one action has learnt the
wrong rule for the other.

**Our own manager UI is a `path=` caller**, three times, in
`starter/manager/appearance.md`. That is not an argument against the ruling; it
is the reason the ruling is cheaper than it looks, because the Appearance page
ships with the engine and is upgraded by the same tarball that removes the
parameter. The external exposure is narrower than "every token client" - it is
token clients written against `path=`, and the briefing that taught them
(`ai-briefing-layouts.md:489`) ships too.

**On `layout-activate` the retirement removes a genuine ambiguity, not just a
spelling.** That action takes `theme=` as a SEPARATE, real parameter - the
compatible theme to activate with the layout, which
`starter/docs/features/configuration/theme-publishing.md:114` documents and
`t/unit/manager/12` exercises as `path=alt&theme=shared`. So today one call
carries the layout name in the dispatcher's generic `path` and a theme name in
`theme`, and nothing on the wire says which is which. After the ruling it reads
`layout=alt&theme=shared`, where both parameters name what they are.

The deactivation call is the one to be careful with:
`appearance.md:327` posts `theme-activate&path=&deactivate=1`, an EMPTY `path`
plus a flag, and it works because `Manager::Themes:523` returns on `deactivate`
before the empty-name error at `:527`. Retiring `path` there means dropping the
parameter, not renaming it - `theme-activate&deactivate=1` - and the guard that
makes an absent name an error (SM247's fix) must keep sitting behind the flag.

# What the ruling does not cover

`layout-delete`'s pair stays as it is. SM911 LD2 added `layout=` there
deliberately and recorded *"`path` still works, so nothing that calls it today
changes"*, which was the right call for a defect about an action that appeared
unreachable. Consistency now argues it should follow these two, and that is a
question rather than a consequence - a delete is the one place where a caller
whose parameter is silently ignored is better served by a refusal than by a
rename. Raised here so it is not lost, and deliberately not decided.

# What was measured in the field

Against a site whose layout and current theme are both `odcc`, with a copy
`odcc-b` carrying a real change:

```datatable
columns: Call | Answer | Served
widths: 6.6cm | 3.4cm | X
text: 3
bold: 1
tone: medium
---
`path=odcc&theme=odcc-b` | `ok:true, theme:odcc` | `odcc` - **not what was asked for**
`layout=odcc&theme=odcc-b` | `ok:true, theme:odcc-b` | `odcc-b` - correct
`layout=odcc&theme=zz-nope` | `ok:false, "Theme not found"` | unchanged - correctly refused
```

The served stylesheet URL was read from the live page each time, so this is what
visitors got rather than what the response claimed. Reproduced on a second run.

# The cause, and it is not the one reported

The filing came in as SM911's family - a parameter the code reads and the table
does not declare, with `layout` named as the one that works. The dispatcher says
something different:

    my $name = ( length($path) && $path ne '/' ) ? $path : ( $params{theme} // '' );

`path` and `theme` are BOTH declared in `Lazysite::ControlApi::Actions`, both are
real, and **`path` wins when both are supplied**. Nothing reads `layout` in this
branch at all.

So `layout=odcc` did not work because `layout` is the true parameter. It worked
because it is NOT `path`, which left `$path` empty and allowed `$params{theme}` to
be read. Any unrecognised parameter name would have had the same effect.

This matters because the reported diagnosis leads to the wrong repair. Declaring
`layout` would document a parameter the code ignores - the very defect the report
is about - and would leave the precedence untouched.

# Why t/lint/58 passed

That lint extracts `$params{x}` per branch and compares it to the declared list,
and it is right: this branch reads `$params{theme}`, and `$path` is the
dispatcher's generic path. Both are declared. The lint checks that the NAMES
agree, and has no view on what happens when two of them arrive together.

An alias pair with a silent precedence is invisible to it, and `theme-activate` is
not necessarily the only one.

# The history makes it worse

`action_theme_activate` carries SM247's comment:

> The control API defaults `path` to '/', which this sanitiser reduces to '', so
> calling theme-activate with the name in the wrong parameter (theme= instead of
> path=) used to strip the site's theme and return ok:1.

So the inverse of this defect was found on a live site once already, and fixed by
making an empty name an error. `theme` was then added as a fallback so that spelling
would work too - and the two have coexisted since, with no statement of which wins.
Each half was reasonable; the pair is the defect.

# What it costs an operator

The whole loop looks right and changes nothing:

1. copy the live theme, because the write-lock refusal tells you to;
2. edit the copy;
3. call `theme-activate` with the parameters the table declares;
4. be told `ok:true`;
5. still be serving the old theme.

The response does name the old theme, but to someone who has just asked for
`odcc-b` and been told `ok`, `"theme":"odcc"` reads as confirmation rather than
contradiction.

# The three shapes that were offered, and why none was taken

Kept as the record of what was put up. **All three were declined** - see the
ruling at the top. They share a premise the question exposed: that two names for
one argument is a thing to be arbitrated rather than removed.

1. **REFUSE THE CONFLICT.** If both arrive and they differ, answer `ok:false`
   naming both values and which parameter to use. Nothing silently discarded, and
   a caller who sends one is unaffected. This is the "a missing parameter is named
   as missing" rule applied to a surplus one.
2. **THE SPECIFIC NAME WINS.** `theme` beats the generic `path` for
   theme-activate, `layout` beats it for layout-activate. Fixes the reported case
   and keeps single-parameter callers working, but it is still a precedence a
   caller has to know.
3. **ONE NAME ONLY**, the other refused as unknown. Cleanest contract, and it
   breaks existing callers - which on a control API with token clients in the
   field is a decision rather than a tidy-up.

(1) was what this filing recommended, on the grounds that it converts a silent
wrong action into a refusal - the direction every other repair in 0.15.1 took.
That reasoning was sound about refusals and wrong about the subject: a refusal is
the right answer to a caller who says two contradictory things, and the better
answer is an interface on which they cannot. The ruling took (3), narrowed to
these two actions and spelt as retirement rather than as "refused as unknown" -
the parameter goes, so there is nothing to refuse.

# The sweep the report asked for, re-aimed

The report suggested sweeping actions whose declared parameters differ from the
ones they read. t/lint/58 already holds that, so the sweep with something to find
is a different one: **actions that accept more than one name for one argument, and
what they do when both arrive.** `layout-activate` has the identical shape two
lines below, and `preview-grant` (filed 2026-09-28, declares `params: []` and
requires `layout`) is a third that needs reading before it is assumed to match.

Not measured here, and deliberately not claimed: how many such pairs exist. That
needed the decision first, because what counts as a defect depends on which of
the three shapes is the rule.

**The decision has now been taken, so the sweep has a definition**: an action
that declares two `params` names reaching one argument is a defect, and the
repair is to retire the generic one. `layout-delete` is a known instance held
back by the section above. `preview-grant` still needs reading. The sweep is
cheap to make mechanical, because the pairs are visible in the declarative
`params` table rather than only in the dispatcher - two entries whose names are
`path` and one other, on an action whose handler takes a single name, is the
signature. That is a lint, and it is the gate this ruling should land with, so a
fourth pair cannot arrive the way this one did.

# Related

[[SM911]] (the family the report assigned this to - a parameter read and not
declared, which this is NOT), [[SM247]] (the inverse defect on the same action),
[[SM662]], [[feedback_a_declaration_the_code_ignores]],
[[feedback_missing_parameter_named_as_missing]],
[[feedback_preview_and_apply_look_alike]].
