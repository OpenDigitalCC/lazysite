---
id: SM686
title: The capability grid ends every row with a bare question mark
raised: 2026-08-29
raised-by: release manager
area: manager-ui
status: shipped
status-note: "SHIPPED in 0.11.6. The `?` was a marker for the sentence describing what a capability grants, rendered against a class that had NO CSS RULE AT ALL - so it appeared as an unstyled character in the label text and every row read 'Manage forms ?'. Replaced with a circled `i`, styled, focusable and named to a screen reader. The missing stylesheet rule was the actual defect: the glyph was only ever meant to be a badge."
---

# What the operator saw

Every capability in the Groups grid ended with a question mark:

> Manage forms ?
> Manage data ?
> Purge ?

Reported twice. The first report was read as being about label wording - the
`Purge - destroy what no copy survives` case, which was fixed by moving the
explanation into a tooltip. The marker itself survived that fix, which is why
it came back: **the same instruction covered both, and only one half was done.**

# What it actually was

`groups.md` appends a hover marker to any capability carrying a `grants`
sentence, and nearly every capability carries one:

```js
' <span class="mg-cap-what" title="' + escHtml(grants) + '">?</span>'
```

`mg-cap-what` had no rule in `manager.css`. Not a wrong rule - no rule. So the
element rendered as an inline text node in the label's own font and size, and a
`?` in running text reads as punctuation. The page appeared to be asking a
question about each capability rather than offering to answer one.

# The fix

A circled `i`: `border-radius: 50%`, sized below the label, muted, `cursor:
help`. It also takes focus and carries an `aria-label`, because a `title`
attribute alone is mouse-only and the sentence behind it is the thing an
operator needs before granting.

The sentence itself is unchanged and still comes from `Capabilities.pm`, so the
grid, `describe_capabilities` and the generated map keep saying the same words.

# What this says about the class of bug

A marker glyph and the rule that styles it are one thing in two files, and
nothing linked them. The test added with this fix asserts both halves together -
a glyph with no rule, or a rule with no element, each fail it - because either
half alone lets the defect back in wearing the other half's clothes.

# Related

SM617 (the technical name stays on the label, which is why the marker is
separate from it), [[SM662]] (a capability's reach described in several places
at once - the same shape, in the gate rather than the grid).
