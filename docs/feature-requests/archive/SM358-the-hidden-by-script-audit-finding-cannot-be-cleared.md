---
title: "SM358 - The hidden_by_script audit finding cannot be cleared by the operator it is shown to"
subtitle: "It names the stylesheet that defines `.reveal`, not a page that uses one. No page on the instance uses it. The theme already ships the `prefers-reduced-motion` reset and the audit does not credit it. And the theme is shipped, so an edit would be overwritten - leaving 'learn to ignore the audit' as the only available response."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17, and the filing was PARTLY DECLINED on the strength of what it asked for. Adopted: the finding now requires a USE. audit_site extracts the classes whose rules do the hiding, then asks whether anything on this site puts one on the page - a page's own content or a LAYOUT TEMPLATE - and reports nothing when nothing does. The finding names the class and the page (or the layout), so an operator has somewhere to go instead of a stylesheet they cannot edit. DECLINED: crediting a prefers-reduced-motion reset, or reporting it as mitigating. That rule reaches only visitors who asked for reduced motion, and reading it as a neutraliser is exactly what caused the SM250 incident - the code and t/unit/mcp/17 have both said so since, and sabotaging it makes that test fail, so the guard is real rather than commentary. Narrowing to real uses makes the finding clearable without weakening a check that exists because a live site lost every section below the fold. THE LAYOUT HALF MATTERS: SM250 was a layout emitting the class on every section while the hero sat outside the pattern, so a check reading page content alone would have missed the case it was built for. Six existing fixtures were implicitly assuming a use that no page made and the check never looked for; they now state it. PARTIAL after field validation 2026-08-18. `classes` and `used_by` both work and are useful, and the finding is NOT silent on edge - `used_by` names `layout:lumen` where no rendered page carries the class. The cause is one level in from where I looked: both `reveal` references in layout.tt are JAVASCRIPT (querySelectorAll, plus a no-IntersectionObserver fallback that reveals everything), but four of the layout's six COMPONENTS apply the class in markup, and my glob reads the whole layout directory including components. So the check fires on a component that COULD apply the class rather than on a page that does - which is the mechanism-versus-use distinction this filing is about, reproduced one layer down by the fix for it. Two things to do: name the component rather than the layout, so the operator is sent somewhere real; and decide whether a component nothing renders counts as a use. Keeping it in proportion, the site agent's own reading is right - the check is well aimed, and a section-driven page built from those four components WOULD have content at opacity 0 for a visitor without JavaScript. Only the silence condition is unmet. FOLLOW-UP 2026-08-18: used_by now names the TEMPLATE that applies the class rather than the layout containing it - the field instance had four of six components implicated and two innocent, so layout:lumen was true and sent an operator to six files. The site agent then strengthened the load-bearing claim from three pages to all 26 on the instance, cache-busted: 0 of 26 render an element carrying the class. STILL OPEN, and it is a decision rather than an implementation: should an unrendered component count as a use? Their view, argued rather than asserted, is no - the finding cannot be cleared by anything a site owner can do, since the components are in a shipped layout and an edit is overwritten on reinstall, so a permanent entry beside acl_keys_matching_nothing (which reports 4 real problems there) spends attention it has not earned. The case the other way is real and they wrote it: a component in the layout is a loaded gun, and the moment a page uses `features` the content goes to opacity 0 with NO new warning, because the finding was already sitting there. If that case matters it wants a different report - a capability note, or a warning when a page first uses such a component - both of which tell the operator something at a moment they can act on. CLOSED 2026-08-18. The open question - should an unrendered component count as a use - turned out to rest on a false premise: I had framed the alternatives as warn-at-first-use or a capability note, both compensating for a check that could not tell. It CAN tell, and cheaply. A page invokes a component two ways, both visible in the source audit_site already walks: a `::: name` fence matching components/name.tt, and a `sections:` block in front matter (D035 phase 3). The audit now collects those and a component counts only when a page invokes it. So the loaded-gun case is answered rather than dropped - the finding appears the moment a page starts using the component, which is the moment an operator can act on it - and no second warning surface was needed. The layout's own template still counts unconditionally, since it renders on every page. Both directions sabotage-verified: removing the invocation test makes the silent case fire, and removing the fence collection makes the speaking case go quiet."
---

