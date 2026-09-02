---
title: "The manager's behaviour rules: scope and rulesets"
subtitle: "An inventory of every rule the manager already obeys - colour semantics, vocabulary, component choice, interaction, presentation, input - with where each one lives and whether anything holds it. A scoping document: it describes what exists, and does not propose changes."
brand: plain
standard-margins: true
---

# Why this exists

Rules have accumulated in three places - lints that enforce them, the style
guide that states them, and comments and filings that merely record them. Nobody
has ever seen them in one list, so it is not known which are held and which are
only remembered.

**The end this serves**: semantic descriptions of controllable behaviours, so a
rule can be defined once and applied. That needs the inventory first.

# The distinction that runs through all of it

**A rule has a semantic statement and, if it is lucky, a mechanical proxy.**

> *steel confirms, copper changes, red destroys*

That is the semantic statement for button colour. `t/lint/101` enforces a
mechanical proxy for part of it - a page names colours with tokens, never
literals - so **the colour can change and the commonality survives**, which is
the property wanted. But nothing checks that a destructive action actually
*uses* the destroying modifier. The semantic half is unheld.

**Every rule below is classified this way:**

ENFORCED
: a lint fails when it is broken. It cannot drift.

STATED
: written in the style guide, which is shipped and read, but nothing checks it.
  It drifts silently and is rediscovered by a person.

IMPLICIT
: recorded only in a code comment or a filing. It drifts and is rediscovered by
  repeating the mistake.

# A. Colour and emphasis semantics

| Rule | Where | Held? |
| --- | --- | --- |
| Colours are named with tokens, never literals | `t/lint/101` | **ENFORCED** |
| steel confirms, copper changes, red destroys | style guide, SM-DS1 | STATED |
| Copy is retrieval and carries its own colour | style guide, MR-97 | STATED |
| A destructive action must ALSO be confirmed - the colour is a warning, not the guard | style guide | STATED |
| `mg-note`: info = worth knowing, warn = will not work yet, danger = will lose something | style guide, SM-DS1 | STATED |
| A warning bar must read as one - quiet tints vanish at full width | CSS comment, MR-16 | IMPLICIT |
| The three sheets may differ in look, never in which modifier means what | nowhere | IMPLICIT |

**This family is where the user's framing bites hardest.** The colour is an
implementation detail; the mapping from *kind of action* to *emphasis* is the
rule. Only the token discipline is enforced, and that is the half that protects
re-theming rather than the half that protects meaning.

# B. Vocabulary

| Rule | Where | Held? |
| --- | --- | --- |
| A button label says what the button does | `t/lint/97` | **ENFORCED** |
| `Save` commits; `Apply` is only for putting a prepared thing into effect | style guide, SM699 | STATED |
| `Cancel` when work would be lost, `Close` when nothing would | style guide | STATED |
| `Delete` destroys; `Remove` takes out of a list; `Clear` empties a field | style guide | STATED |
| One way to name a principal | `t/lint/47` | **ENFORCED** |
| Retired terms are not reintroduced | `t/lint/08` | **ENFORCED** |
| sysop is the app, sysadmin is the host, manager is the UI | 0.11.3 changelog | IMPLICIT |
| A refusal names the capability, not only the action | SM712 | STATED |
| A non-JSON body is not "malformed data" | `t/lint/79` | **ENFORCED** |

# C. Which container for what

| Rule | Where | Held? |
| --- | --- | --- |
| The row expander is ONE idiom: two elements with two jobs | `t/lint/99` | **ENFORCED** |
| Expander when a row has too much detail for the row, not enough for a modal | style guide | STATED |
| Modal for a subject that is its own application - a panel below a long list is not seen (SM680) | style guide | STATED |
| A card holds one subject, and cards do not nest | style guide | STATED |
| A badge labels a thing; a tag records a state and who set it | style guide | STATED |
| A status line belongs to the page; a toast belongs to the action | style guide | STATED |
| Domains has one form, not two | `t/lint/29` | **ENFORCED** |
| The AI setup is one flow | `t/lint/78` | **ENFORCED** |

# D. Interaction and feedback

