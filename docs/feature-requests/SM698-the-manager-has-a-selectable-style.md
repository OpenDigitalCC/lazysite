---
id: SM698
title: The manager has a selectable style, previewed before it is committed
raised: 2026-08-30
raised-by: release manager
area: manager-ui
status: partial
status-note: "PARTIAL - the three sheets are IN and selectable; the app-side class changes are not. The design side delivers one sheet switching on [data-variant] at the root; we split it into one file per style and select with `manager_style` in config. THE SPLIT IS DELIBERATE, on the release manager's decision: a future style may differ far more than these three do, and an in-page switcher carrying every style at once makes each new one a tax on all the others - it has to keep working inside a document containing its rivals. `classic` is the shipped default, so an instance that never touches the setting sees the traditional manager. The design sheet's legacy vocabulary layer styles the CURRENT markup, so the sheets deploy before the class collapses rather than after. ORIGINALLY: Ship two or three manager stylesheets and let an operator pick one in system settings, with a LINK TO THE STYLE GUIDE RENDERED IN THAT STYLE, in a modal, so the choice is seen before it is made. Current becomes `classic`; the release manager will supply `accessible` and `modern`. Later, download/upload so an operator can author their own. THE STYLE GUIDE IS WHAT MAKES THIS POSSIBLE and is also the acceptance test: a style is complete when it satisfies the guide's contract, and the preview is the guide rendered with the candidate sheet. THE DELIVERY MECHANISM IS THE CARE POINT: manager.css is code-bucket and overwritten on every upgrade, by design (SM-era fix for a stale sheet lingering) - so a chosen style must not be a file an upgrade will silently replace."
---

# The request

> add briefing to select in system settings the manager style. we can include
> 2-3 css file options, and link from there to see style guide preview, so user
> can see what each looks like in modal before committing. potential later to
> have download/upload manager style allowing user to create their own. then
> this can be actioned, with current being classic, I will provide accessible
> and modern css options.

# Why this is now possible, and was not last week

The style guide ([[SM697]] work) is what makes a second stylesheet checkable at
all. Before it, "does this style cover the manager?" had no answer short of
clicking every page - which is how the manager accumulated eight classes with no
rule on one page and fourteen more across seven others.

With the guide, the question has a mechanical answer, and it is the same one for
a shipped style and an operator's own:

**A style is complete when `t/lint/96` passes against it** - every class the
guide names has a rule. That is the acceptance test for `accessible` and
`modern` before they ship, and it is the check an upload would have to pass.

The guide is also the natural preview surface. It already shows every component
in every state on one page, which is exactly what somebody choosing a style
needs to look at. Nothing new has to be built to preview a style - point the
guide at a different sheet.

# The delivery mechanism, which is the part to get right

`manager.css` is classified **code** in `dist/config/classification.json` and
installs to `{DOCROOT}/manager/assets/manager.css`. Code-bucket means
`install.pl` **overwrites it on every upgrade**, deliberately: the old approach
left a stale manager.css behind after an upgrade and that was the fix.

So the naive implementation - let the operator replace `manager.css` - gives
them a choice that silently reverts at the next upgrade, and the symptom is "my
manager went back to how it was" with nothing to point at. Three parts, kept
apart:

| Thing | What it is | Where it lives |
| --- | --- | --- |
| The shipped styles | Engine code, several sheets | code bucket, overwritten on upgrade, as now |
| The **selection** | One name: `classic`, `accessible`, `modern` | site config - survives upgrades because it is not a file the manifest owns |
| An **uploaded** style | Operator content | a store the manifest does not own, like any other operator artefact |

The page then loads `manager-<name>.css`, or the uploaded sheet, chosen by the
setting. `classic` is the current sheet renamed, so an instance that never
touches the setting is unchanged.

# The preview, in a modal, before committing

Per the request: the setting links to the style guide rendered **in the
candidate style**, shown in a modal, so the operator sees the choice before
making it.

Two things worth deciding up front:

- **The preview must be the guide, not a sample.** A screenshot or a swatch row
  would let a style look good and still leave a component unstyled - which is
  precisely the defect this whole line of work came from.
- **An iframe, not an injected stylesheet.** Loading a candidate sheet into the
  live manager page would restyle the manager the operator is standing in,
  including the modal doing the previewing. An iframe keeps the candidate style
  inside the preview.

# Upload, later - and what it will need

Recorded now because it changes what the earlier parts should look like, not
because it should be built with them.

An uploaded stylesheet is **operator-supplied code that runs in the manager**,
and CSS is not inert:

- `background-image: url(...)` and `@import` make requests, so a stylesheet can
  report that a particular manager page was opened, and to whom, to a third
  party. That is an exfiltration channel, not a styling feature.
- `display: none` on a confirm button, or a transparent overlay, can hide or
  obscure a control the operator is about to use. A stylesheet cannot press a
  button, but it can change what a person believes they are pressing.

None of that argues against the feature; it argues for deciding the boundary
before it is built. The likely shape: refuse `@import` and external `url()` at
upload, and hold uploaded sheets to the same guide contract, so a sheet that
hides a component fails for the same reason an incomplete one does.

Worth noting that `classic` and the two the release manager supplies do not
raise this - they are engine code, reviewed like engine code. The boundary work
belongs with upload, not before it.

# What to build, in order

1. **Rename the current sheet to `classic`** and make the loader read a setting,
   with `classic` as the default. Nothing changes for anybody yet, and the
   mechanism exists.
2. **The setting in system settings**, with the preview modal pointing at the
   guide in an iframe.
3. **`accessible` and `modern`**, supplied by the release manager, each gated by
   `t/lint/96` against the guide.
4. **Download** - export the active sheet, which is the obvious starting point
   for somebody authoring their own.
5. **Upload**, with the boundary above settled first.

# Related

[[SM697]] (the style guide and its contract - this depends on it entirely),
[[SM686]] (a class with no rule renders as unstyled content: what the contract
prevents, and what a second style would otherwise reintroduce wholesale),
[[SM689]], and the site-side practice that the style guide is the contract
between the content and the design side - this applies the same rule to the
manager, with the operator in the design side's chair.

# Not started
