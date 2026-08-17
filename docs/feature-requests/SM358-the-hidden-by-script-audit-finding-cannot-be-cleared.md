---
title: "SM358 - The hidden_by_script audit finding cannot be cleared by the operator it is shown to"
subtitle: "It names the stylesheet that defines `.reveal`, not a page that uses one. No page on the instance uses it. The theme already ships the `prefers-reduced-motion` reset and the audit does not credit it. And the theme is shipped, so an edit would be overwritten - leaving 'learn to ignore the audit' as the only available response."
brand: plain
status: candidate
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