# SM358 - a control whose finding nobody can act on

## What was measured

edge 0.10.12, `audit_site` over the whole instance:

```
hidden_by_script: [{ theme: "lumen/lumen",
                     file: "/lazysite/layouts/lumen/themes/lumen/assets/main.css" }]
```

The pattern it found, line 123 of that file:

```css
.reveal { opacity: 0; transform: translateY(26px); transition: opacity .7s var(--ease), transform .7s var(--ease); }
```

Then, from outside:

```datatable
columns: Question | Answer
widths: 7.2cm | X
bold: 1
tone: medium
---
How many pages carry `class="... reveal ..."`? | **Zero** - homepage, four docs pages, contact page
Does the theme mitigate it? | Yes - line 136, `@media (prefers-reduced-motion: reduce) { .reveal { opacity: 1; transform: none; } }`
Is there a `<noscript>` fallback? | No
Can the operator edit the file? | It is a **shipped** theme; an edit is overwritten on reinstall
```

## Why this is a defect in the control, not in the theme

The risk `hidden_by_script` exists to catch is real and this instance's own
runbook records it costing four wasted checks: *"a theme can carry
`.rv{opacity:0}` revealed only by script. Four successive checks of a hero
looked correct while every section beneath it was invisible."* The check
should exist.

What it reports is not that.

**It flags the definition, not the use.** A stylesheet that defines a
reveal class is a capability. A page that carries the class is an instance.
The finding names the first, so an operator cannot tell whether any of
their content is affected - and on this instance none of it is.

**It does not credit the mitigation that is in the same file.** Thirteen
lines below the pattern, the theme resets `.reveal` to `opacity: 1` under
`prefers-reduced-motion`. That is the correct protection for the audience
most likely to be harmed by motion-gated content, and the audit reports the
theme as though it were absent.

**Nothing the operator can do resolves it.** The file belongs to a shipped
theme. Editing it is both outside what a site owner owns and futile,
because the next install overwrites it. There is no configuration to set
and no content to change.

**So the only available response is to stop reading the audit.** That is
the actual cost, and it is not small. The same `audit_site` call on this
instance also reports **four ACL keys matching nothing** - access rules
that protect no file, which is precisely the residue an operator most needs
told about. A permanent unclearable entry sitting beside those trains the
reader past them.

This project has spent a week removing controls that report without
meaning it - [[SM327]] on a tolerance that permits anything, [[SM340]] on a
cache never read, [[SM354]] on commit refs naming commits that do not
exist. This is the same shape aimed at the operator rather than at the
code: a check that produces output nobody can act on is indistinguishable,
in its effect on behaviour, from a check that produces nothing.

## The fix

Report **pages**, not stylesheets. A finding should name the page whose
rendered output carries a script-revealed class, the class, and the theme
that defines it - so the operator sees content at risk rather than a
mechanism that exists.

Then treat a `prefers-reduced-motion` reset as satisfying the check, or at
minimum report it alongside so the reader can weigh it. A theme that
defines a reveal mechanism *and* resets it for reduced-motion users has
done the work; saying so is the difference between a finding and a warning
about a feature.

If a theme-level signal is wanted regardless, it belongs somewhere other
than a findings list an operator is expected to clear - a capability note,
not a defect.

## Verification

- A page carrying a script-revealed class is reported, naming the page.
- An instance where no page uses the class produces **no**
  `hidden_by_script` finding, even with a theme that defines one.
- A theme resetting the class under `prefers-reduced-motion` either
  satisfies the check or is reported as mitigated.
- The [[SM213]]-era case still fires: a hero visible while every section
  beneath it is `opacity: 0` and script-revealed is still found.
- No `audit_site` finding is reachable only by editing a shipped theme.

## Related

[[SM327]] (a tolerance that permits anything - a control reporting without
meaning it), [[SM340]] (a cache never read), [[SM354]] (commit refs naming
commits that do not exist), and
`inbox/four-surface-residual-observations-2026-08-17.md`, the pass this came
from.
