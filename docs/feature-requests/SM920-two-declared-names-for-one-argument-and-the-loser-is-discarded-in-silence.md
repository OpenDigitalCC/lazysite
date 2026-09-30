---
id: SM920
title: "SM920: theme-activate declares two names for one argument, and discards the loser in silence"
subtitle: "Reported from a live site: theme-activate&path=odcc&theme=odcc-b answers ok:true, names the OLD theme in its response, and serves the old theme. The field diagnosis was SM911's - a parameter read but not declared. The code says otherwise: BOTH names are declared and real, `path` takes precedence, and a caller who supplies both has the more specific one dropped without being told."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, from opendigital.cc (0.14.4), reproduced twice
area: control-api
---

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

# What wants deciding

Three shapes, and they are not equivalent:

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

(1) is what this filing recommends: it converts a silent wrong action into a
refusal, which is the direction every other repair this release took.

# The sweep the report asked for, re-aimed

The report suggested sweeping actions whose declared parameters differ from the
ones they read. t/lint/58 already holds that, so the sweep with something to find
is a different one: **actions that accept more than one name for one argument, and
what they do when both arrive.** `layout-activate` has the identical shape two
lines below, and `preview-grant` (filed 2026-09-28, declares `params: []` and
requires `layout`) is a third that needs reading before it is assumed to match.

Not measured here, and deliberately not claimed: how many such pairs exist. That
needs the decision above first, because what counts as a defect depends on which
of the three shapes is the rule.

# Related

[[SM911]] (the family the report assigned this to - a parameter read and not
declared, which this is NOT), [[SM247]] (the inverse defect on the same action),
[[SM662]], [[feedback_a_declaration_the_code_ignores]],
[[feedback_missing_parameter_named_as_missing]],
[[feedback_preview_and_apply_look_alike]].