| Rule | Where | Held? |
| --- | --- | --- |
| The six save behaviours (dirty, note, warn, in-place feedback, in-flight, resolve) | style guide, SM726 | STATED |
| The handler wizard does not move under the operator | `t/lint/106` | **ENFORCED** |
| A page keeps the elements its script fetches | `t/lint/94` | **ENFORCED** |
| A page calls only helpers it has | `t/lint/103` | **ENFORCED** |
| A manager page's script parses | `t/lint/104` | **ENFORCED** |
| An expired session is reported, not silently failed | `t/lint/69` | **ENFORCED** |
| A protected folder says so in its own row | `t/lint/72` | **ENFORCED** |
| Adding a domain mentions TLS | `t/lint/74` | **ENFORCED** |
| A refusal answers with a refusal, not 200 | SM670, unbuilt | IMPLICIT |
| A capability hint is focusable - a title attribute alone is mouse-only | style guide, SM686 | STATED |

**This is the largest STATED-not-enforced block, and SM726 has just added to
it.** The six behaviours are the newest rules and nothing holds them.

# E. Data presentation

| Rule | Where | Held? |
| --- | --- | --- |
| A column that can be long wraps rather than pushing the row sideways | style guide | STATED |
| A checkbox column is checkbox width | style guide | STATED |
| A table that cannot fit scrolls in its own box, never the page | CSS, MR-18 | IMPLICIT |
| A long list is sectioned by what a thing IS | style guide, groups | STATED |
| An entry says what it rolls up into rather than being repeated | style guide | STATED |
| A refused listing is rendered where the rows would be | MR-93 | IMPLICIT |
| Rows carry a quotable reference | house rule | IMPLICIT |
| A demonstration page does not advertise itself | `t/lint/82` | **ENFORCED** |

# F. Input

| Rule | Where | Held? |
| --- | --- | --- |
| A read-only value is shown as a value, never a disabled input that looks editable | style guide | STATED |
| A value derivable from another field is PICKED, not typed | `t/lint/70` | **ENFORCED** |
| A note explains a field; a help line explains a page | style guide | STATED |
| Placeholders name the value a field falls back to when cleared | MR-13 | IMPLICIT |
| A checkbox belongs beside its label, not under it | MR-19 | IMPLICIT |
| No control characters in manager pages | `t/lint/24` | **ENFORCED** |
| Surfaces require the same arguments | `t/lint/52` | **ENFORCED** |

# G. Layout and responsiveness

| Rule | Where | Held? |
| --- | --- | --- |
| The three sheets narrow alike | `t/lint/107` | **ENFORCED** |
| A page does not carry its layout inline - per-page ceiling, ratcheting down | `t/lint/108` | **ENFORCED** |
| A manager page does not carry its own stylesheet | `t/lint/100` | **ENFORCED** |
| A page does not use a class nothing defines | `t/lint/95` | **ENFORCED** |
| The style guide is the stylesheet's contract, both directions | `t/lint/96` | **ENFORCED** |
| Nothing is clipped and the page never scrolls sideways | `tools/manager-layout-check.js` | **browser check, not in the gate** |

**This family is the best held of all**, and it is worth asking why: every rule
here has an obvious mechanical proxy. That is not a coincidence, it is the
selection effect - the rules that got enforced are the ones that were easy to
check, not the ones that mattered most.

# What the tally says

Roughly **28 rules are ENFORCED**, **24 STATED**, **10 IMPLICIT**.

Two observations worth carrying into any rule engine:

**The enforced set is skewed toward structure, the unenforced toward meaning.**
"A page does not use an undefined class" is enforced; "a destructive action uses
the destroying colour" is not. The first is a property of the text; the second
needs to know what an action *does*.

**Every STATED rule in section D is new.** Interaction rules are the youngest
and the least held, which is where drift will appear first.

# What a controllable rule needs

For a rule to be defined once and applied, it needs three parts. Most rules here
have one or two:

1. **A semantic statement** - what it means, in words that survive the
   implementation changing. Nearly all of them have this; the style guide is
   good at it.
2. **A subject it can be evaluated against** - a class, an action name, a
   handler, a rendered element. Where this is missing, the rule cannot be
   checked at all: *"a destructive action"* is not yet a thing the code can
   enumerate.
3. **A mechanical proxy** - the check that stands in for the meaning, and an
   honest note of where proxy and meaning diverge.

**The missing piece across the whole inventory is (2).** The manager has no
declaration of what an action IS - destructive, state-changing, committing,
retrieving. Once a page's controls declared their kind, most of section A and
much of section D would become checkable, because the checker would finally have
a subject to ask about.

That is the single change that would move the largest number of rules from
STATED to ENFORCED, and it is worth knowing before any rule engine is designed.

# What this document does not do

It does not propose changes, rank the gaps, or argue that any rule is wrong. It
records what exists so that a decision about rules can be made against the
actual set rather than a remembered one.
