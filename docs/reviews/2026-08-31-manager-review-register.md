---
title: "Manager review, 2026-08-30/31: every item the release manager raised, and where it got to"
subtitle: "One row per piece of feedback from the live-manager review sessions, with what was done or why it was not. Forty-eight done, eight open. DONE items are on claude/expander-roles. OPEN items are the backlog this review produced - nothing here is closed by having been read, and MR-53 carries a proposal rather than a change because it affects every listing."
brand: plain
standard-margins: true
---

# How to read this

Every row is something the release manager said, in the order it arrived.
**Done** means shipped on `claude/expander-roles` and covered by a test where a
test was possible. **Open** means not built - the reason is in the row, and a
reason is not a closure.

Refs are quotable: `MR-01` and so on.

# Done

| Ref | Raised | What was wrong | Where it landed |
| --- | --- | --- | --- |
| MR-01 | Files expander shows a thin line | The 0.11.8 class collapse merged the toggled wrapper and its inner card into one name, so `closest()` returned the wrong element and the panel opened empty. Data had it too | `t/lint/99` |
| MR-02 | Small square artifact under titles | `.mg-status::before` painted a dot on 13 pages that ship an empty status div | `.mg-status:empty` |
| MR-03 | Dark/light switch not working | `:root` and `[data-theme="light"]` are equal specificity and the dark media block came later, so on a dark OS it won. Failed in ONE direction, which is why it passed review | `t/lint/96` |
| MR-04 | Left menu headers indistinct | Heading and items were both `--mg-text-muted`; the heading differed only by being smaller | — |
| MR-05 | Manager lost its structure, needs cards | The card component is used 128 times across 11 pages; Site settings used it zero times | — |
| MR-06 | Navigation modal too big, fills the page | The stylesheet describes wrapper > backdrop + panel; the JS built the opposite, and `.mg-modal` is `inset: 0` | — |
| MR-07 | Settle on one modal | Three idioms existed; `data.md` reimplemented `.mg-sheet` in a page-local block | `t/lint/100` |
| MR-08 | Plugin config cramped on the right | `.mg-plugin-card` is a flex row, so the whole handler UI was one squeezed child | — |
| MR-09 | Check for reuse before inventing | 80 hard-coded colours became tokens; five duplicate classes merged; four pages' intro text moved to the shared note box (four more later) | `t/lint/101` |
| MR-10 | Manager access not permitted | `local $/` leaked into `_group_closure`, so the groups file was read as ONE line: 21 groups became 1 and no nested group ever resolved | SM702, `t/unit/auth/60` |
| MR-11 | Style guide popup cannot be closed | Modal and toast specimens were pinned; they are triggered now, and the modal closes three ways | — |
| MR-12 | Data tables plugin missing from the list | The preview docroot's parent held a stale `plugins/` directory; not a product fault | — |
| MR-13 | Placeholder text on Site settings | Five fields, each naming the value it falls back to when cleared | — |
| MR-14 | Blocked IPs belong in Plugin Config | Measured: a blocked address is refused the site (403), so it is an access control, not a reporting filter | SM703 |
| MR-15 | Plugin config / form config squashed | Answered: expander, not modal - detail you scan and edit in place | — |
| MR-16 | Footer warning should use a colour | The `-bg` tokens are quiet tints; across a full-width bar they read as white | — |
| MR-17 | Sessions info button squashed | No affordance and no spacing; it is a bordered control now | — |
| MR-18 | Device column runs off the right | Cells wrap; `.mg-table-wrap` replaced inline `overflow-x` on four pages | — |
| MR-19 | Checkbox on its own row below its label | `.mg-field` stacks label above control - right for a text box, wrong for a checkbox | — |
| MR-20 | "Turn these on" does not look like a button | It sat inline against its note | — |
| MR-21 | Preview appearance does not preview | `previewStyle` called `escHtml`, which the page does not define. ReferenceError, so the modal never opened | `t/lint/103` |
| MR-22 | Title should be "Manager theme" | Group renamed | — |
| MR-23 | Force refresh after a theme change | The sheet is chosen server-side, so a change was invisible on the page that would show it | — |
| MR-24 | Six identical Save buttons on Users | Named for their object - Save name / note / email / password - and none primary | — |
| MR-25 | New table: nothing happened | `test-1` is invalid, and the refusal went to a toast the operator was not looking at | — |
| MR-26 | "Save descriptor" should say create | Contextual: Create table when declaring, Save changes when editing | — |
| MR-27 | Why migrate when creating? | A plan weighs what a change costs existing rows; a new table has none. Declaring runs straight through | — |
| MR-28 | The default descriptor errors | It set `key: id` AND declared an `id` field, which the validator refuses | — |
| MR-29 | New-table modal cuts off text | Panel widened; the field table scrolls in its own box | — |
| MR-30 | "Required" wrapped to "Re qui re d" | My own regression: `overflow-wrap: anywhere` on `th` breaks mid-word | — |
| MR-31 | Does anything audit? | Yes - table create, migrate and row-save were all recorded. The expander's LINK filtered on the ACL rule key while rows record the table name | — |
| MR-32 | Export buttons flush against owner | Separated | — |
| MR-33 | Intro text should always be in the box | Eight pages in total, in three different spellings | — |
| MR-34 | Editor: collapsible metadata, content, access | All three are `<details>`; Metadata closed; Access reuses `mgRights` | — |
| MR-35 | Groups should be nested | Measured first: it is a GRAPH - 8 groups have several parents, one has seven - so sections by kind, each group once, each naming what it rolls up into | — |
| MR-36 | Groups page stuck on Loading | My edit script printed "ok" then aborted before writing, so half an edit landed | `t/lint/104` |
| MR-37 | Plugins page button styling | Configure was full size beside small action buttons | — |
| MR-38 | Rename to Branded PDF creation | The old name named the tool, and the wrong tool | — |
| MR-39 | Status just says "Done" | It returned a bare `ok`; it now reports the converter, its version and the brands | — |
| MR-40 | Is the brand folder served? | **It was.** Every template and logo answered an anonymous GET with 200. Moved under `lazysite/` | SM694 |
| MR-41 | data.pl header drift | It claimed its surfaces were "the next commit" three releases after they shipped | — |
| MR-42 | Manual add of a blocked address | Same store and shape as an automatic entry | SM704 |
| MR-43 | Remove the placeholder card from stats | "No need to say what isn't there" | — |
| MR-44 | Modals should be as big as their content, scrolling only at browser width | Five panels had five fixed ceilings, and `showModal` built a sixth overlay in `cssText`. One rule now: `max-content`, floored so a sentence is not a sliver, capped at the window. Prose is capped separately so a long message wraps rather than stretching the dialog | — |
| MR-45 | What does "not published" mean, and how do you publish? | It was a bare label an operator could neither read nor act on. Both places now say it is about anonymous visitors, and name the Published tickbox in Fields as the way to change it | — |
| MR-52 | Remove the plugin pointer from Site settings | Removed | — |

| MR-55 | The `members` group is an example for the demo, and now has a display name and description - put them in the seeded data | Seeded. It shipped with every install and no label, so it showed its bare name for ever - the state SM642 fixed for groups an operator makes, still true for the one group everybody starts with. It says it is an example, so nobody has to guess whether deleting it breaks something | — |
| MR-56 | Still "What would migrating do?", and still not understood | The button was hard-coded onto the panel, so it asked while a table was being CREATED (nothing to compare) and again when the stored table already matched (answer: nothing). It appears only when the two have come apart, and says "Compare with the stored table". The plan's own wording drops the word: "These can be applied safely, keeping every row" / "These cannot be applied to the stored table". The listing says "fields changed, not yet applied" rather than "needs migrating" | — |


# Open

| Ref | Raised | Why it is still open |
| --- | --- | --- |
| MR-46 | Red and copper are neighbours | `--mg-danger` is hue 27, `--mg-accent2` is hue 45. The field agent read a `--mg-danger` Delete as copper. Referred to the designer rather than re-picked here, because it is their semantic set |
| MR-47 | A dense settings card, and a dense list, have no specimen in the guide | We built both with existing components; neither is designed. In the designer brief |
| MR-48 | `domains.md` carries 1,019 lines of page-local CSS | The last page-local block, tracked as debt with a ceiling so nothing new joins it. Needs the designer's eye on which rules are new components and which re-invent existing ones |
| MR-49 | Narrow widths are unreviewed | The nav drawer only appears below about 1000px and has never been looked at there; nor has the device column |
| MR-50 | SM662: a gate declares its capabilities | Built and proved by fingerprint, then DROPPED from the stack: it breaks six suites that parse the literal `%need` block. Held on `claude/need-declares-caps` |
| MR-51 | Layout install said "Layout not found" | Preview artefact, not a product fault - there are no layouts in the starter tree and a theme installs into one. Recorded so it is not re-investigated |
| MR-53 | The manager still has column problems: space wasted on the right while extra columns are cramped inside rows. What would render these better? | Not done, and it is the last structural question left. A proposal is below rather than a change, because it affects every listing |
| MR-54 | Nav: the edit line should be a modal holding both boxes, not one after the other | Not done |

# What this review says about the gate

Four of the defects above shipped through a full release gate:

- **MR-01, MR-03, MR-21** are appearance and behaviour. The tier reads source
  as text, so a page can be syntactically valid, semantically wrong and pass.
- **MR-36** was not even valid JavaScript. Nothing parsed page scripts until
  `t/lint/104`.
- **MR-10** failed CLOSED and was invisible to every existing test, because
  they all put their user in a group holding the capability directly.
- **MR-40** was a security exposure that no test asked about: whether a
  default path is served.

Five new lints came out of this review (`99`-`104`). The pattern in all of them
is the same: the tier could say what the code SAYS, and could not say what the
browser DOES.

# MR-53: what would render these better

The shape of the problem, measured rather than felt: a listing row is a flex
line with a name, some metadata and a group of buttons. It has no columns, so
everything after the name is pushed right and packed against the edge, while a
page laid out for reading leaves the right-hand third empty.

Three ways out, using what already exists:

**1. A grid row rather than a flex row.** `.mg-row` becomes
`grid-template-columns: minmax(0,1fr) auto auto` - name, metadata, actions -
so the columns line up DOWN the list rather than each row packing
independently. This is what the Plugin row already does
(`4.5rem 1fr auto`), and it is why that page reads more evenly than Files.
Cheapest change, biggest gain, and the guide already has a specimen.

**2. The metadata moves under the name, not beside it.** Two lines per row -
name on the first, `9 rows · no access rule` in `.mg-muted` on the second -
which is how the Files listing already treats a filename with its size and
date. It buys horizontal room without a wider window and reads better at
narrow widths, where these rows currently overflow.

**3. The page stops being a column of text.** `.mg-main` is capped for reading
prose, which is right for Site settings and wrong for a listing: a table of
tables wants the width. A listing page could opt out of the reading cap.

**Recommendation: 1 and 2 together, 3 only for pages that are wholly a
listing.** They compose - a grid row whose first column holds a two-line
name-and-metadata block - and neither invents a component. **This is a design
question as much as a layout one**, and the dense-list specimen it needs is
already on the designer's list (MR-47).
