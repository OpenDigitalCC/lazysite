---
title: AI briefing - field practice
subtitle: One agent's field notes from building and breaking real sites and apps on this engine - a companion to the reference briefings, not a specification.
register:
  - sitemap.xml
---
<!-- lazysite:field-practice-import
     generator: tools/import-field-practice.pl
     engine-version: 0.11.5
     imported: 2026-08-28
     agent: the lazysite site agent (Claude Code)
     source: /srv/projects/lazysite-sites/AUTHORING-PRACTICE.md sha256=58fbc62167fe7787c14374c3ef9eb0bcb871f5ab5ce1472ed3960c72bede1e3d modified=2026-08-28
     source: /srv/projects/lazysite-apps/APP-PRACTICE.md sha256=8a0249245da56abbf75c7438122b8d15c1eafb5854653d202b57982c77d7eccc modified=2026-08-28
     body-sha256: 93643f56738a34aeb96637d81d79f404a2f813c4b7a513cf8e57f31da00ea602
-->

## What this is, and what it is not

These are **one agent's field notes** from building and breaking real sites and apps on this engine. They are a **companion to the engine's reference briefings, not a specification**: nothing here defines behaviour, and nothing here was written by the engine.

**Where these notes conflict with the engine's reference docs, the reference docs win, and the conflict is a bug in these notes.** Report it rather than working around it - a stale line here is worse than no line, because it will be trusted.

This copy was **generated for engine 0.11.5**. The last section, *Where this came from*, names the sources, the agent and the dates.

## How the sections are marked

Some of what the field learns is true of one engine version and false of the next, and some of it is true whatever engine a site runs. They are worth different amounts to you, so they are marked:

| Marking | What it means |
| --- | --- |
| **Version-dated** | Behaviour that **differs by engine version**, kept as before/after columns. Not resolved down to "current behaviour": a half-migrated estate is the normal state, and the agent on an older site is the one who needs the left-hand column. Check the engine a site runs before acting on one of these. |
| **Version-independent** | A field scar. It cost somebody real time, it does not depend on a version, and it is the most useful part of this page. |
| unmarked | General practice - judgement and habit rather than mechanism. |

The engine version a **running** site reports is not necessarily this one. The briefing set is served from the site's own docroot, so a site installed from an older release serves an older copy of this page.

## Part one: sites and content

*Pages, layout, theme, HTML and styling.*

## The toolkit, and what each part is for

The engine gives more than Markdown. Reach for these before writing HTML.

### Front matter, with source prefixes

`tt_page_var` values may be literals, or carry a source prefix:

- `json:` - decode a local JSON file into a structure you can loop over
- `scan:` - a list of pages matching a glob
- `url:` - fetch a remote value
- `${ENV}` - an allowlisted environment value

This is documented in `docs/frontmatter.md` and is easy to miss. **`json:` is
the single most useful feature for content-heavy or repeating pages** and it
removes the temptation to generate pages offline.

```yaml
tt_page_var:
  gallery: json:/data/paintings.json
```

### Template Toolkit in the page body

Front-matter variables are available in the body. **The body becomes HTML
first and TT runs second, over the rendered HTML** - see "Things that look
equivalent and are not" for the two things that follow from it, both of which
bite when a variable feeds an image or a `:::` fence.

`loop` carries everything a list needs:

- `loop.count` / `loop.size` - a human-facing counter
- `loop.index` - zero-based, for "first N" decisions
- `loop.first` / `loop.last` - booleans
- `loop.prev` / `loop.next` - the neighbouring items

Wrap-around navigation without storing neighbours in the data:

```
[% FOREACH w IN works %]
[%- prev = loop.first ? works.last.id : loop.prev.id -%]
[%- next = loop.last  ? works.first.id : loop.next.id -%]
...
[% END %]
```

### Components

A `::: name key="value"` fence renders through `components/name.tt`, where:

- the inner Markdown becomes `content`
- the attributes become `attrs`
- direct-child `::: slot` fences become `slots.<slot>`
- it is **nesting-aware**; components nest inside components

Components live at `lazysite/layouts/<layout>/components/*.tt`. Components under
`lazysite/templates/components/` are available to **any** layout, and a layout's
own component of the same name wins.

Front matter can also carry `sections:` as structured data, which a layout
iterates and dispatches to the same components.

### Themes carry the look, layouts carry the structure

Colours, type and spacing belong in `theme.json` as tokens, emitted as CSS
custom properties. A component or layout should reference tokens, never literal
colours. This is what makes a restyle a one-file change.

### The style guide is the design contract

When the look is produced by a separate process - a design agent, a themer, a
later you - the style guide is the contract between that process and the content,
and it is the primary artefact. The rule runs both ways:

- **Every component the pages emit is registered in the style guide**, in each of
  its states, with test content. A component is not finished until it has an entry
  there. Register it the moment a page starts emitting its class, so the design
  side has something to style against; the structural class can carry a neutral
  token-based default in the meantime.
- **The theme's job is to deliver everything the guide names.** The design process
  reads the style guide and ensures each component in it is styled - nothing the
  pages use is left to render unstyled. The guide is the checklist the theme is
  measured against: a component present in the guide but missing from the theme is
  a gap in delivery, not a licence to hand-style a page.

Because the contract is explicit the two sides do not collide - the content side
names and demonstrates what it needs, the theme side styles what is named, and
neither edits the other's files to get its way. That separation is the whole point:
the **design side READS the style guide and WRITES the theme** (`theme.json` and its
CSS); the **content side WRITES the style guide and the pages** and only READS the
theme, to reference its tokens and classes. Because the two sides write different
files, their edits never conflict - the style guide is a one-way contract carrying
intent from content to design, and the theme is design's alone to author.

Where a new component must be usable before the design side has delivered its
styling, the content side may seed a neutral, token-only structural default in the
theme as a temporary bridge - flagged as such, and superseded the moment design
styles it. The steady state is design owning the theme outright. Either way, when
the theme is updated underneath you, sync to it rather than overwriting it; the
revision history on the theme and the guide is how each side sees what the other
changed.

### Other things worth remembering

- `aliases:` - every retired URL gets one on its successor at conversion
- `register:` - what appears in `sitemap.xml` / `llms.txt`
- `.url` files - a page that is a redirect
- Native forms - `create_form` or a `:::form` bound to a vetted handler, never
  hand-written form HTML or a third-party service

## Briefs: stop writing sidecars from 0.10.29

*Version-dated - this describes behaviour that **differs by engine version**. The before/after columns below are kept on purpose. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

**SM245 retires the `.brief` sidecar.** The record survives, in an engine-owned
store at `lazysite/briefs/<content-path>`, owned by a contract plugin that ships
**disabled** - the operator enables it per site and runs its Migrate action,
which imports every existing sidecar idempotently and never removes one it could
not import.

| Was | Is, from 0.10.29 |
|---|---|
| write `<file>.brief` over WebDAV | `append_brief` (MCP) / `brief-append` (API), under `manage_content` |
| read the sidecar | `read_brief` / `brief-read` |
| you stamped the date and your name | the store stamps the date and your **verified** identity |
| append-only by convention | append-only, unchanged |

`append_brief` takes `{path, entry}`.

**A brief is not only for a page.** The store keys on a path and does not check
that the target is a file, or that it exists. Verified on 0.10.29: a folder
(`/docs`), an asset (`/favicon.ico`), a layout, a theme stylesheet, the nav, a
form submission store and **the site root** (`/`) are all accepted keys. So the
place to record why a whole section exists is a brief on the folder, and the
place to record what a site is for is a brief on `/`.

Two things it will not key: anything under `lazysite/db/` (blocked), and a data
table ROW (no path exists to name one). Whether to extend to those is an open
decision with the operator, not settled practice.

**The trap:** writing a `.brief` over WebDAV still *works mechanically* after the
change. It just writes an inert file - nothing lists it, nothing carries it, and
nothing imports it after the one-shot migration. There is no error to tell you.
So the rule is not "prefer the tool", it is **stop authoring sidecars** on any
site running 0.10.29 with the plugin enabled.

The denies are unchanged: a stray `.brief` still 404s and never indexes, so
nothing leaks during the transition.

**Until 0.10.30, `move_file` does not carry a brief, and deleting a file
leaves one behind.** The store is path-keyed, so a moved
file's entry stays under its OLD path until a reconcile - recorded as the
accepted interim, and a deleted page's brief becomes debris that nothing can
list or remove. **Do not read an empty brief after a move as data loss**; read
the old path.

**Fixed in 0.10.30, and verified on edge:** the entry follows the file on move
and goes on delete - over WebDAV as well as through the tools - a copy starts
unbriefed, and `list_briefs` / `delete_brief` make strays visible and clearable.
`list_briefs` returns path, size, mtime and an `orphan` flag; `read_page` reports
`has_brief` from the store. **Check which of these a site has before assuming
either behaviour**, the same way you check whether the plugin answers at all.

Two things worth knowing about the store once you can list it:

- **`list_briefs` is how you find out what a site actually has.** On edge it
  turned up five briefs nobody had mentioned, two of them 22-23KB, migrated
  intact from sidecars. Until the listing existed there was no way to know.
- **An orphan is a brief whose file is gone.** `delete_brief` is permanent and
  the store has no undo, so read one before removing it - a 6KB brief is
  somebody's thinking, and the page being gone does not mean the reasoning was
  worthless.

**Nothing is deleted, and migration is per site, whenever that site is next
revisited.** There is no estate-wide sweep and no deadline: a site can sit on
sidecars indefinitely and must keep working. So **a half-migrated estate is the
normal state for a long time**, and arriving at a site you cannot assume either
condition.

**Check before you write a brief.** The plugin is off until an operator enables
it, and the tools do not answer until they do:

- tools answer -> use `append_brief` / `brief-append`
- tools do not answer -> that site is still on sidecars; write the file, and
  the operator's Migrate will import it when they get to it

Filed 2026-08-24 (operator's instruction): a `.brief` write **should be refused**
once the plugin is enabled, rather than silently landing an inert file. Until
that ships, the check above is the only thing standing between you and a record
nobody reads.

## Choosing the right tool

- **Prose, headings, links** - Markdown. Nothing else.
- **A repeating structure on one page** (cards, a gallery, a listing, a price
  table) - a JSON data file plus a `FOREACH`. Not copy-pasted blocks, and not an
  offline generator.
- **A repeating structure across many pages** (hero, stats band, CTA) - a
  component, invoked by a `:::` fence or `sections:`.
- **Chrome shared by every page** (header, nav, footer) - the layout.
- **A distinctive look** - theme tokens.
- **A list of existing pages** (index, archive, related) - `scan:`.
- **One genuinely self-contained interactive artifact** - the only case for
  `api: true` / `raw: true`, and it needs its own `content_type`.

## Graphics-heavy sites

A visual site is not a different kind of site. Measured across this estate, raw
HTML in Markdown tracks one thing only: whether the site has components.

- Sites with a component set: 0.1% - 0.5% raw HTML
- Sites without: 5% - 20%, and one at 87%

`community.dhcf.eu` writes a three-number stats panel as 24 lines of hand HTML
with an inline `style` hack. `dito.tech` renders the same shape from a 9-line
component fed by a list. Same engine, same week.

### Receiving a design

Designs often arrive as a zip of monolithic HTML from a design tool or another
Claude. **Do not publish it as-is**, and do not paste it into a Markdown body -
the engine refuses `raw: true` pages with an HTML content type, but nothing
stops a monolith pasted into an ordinary page, so the guard will not save you.

Decompose in this order:

1. **Find the repeats.** Any block appearing three or more times with the same
   class signature is a component. Do this before anything else; it determines
   the shape of everything after.
2. **Pull the copy out** into Markdown and the structured bits into a JSON data
   file. Ask: could the client edit this text without seeing a tag?
3. **Collect the visual decisions** - every colour, size and spacing value - and
   put them in `theme.json` as tokens. No literal colours survive this step.
4. **Rebuild the page** as prose plus component fences.
5. **Check the round trip.** The next design iteration should touch tokens and
   components only. If a redesign would force re-entering content, the
   decomposition is not finished.

### Photograph-led galleries

- Two image sizes: a thumbnail for the grid, a larger one for the lightbox.
  Grid images **eager** (they are the page); lightbox images **lazy**. A browser
  fetches `<img src>` even inside `display: none`, so the naive arrangement
  downloads every full-size image on first paint.
- Strip EXIF. Check for GPS rather than assuming there is none.
- Uniform grid cells with the picture *contained*, not cropped, when the set
  mixes portrait and landscape. Ragged rows read as accidental.
- Lightbox controls belong to the **viewport**, not the image box. An image box
  sized per aspect ratio moves its controls between works and puts them on the
  artwork.
- Size the lightbox picture by height and let the frame `width: fit-content`
  shrink-wrap it. Then no dimensions are needed in the data at all.

## Anti-patterns

**Never label one statement as honest, or as precisely stated.** "The honest
position", "one honest qualification", "stated precisely" - each implies
everything else on the page is dishonest or imprecise. The label undermines the
whole to decorate a line. State the fact and let it stand; a qualification is
just a sentence next to the claim it qualifies. (Keep `precisely` where it means
*accurately* - "restrict the ports precisely" carries information.)

- **An offline generator that produces a page.** If a `.md` is machine-written
  from a manifest, the manifest belongs in the docroot and the page belongs in
  a `FOREACH`. I built one of these before finding `json:`; it was pure cost.
- **`raw: true` on a content page.** It skips layout and theme, so the page must
  carry its own chrome and CSS. This is how monoliths are made.
- **Inline `style=` attributes.** Always a missing token or a missing component.
- **Literal colours in a component or layout.** They defeat restyling.
- **Derived data in a hand-edited file.** Image dimensions, counts, neighbours.
  Compute them at render time or in the build that produces the asset.

## A `db:` binding has a row ceiling, and it changed in 0.10.30

*Version-dated - this describes behaviour that **differs by engine version**. The before/after columns below are kept on purpose. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

A binding with no explicit limit does not return every row. This bites only
once a table passes 200 rows - which is exactly when a site has become worth
something - so check which engine a site runs before trusting a list.

| Binding | 0.10.29 and earlier | From 0.10.30 |
|---|---|---|
| `db:works`, 250-row table | **200 rows, silently** | 500-row ceiling; a capped render logs a WARN |
| `.count` on that page | **200** - counted after the limit, so it agreed with the short list | the **true** count, 250 |
| `db:works limit=501` | **nothing at all**, no error | clamps to the ceiling and **serves rows**, warning on the result |
| Showing the real total | no way to | `[% items_total %]` beside `[% items.size %]` |

**On 0.10.29 the page and its own count agreed with each other and were both
wrong**, with no signal anywhere - not on the page, not in the source, not in a
log. That is the version to be careful on.

The 0.10.30 column is **verified on edge**: a 250-row table renders 200 with
`items_total` reporting 250 and `.count` reporting 250, and `limit=501` serves
rows rather than nothing. Note the default is still 200 when no limit is given -
500 is the ceiling you may ask for, not the default you get.

From 0.10.30 the ceiling is one number, 500, stated once; an over-cap request
clamps rather than emptying; and every list binding gets a companion
`<var>_total` carrying the true count. The sanctioned spelling for an honest
list is:

```
showing [% items.size %] of [% items_total %]
```

So:

- **On 0.10.29, name a limit whenever a table might grow past 200**, keep it at
  or below 500, and never ask for more than 500 - it renders an empty page, not
  a truncated one.
- **From 0.10.30, say the total** rather than hoping the list is complete.
  `_total` costs nothing where you ignore it.
- Either way, a table that must show more than 500 rows on one page cannot be
  done with a single binding. Page it with `offset`, or reconsider the page.
- When a list looks short, check the row count before hunting for a filter bug.

## Creating a page in a folder that does not exist yet

*Version-dated - this describes behaviour that **differs by engine version**. The before/after columns below are kept on purpose. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

Verified on 0.10.30, and the channel decides:

| Channel | Deep path with missing parents |
|---|---|
| MCP `write_file` / `create_page` | **creates the parents** and the page |
| Manager save | creates the parents |
| WebDAV `PUT` | **refused** - "Parent collection missing - MKCOL the parent(s) first" |

The WebDAV refusal is correct behaviour, not a gap: RFC 4918 9.7.1 requires it,
and every WebDAV client in the world expects it. So `MKCOL` each level first
when you are working over DAV, or use the MCP tools, which do it for you.

A brief may be appended to a path at any depth whether or not anything exists
there yet, on any channel - that is what makes brief-first authoring possible.

## WebDAV writes that leave something stale

*Version-dated - this describes behaviour that **differs by engine version**. The before/after columns below are kept on purpose. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

Proven defects as at 0.10.32, fix planned but NOT yet shipped. They share one
shape: **the manager path cleans up and the DAV path does not**, so the same
logical edit has two different outcomes depending on how you made it.

| What you do over DAV | What is left stale |
|---|---|
| `MOVE` or `COPY` a page | Registries are never invalidated - **the sitemap keeps advertising the old URL**. The manager's own move clears it |
| `DELETE` a collection | A **301 alias survives, pointing at a page that no longer exists** |
| Write `nav.conf` | Cached pages keep rendering the **old nav** until something else invalidates them |

Until these land, after any of the three: **regenerate the registries and
invalidate the cache explicitly**, or make the edit through the manager or MCP
instead, which do it for you. And check the sitemap after a move rather than
assuming - an old URL left advertised is the kind of thing a visitor finds
before you do.

This is the same lesson as the parent-directory one, in the other direction:
WebDAV is a file protocol and does exactly what a file protocol should. The
engine's bookkeeping hangs off the tools that know about pages.

## Things that look equivalent and are not

*Version-independent - a field scar. It holds on any site you connect to, whatever engine that site runs.*

Each of these cost real time; none is obvious from reading.

- **`height: min(72vh, 100%)` is not `height: 72vh`.** Against an auto-height
  parent the `100%` term has nothing to resolve against and the bound is lost -
  the image renders full size and overflows.
- **`width: fit-content` on a ratio-computed box is not the same as sizing by
  height.** Shrink-to-fit uses the *intrinsic* width, i.e. the width the image
  would have had without the height cap.
- **An `aliases:` 301 drops the query string.** If a legacy URL carries data in
  its query, an alias resolves the URL and discards the payload.
- **An unknown file extension is not served.** Static files come from a known
  extension list, so a hand-written `.shtml` redirect stub can never run.
- **The active layout is read-only over WebDAV.** To edit it, activate another
  layout first; a page pinning `layout:` in its front matter is unaffected, so
  the live page need not change while you do.
- **A `::: name` fence with no matching component fails silently** as a plain
  div. A typo looks like a styling bug.
- **`<meta name="generator">` reports the build that rendered *that page***, not
  the running version. To learn the running build, publish a page that has never
  existed and read its stamp.
- **The body becomes HTML first; TT runs second, over the rendered HTML.**
  Corrected 2026-08-24 from the processor, having first inferred it wrongly the
  other way round. Two consequences that look unrelated and are the same fact:
  - **Markdown image syntax cannot carry a template expression.**
    `![[% p.title %]](/img/[% p.file %])` renders a stray `!` and a link. The
    image regex runs while `[%...%]` is still literal, cannot match across it,
    and falls back to link syntax. True in the alt AND in the URL, fence or no
    fence. Use `<img src="/img/[% p.file %]" alt="[% p.title %]">` whenever any
    part of an image comes from a variable - HTML passes through the Markdown
    pass untouched and TT then fills the attributes.
  - **A `:::` fence inside a `[% FOREACH %]` does work, but not for the reason
    it appears to.** The fence has already become ONE `<div>`; the loop then
    multiplies that rendered div. So the loop cannot choose a fence's NAME
    (`::: [% p.kind %]` is literal text, never a component) or emit one
    conditionally - by the time TT runs, the fence is gone. **Put the
    `[% IF %]` around the fence's CONTENT instead, or emit the raw HTML.**
- **A data table is closed until it is published.** Without `public: true` in its
  descriptor, the control API reads its rows and a page renders none. The two
  symptoms together look exactly like a permissions fault or an unwritable
  store, and nothing in the empty result says "not published".
- **One wrong spelling of a working route looks identical to a missing
  capability.** `acl-set` takes its path from the query and its lists from the
  body; sending both in the body is refused for the path, which reads as "this
  surface cannot do it". It can. Before concluding a capability is absent, try
  the documented shape, not just a shape.

## Verify like this

*Version-independent - a field scar. It holds on any site you connect to, whatever engine that site runs.*

- After every publish, fetch the page and confirm the thing you changed.
- Prefer a probe that cannot lie: to test a loop, render it; to test a version,
  force a fresh render; to test a font, compare against a known-good control.
- **Headless Chromium ignores `loading="lazy"`** and will fetch everything -
  proved with a three-image probe. Do not use it to measure loading behaviour.
- When a measurement surprises you, test the harness before believing the
  result. A control line costs a minute and has twice stopped me filing a
  defect that did not exist.
- **A loop that reports success after processing n-1 items is the worst kind
  of failure.** `while read -r f` silently drops a final line that has no
  trailing newline, so a delete loop cleared five of six and reported done.
  Guard it - `while read -r f || [ -n "$f" ]` - and **count before and after**,
  because the count is what catches it, not the loop's own output.
- **A pass under your own grant is not evidence that a gate exists.** SM515:
  `delete_brief` shipped in 0.10.30 and 0.10.31 with no capability declared, so
  ANY authenticated partner could call it - a themes-only grant included. My
  tests passed both cuts and could not have seen it, because I held
  `manage_content` and so was never refused. **Testing that a thing works says
  nothing about who else it works for.** When you report a pass, say what
  capability you held while proving it; a real gate check needs a *weaker*
  credential than the one the feature is for, and if you have only one grant,
  say the gate is unverified rather than implying it is not.
- **An absent gate is not a reached target. Verify the CONSEQUENCE, not just
  the mechanism.** I proved three ACL actions had no capability check - true,
  and it stayed true. I then wrote that a grant "can rewrite who may read and
  write any path on the site", which I had not tested: the two paths I read
  were both owned by my own account. A second principal later showed ownership
  refuses every cross-owner attempt, so the consequence I asserted was false
  while the mechanism I proved was real. A build was stopped on the difference.
  **A missing check does not tell you what lies behind it** - there may be a
  second layer, and here there was.
- **A severity claim is a testable claim: test it, or mark it untested IN THE
  CLAIM.** Words like *any*, *all* and *every* need a case that could have
  failed - one you do not own, one you did not create. Where the case does not
  exist yet, write "untested: no second principal on this site" rather than
  asserting and amending later. Amending is honest; not needing to amend is
  better, and the reader acts on the first version.
- **Say whether you are reporting an observation or a cause.** A probe showed
  `git-history-summary` ignored `limit=1`, and I reported "the slow part happens
  before the limit is applied". The real cause was that the action never reads a
  limit at all - one `git log` per tracked file. Both explanations predict the
  same observation, which is why mine survived; they are different bugs with
  different fixes. A probe can establish THAT something behaves a certain way.
  It cannot establish WHY. Offer the mechanism as a guess and label it one.
- **Two people hitting the same wall is not two pieces of evidence** if they
  used the same method. A colleague reported a test dying at compile "identical
  on untouched main, pre-existing"; run properly it passed. Shared method means
  correlated error, not independent confirmation - so reproduce a claim by a
  DIFFERENT route, or say it is unconfirmed.
- **Test the RESTRICTIVE value, not just the permissive one.** `public: false`
  on a data table was rejected on 0.10.32 while `public: true` worked - and no
  test caught it, because every fixture in the suite declared `true` or omitted
  the key. A test that only exercises the permissive setting passes straight
  through a bug in the restrictive one, and the restrictive one is usually the
  safe default: private, denied, disabled, off. Those are the values worth a
  case of their own.
- **There is no engine log you can read.** `log_event` writes to STDERR, which
  the web server collects into its own error log - there is no file under
  `lazysite/logs/` to grep, and no control-API action exposes it to a token
  client. So any behaviour whose only evidence is a log line is **not verifiable
  from an agent's position**: say so rather than reporting it as passed, and let
  it be pinned by a test that captures the processor's stderr instead.
- **A permission is not verified by the call that sets it.** `acl-set` returned
  `ok:true`, showed an owner, and said "content moved out of the document root"
  while the page stayed fully public. The check is an **unauthenticated fetch
  afterwards** - and nothing less. I recorded that ACL as working once on the
  strength of the API's own report, and it was not.
- **Never put a destructive action in a sweep.** Enumerating every action of a
  family to check their replies is a good technique; including `rebuild` and
  `drop` in that list, pointed at live data, is not. I did it, and only luck -
  the operation happened to be lossless - kept it from destroying the table the
  regression page depends on. Sweep the read actions; exercise the writers
  deliberately, one at a time, against something disposable.
- **A check that only answers when invoked does not help someone who did not
  think to invoke it.** A validator with a perfect message is still silent to
  the person who reached for the wrong tool. When building one, ask what the
  failure looks like to somebody who never runs it.
- Keep a **regression page** on a test site for anything you had to diagnose the
  hard way. `/data-test` on edge renders a published and an unpublished data
  table side by side in one request; it has already caught one behaviour change
  and costs nothing to leave up.

## Part two: apps and data

*Workflow, where state lives, how data is stored and read back, and who is allowed to see it.*

## The question that separates a site from an app

> If two people open this on two devices, do they see the same thing, and does
> what one of them does show up for the other?

If yes, it is an app and it needs a store. If no, it is a page. Most prototypes
answer no without meaning to, because the browser makes it so easy not to
notice - see *State that only exists in one browser*, below.

## Start with the design system, not the pages

The failure mode this avoids: a design tool emits one HTML page with the
styling, the data and the structure fused together, and it is dropped onto the
platform as if it were static hosting. It cannot then be themed, bound to real
data, or extended - and the next agent to touch it writes another monolith
beside it. Build the opposite, in three layers, each finished and gated before
the next relies on it:

1. **Schema first.** The data contract is the most expensive thing to change
   once pages read it. Settle every table, key and type and prove a read/write
   round-trip before any page exists.
2. **Design system second, and complete.** Extract the whole class vocabulary
   from the design up front into ONE theme + layout. No page ever carries its
   own styling.
3. **Pages third, and mechanical.** A page is structure + catalogued classes +
   a data binding. A page that seems to need new styling or a new type is a gap
   to fix in layer 1 or 2, never a page-level hack.

Once the schema and the design system pass their gates, every further page is
straightforward and looks right for free - which is also the hand-over promise:
the client can add a view later without touching design.

### The internal style guide (the governing rule)

Build one page - `/style-guide` - that renders **every** visual element the app
uses, with test content, in every state. It is the single control point for the
look:

- Every visual element appears there.
- Styling is reviewed and adjusted there - between that page, the layout and the
  theme - never on a content page. This is where the user reviews the look.
- Any new element is prototyped there first, then used.

It is the fence that keeps a later agent from fighting the theme: the class it
needs already exists, named and styled. Establish it before the first real page.
(Author it as an included bare `.html` partial so indented markup is not mangled
by the Markdown processor; person tint reaches elements as `style="--who:#hex"`
and classes consume `var(--who)`, so the palette stays in the data layer.)

### A project room for the build

Give a collaborative build its own gated area on the site - a `/team/` section
ACL'd to an admins group - holding the plan, the settled decisions, the build
method, and a questions page. It travels with the site, so a new collaborator
picks the work up without re-deriving it. Distinct from the app the end users
see. (Native forms there need a one-time operator setup - see *Forms*.)

## Probe the action before you design around the capability

*Version-dated - this describes behaviour that **differs by engine version**. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

`describe-capabilities` lists actions its own server will refuse. A capability
reads `true`, the action appears in the `actions` map, and the call answers
*"served only to the manager UI over a cookie session"*. The map answers **has
this account been granted X**, never **can this surface reach X**.

Confirmed manager-UI-only on 0.10.32: `form-targets-*`, the `handler-*` family,
`plugin-list` / `plugin-enable`, `users`, `principals`, `keys-list`,
`protected-sections`, `preview`, `cache-invalidate`. `auth_default` is refused
by `config-set` as not settable. `acl-set` refuses `lazysite/db/tables` as a
blocked path.

**Make one call of the action the design depends on, before the design depends
on it.** A throwaway probe costs a round trip. Finding out at the first write
costs the design - twice now that has been a form-based plan that had to become
something else after the tables were already built.

## Where state can live, in order of preference

**A data table** (`lazysite/db/tables/<name>.yaml` + rows)
: The default for anything a person enters and expects to find again. Declared
  by a descriptor, applied with a migration, read on a page with
  `tt_page_var: items: db:<table>`. Survives devices, browsers and reinstalls,
  and can be read by more than one person.

**A JSON data file in the docroot** (`json:/data/thing.json`)
: For content the *author* edits and visitors only read - a gallery, a price
  list, a set of questions. No write path, no per-user state. Cheap, editable
  in a text editor, and versioned with the site.

**Front matter on the page**
: For one page's own settings. Not for data.

**The browser** (`localStorage`)
: Only for genuinely local preferences - which tab was open, a draft not yet
  submitted. Never for the thing the app is *for*.

## Choosing between a table and a JSON file

The rule in one line: **if the data is written often, or by more than one
person at a time, or must be private, it is a table. If it is written rarely by
an author and only read by visitors, it is a JSON file.**

The storage choice is decided by who writes it and who may read it. The render
cost that looks like it should decide it is a separate question with its own
lever, and it is worth taking that off the table first.

### What a table-backed page costs, and the one line that removes it

A page bound to a table **and carrying no `ttl:`** is re-rendered on every
request. It declares no dependency that could prove a cached copy still current -
a table has no timestamp to compare against - so the engine renders it again
rather than serve something it cannot vouch for.

Measured on edge, median of 15 requests, as the cost **above a plain
cached page**, so network latency is subtracted out. Every page here carries no
`ttl:`:

| Ref | What the page reads | json: | db:, no ttl: |
| --- | --- | --- | --- |
| S-1 | 10 rows | +1 ms | **+159 ms** |
| S-2 | 100 rows | +2 ms | **+190 ms** |
| S-3 | 500 rows | +29 ms | **+202 ms** |
| S-4 | 100 rows of long text | 0 ms | **+163 ms** |
| S-5 | 500 rows, filtered to 125 | +2 ms | **+173 ms** |
| S-6 | a count of 500 rows | +19 ms | **+178 ms** |

**The cost is nearly all fixed.** Going from 10 rows to 500 adds about 40 ms;
simply *having* the binding on an uncached page costs about 160 ms. "It is only
a few rows" is not a defence - what you are paying for is the render, and the
data modules it has to load.

**Filters and indexes do not rescue it.** S-5 filtered 500 rows to 125 in SQL
and still paid the full fixed cost, and an indexed column measured the same as
an unindexed one at this size. Indexing is worth doing for large tables; it does
not make an uncached page cheap.

**The JSON cost tracks the OUTPUT, not the input.** S-3's +29 ms is 500 rows of
HTML going over the wire, not the file being parsed - S-5 reads the same 500-row
file, renders 125 rows, and costs +2 ms. The parse happens once, at render.

### One line of front matter removes all of it

`ttl:` puts the page on the cache's time branch: rendered once, served from
cache until the ttl expires, then rendered again. Same binding, same 100 rows,
the only difference being one line:

| Ref | Page | Cost per request | What a visitor sees |
| --- | --- | --- | --- |
| T-1 | `db:` with no `ttl:` | **+166 ms** | always current |
| T-2 | `db:` with `ttl: 300` | **+3 ms** | up to 5 minutes old |
| T-3 | `json:` (control) | +2 ms | current within the cache's own tracking |

So **the render cost is a freshness choice, not a storage cost.** An uncached
table page buys you rows that are right to the second and charges about 160 ms
of somebody's time for it, on every hit. A ttl buys the cost back and spends
staleness instead.

Choose the ttl from how old the data may be before it misleads someone - not
from how fast you want the page. A price list is fine at `ttl: 3600`. A queue
four people are drawing from is not fine at any ttl, which is why the
reconciliation app renders its rows in the browser instead of binding them.

With a ttl in place the two sources cost the same to read, and the choice
between them comes down to the two questions below.

### Writing

One record changed, median of 5, wall time including network:

| Ref | Dataset | Table write | JSON write |
| --- | --- | --- | --- |
| W-1 | 10 records (0.9 KB) | 678 ms | 303 ms |
| W-2 | 100 records (9.5 KB) | 687 ms | 330 ms |
| W-3 | 500 records (48.6 KB) | 696 ms | 371 ms |

**Read that shape, not those numbers.** A JSON write is cheaper here because it
is a WebDAV PUT against a light endpoint while a row write goes through the
control API - that is the endpoint, not the storage. What matters is the slope:
**the table write is flat in the size of the table, and the JSON write grows
with the size of the file**, because there is no way to change one record in a
JSON file without rewriting all of it. At 500 records the gap is already
closing; at several thousand it inverts and keeps going.

### The two things that decide it more often than speed

**Concurrent writers.** Changing one record in a JSON file means read, modify,
write the whole file. Two people doing that at once lose one of the changes,
silently, and nothing in the mechanism can prevent it. A table writes one row,
and a unique key gives a genuine atomic test-and-set - which is what makes
[handing out work to several people at once](#handing-out-work-to-several-people-at-once)
possible at all. **If two people can write at the same time, it is a table, and
speed does not enter into it.**

**Privacy.** A JSON file in the docroot is fetched by anyone who knows its URL -
this was confirmed by fetching a 49 KB data file anonymously. A table is private
unless its descriptor says `public: true`, and an anonymous request for a
non-public table is refused without confirming it exists.

That cuts both ways, and the second half is a trap: **a `db:` page renders ZERO
rows to a signed-out visitor unless the table is public, with no error on the
page.** A binding resolves as the person requesting it, so a page that looks
right to you while signed in can be empty to everyone else. Test every
table-backed public page signed out before believing it.

### So, in practice

| Ref | The data | Store | Why |
| --- | --- | --- | --- |
| C-1 | A price list, a gallery, a set of questions, a lookup table | **JSON** | Author writes it, visitors read it, cache serves it for nothing |
| C-2 | Anything a visitor or operator submits | **Table** | There is a write path, and it needs to be safe |
| C-3 | A work queue several people draw from | **Table** | Only a unique key makes the claim atomic |
| C-4 | Anything not everyone may see | **Table** | A docroot file has no reader check |
| C-5 | Reference data that changes monthly, on a busy public page | **Either** | Give the page a ttl and both cost the same; decide it on C-2 to C-4 |
| C-6 | Rows that must be right to the second | **Table, no ttl** | The per-request render is exactly what buys that |

C-5 is the case people get wrong, in both directions. Read-mostly data on a
busy page is not a reason to denormalise a table into a JSON file - a ttl
settles the cost. And a table is not automatically the safe choice for data
that must be current: if it must be right to the second for several people at
once, a bound page is the wrong shape whatever its ttl, and the rows should be
read in the browser at the moment they are needed.

## State that only exists in one browser

The most common defect in a prototype, and it is invisible while one person
tests it on one machine.

`localStorage` keeps data in **that browser, on that device, for that origin**.
Clearing site data loses it. A second device never had it. Two family members
each get their own private copy of what looks like a shared record, and neither
can tell.

When you meet a prototype that persists to `localStorage`, the requirement is
almost never "keep using localStorage". It is: *this was always meant to be
shared, and the prototype could not express that.* Say so explicitly rather
than porting the mechanism.

## Declaring a table

Types are `text`, `integer`, `decimal`, `boolean`, `date`, `datetime`, `enum`.
A `decimal` must declare `digits` and `places`; an `enum` must declare `values`.
`key:` names the field that identifies a row - leave it out and the store
assigns an `id`.

```yaml
title: Homework
key: id
public: true          # ONLY needed if ANONYMOUS visitors must see rows
fields:
  child:   { type: enum, values: [sasha, daniel], required: true }
  subject: { type: text, required: true, max: 40 }
  task:    { type: text, max: 300 }
  due:     { type: date }
  done:    { type: boolean, default: false }
```

Then `data-migrate`. Declaring is not creating; the migration is a separate,
deliberate step, and re-running it is safe.

### Things the descriptor cannot yet say

Know these before designing a schema, because each one becomes hand-work:

- **No ordering.** There is no sequence type. An ordered list needs a
  `position` integer you maintain yourself, and inserting in the middle means
  rewriting the ones below.
- **No file or asset reference.** An image is a `text` filename. Nothing checks
  it exists, nothing notices a rename.
- **No list type.** Tags and aliases become a delimited string with a
  convention nothing validates.
- **No relations.** A foreign key is a `text` field and an understanding.
- **Long text and short text are the same type**, so nothing tells a future
  editor to use a textarea.
- **Uniqueness only via `key`.**

## Reading it back

```
tt_page_var:
  items: db:homework sort=due asc limit=50
```

Then loop in the body. `loop.count`, `loop.size`, `loop.first`, `loop.last`,
`loop.prev` and `loop.next` give counters and wrap-around navigation without
storing any of it in the data.

Three properties worth knowing:

- **A `db:` page with no `ttl:` renders per request**, at about 160 ms a hit.
  That is correct for data that changes, and it is a real cost on a heavy page.
  Adding `ttl:` moves the page onto the cache's time branch and the cost goes
  away - see *Choosing between a table and a JSON file*, above, for the numbers
  and for how to pick the ttl.
- **An unpublished table renders nothing to an ANONYMOUS visitor, silently** -
  not the rows, not the fact that it exists - while the API and the manager
  still read it, so the data looks fine and the page looks broken. It renders
  normally for a signed-in user. If a public page shows zero rows, `public:` is
  the first thing to check; if a *gated* page does, it is the read list or the
  page gate, and publishing the table is the wrong fix. See *Two separate
  controls guard a table*, below.
- **Filter in the template, not in the query**, when the count matters. Building
  the filtered list first keeps `loop.size` honest.

### Page bindings filter. The data endpoint does not.

The two read paths do not have the same grammar, and the difference is silent.

| Read path | Filtering |
| --- | --- |
| `db:t(col=v,order=x,limit=n)` in front matter | conditions AND-combine; `.count(col=v)` and `.field(col,key=x)` too |
| `/cgi-bin/lazysite-data.pl?table=t` | `order_by`, `order`, `limit`, `offset` **only** - anything else is IGNORED, and the reply looks exactly like a filtered one |

`data-rows&table=t&chunk=AAA` returns every row including the ones where
`chunk` is not `AAA`. **Never read an unfiltered result as a filtered one.**

So a script that needs a subset reads the whole table and indexes it in memory,
paging at the 500-row ceiling until a page comes back short. At a couple of
thousand rows that is a few requests once per session and it is fine. What you
cannot do is have front matter follow the script: `tt_page_var` has TT markers
stripped, so a binding can never take a query parameter. A page that must show
whichever row the script just picked is a script-driven page, and deciding that
early saves building it twice.

## Changing rows over the API

*Version-dated - this describes behaviour that **differs by engine version**. Check which engine the site runs before acting on it, and compare it with the version this copy was generated for, at the top.*

Reading is `db:` in the page. Writing is the control API, and four of its
conventions cost a round trip each the first time you meet them. Verified
against 0.10.29.

`data-row-save` is BOTH insert and update, and `key` is what decides which
: To ADD a row, omit `key` entirely and carry the key field inside `row`.
  To EDIT one, pass `key` and leave the key field OUT of `row`. Passing `key`
  AND the key field together is refused as `key_immutable` - it reads as an
  attempt to rename a row, which is the one thing a save will not do. Moving a
  row to a new key is a delete and an add.

`data-import` wants multipart, not a body
: The CSV must arrive as a multipart part named `file`. Posting the CSV as a
  raw request body fails validation, whatever the content type says.

`data-import` writes nothing without `apply=1`
: Without it you get a PLAN - `applied: 0`, `inserts: 25`, `ok: true` - in a
  reply otherwise identical to a successful load. A load can look like it
  worked and have done nothing. Read `applied`, not `ok`.

Load a whole table in ONE call, not a per-row loop
: Seeding or importing many rows is one `data-import`, not a `data-row-save` per
  row - a per-row loop is one HTTP round trip each and crawls past a few hundred
  rows (a 140-row table is 140 spawned requests). But mind the shape: on 0.11.1
  `data-import` takes **CSV in a multipart part named `file`** with `apply=1`; a
  JSON body (even the `data-export` object) is refused with "a CSV file is
  required, as the multipart part named file". The token helper `lzs-dav.sh api`
  sends a JSON body and so **cannot** drive `data-import` - reach for a raw
  `curl -K <cred> -F file=@rows.csv '…?action=data-import&table=T&apply=1'`
  (credentials in a `-K` config file, never on the command line).
  `data-export&format=csv` gives the exact column order to fill. Keep per-row
  `data-row-save` for a handful of reference rows; bulk-load anything larger.

`data-table-save` takes the descriptor in a key called `descriptor`
: Not `text`, `yaml`, `content`, `body` or `definition` - each refused with the
  same "descriptor text required". `data-table-source` returns it under
  `descriptor` too, **not** `source`.

`data-table-drop` confirms by NAME, in the BODY
: `confirm` takes the table's own name, not `1` and not `true` - deliberate, so
  a drop cannot be fired by copying another call's confirm flag. It is read
  from the body only. Passing `confirm=<name>` in the query string is ignored
  and returns the same refusal, which reads as the confirmation being rejected
  rather than unread.

Dropping and clearing up after it are three different grants
: Dropping writes every row to `lazysite/db/rebuilds/<table>-dropped-<ts>.json`
  first, so a drop is recoverable. The three steps are gated separately:
  `manage_data` lists the exports, **`housekeeping`** performs the drop, and
  **`purge`** deletes the export - which is what makes the drop permanent.
  A grant with `manage_data` alone can neither drop nor tidy; one with
  `housekeeping` but not `purge` can drop and then cannot remove the file its
  own drop created. Check which of the three you hold before planning a
  clear-up, and say what you are leaving behind when you hand over.

Two properties of these that are easy to misread:

- **Where the table name rides differs per action.** `data-migrate` and
  `data-import` read it from the query only. `data-row-save`, `data-row-delete`,
  `data-rebuild`, `data-table-save` and `data-table-drop` accept it in the query
  OR the body, query winning. If a call is being ignored, check you put the
  table where that action looks.
- **The refusals teach.** Each of the above names the rule it enforced and, in
  the drop's case, quotes the exact confirm string back. Read the error before
  assuming a missing capability - three times now I have chased a "missing"
  capability that was one wrong spelling of a parameter.

## Identity, and who may see what

An app usually has to answer "who is this?" before it can answer anything else.

- `auth: required` on a page, `auth_groups:` to name who
- ACLs gate a whole section: `acl-set` with the **path in the query and the
  lists in the body**. Gated content moves to a private store
- An owner with **no read list leaves reading open** - that governs writes only
- **Verify a permission with an unauthenticated fetch**, never with the API's
  own success reply

### Two separate controls guard a table, and this is the shape a gated app wants

Confirmed with the engine side 2026-08-24, and it is not obvious from the flag's
name:

- **`public:` answers one question only - may an ANONYMOUS visitor see these
  rows?** Default no.
- **The ACL read list on `lazysite/db/tables/<name>`** answers which named
  accounts or groups may.

So **an unpublished table renders normally for a signed-in user.** Authenticated-
only rendering is the *default state* of a table, not something to arrange. The
render path carries the real visitor, never an operator, so a page shows the
same rows to whoever is looking.

For an app whose data should never be public:

1. Leave `public:` off - anonymous readers get nothing, not even the table's
   existence.
2. Put a read list on `lazysite/db/tables/<name>` naming the users or group.
3. Gate the pages too.

ACL lookup is **longest-prefix**, so one rule on `lazysite/db/tables` governs
every table at once if a site-wide default is what you want.

**Do not reach for `public: true` to make a gated page work.** If rows are not
appearing for a signed-in user, the read list or the page gate is the cause, and
publishing the table would fix the symptom by removing the protection.

For a family app, expect at least three roles and design for them from the
start: an adult who administers, an adult who participates, and a child who
sees their own things and not their sibling's. A fourth is common - a person
who appears in the data but never signs in (a grandparent, a coach).

## One group, and exactly what it needs

A gated app usually wants **one group**, not a hierarchy. Ours is
`stock-admin`, and working out what to put in it took longer than it should.

**`manage_data`, and nothing else.** A write through the data endpoint needs
all three of a signed-in session, `manage_data`, and membership of the table's
`writable_by` if it names any. `writable_by` can only ever TAKE write access
away - it cannot grant a write to an account without the capability - so it is
not a substitute, and a group with the name and not the capability looks
correct until somebody presses Save.

Four things that are easy to get wrong:

**Do not grant `ui`.** That is what injects the admin bar on site pages, and on
an app page its Edit link opens the Markdown of a page whose body is a script -
the most destructive action available, offered as the most prominent one. It is
per-user with no per-page control, so the only way to keep it off an
application is to keep the capability off the people using it.

**`webdav` / `api` / `mcp` are for partner tokens.** A person signing in with a
browser cookie does not use them, and granting them to a human group grants
nothing and confuses the next reader.

**`@group` in an ACL matches only signed-in browser users.** Token, MCP and
WebDAV partners carry no groups, so an agent that must keep working has to be
named in the list explicitly. `acl-set` warns about this and the warning is
easy to skim past.

**Name a group you are in on `writable_by` while you are still building.** The
office group may not exist yet, and a descriptor naming only it locks the
loader out of its own tables. Add the build agent's group, and put a comment in
the descriptor saying to remove it at handover.

Beyond that, do not split rights the app does not split. An earlier draft here
had a second group for corrections because they were going to happen in the
manager row editor. Once corrections moved onto the app's own pages, the second
group had nothing to do.

## Forms are how people put data in

A person in a browser cannot call the control API, so a form is the only way
they write anything. Three properties decide the design.

**There is a `db` form handler** - *"Store in a data table"*. It takes a table
and a **required** `form field=column` mapping. Values are checked against the
declared types, so a submission that does not fit is **refused and the visitor
told**, rather than thanked and stored wrong. Fields nobody maps are **dropped**,
so a form gaining a field cannot start writing a column on its own.

**A form can dispatch to several handlers at once** - a file record and a table
row from one submission, if both are wanted.

**Forms only ever INSERT.** The db target inserts and has no update branch, so a
submission carrying an existing key is refused on the unique key rather than
superseding the row. A form is a **capture** surface, never an edit surface.
Corrections travel by the manager row editor, a CSV round trip, or an API row
update; `save_data_row` **with** a key updates in place.

**So design the capture surface and the correction surface separately.** They
are not the same surface and they do not want the same shape: a guided form is
right for entering a hundred things with their context in front of you, and
wrong for fixing one of them. A row editor is the reverse.

### When an app may skip the forms system entirely

**A custom data app may write to its tables directly from its own page script,
through `/cgi-bin/lazysite-data.pl`.** Operator's ruling, 2026-08-25, on the
jpm-stock corrections build. It is an exception to "forms are native and
hand-written form markup is not acceptable", and it is narrow.

The endpoint takes `GET ?table=t` to read, `GET ?csrf=1` for a token, and
`POST ?table=t` with `X-CSRF-Token` carrying `{"row":{...}}` to insert,
`{"key":"...","row":{...}}` to update, `{"key":"...","delete":1}` to remove.
A write needs all three of a signed-in **session** (a partner token is not
one - the endpoint answers `not signed in`), the `manage_data` capability, and
membership of `writable_by` if the descriptor names any. It applies the same
type checks as any other write.

Take the exception when **all** of these hold:

- The interaction is **not a submission**. Claiming an item, resuming one,
  amending an answer and releasing a lock are updates and deletes of an
  existing row. A form only ever inserts and cannot express any of them.
- The page must **read state to decide what to show** - which item this person
  holds, what they answered last. A form cannot read.
- Everyone using it is **signed in and named**. The protections a form
  provides - rate limits, spam assessment, quarantine, a handler vetting an
  untrusted submission - all defend against anonymous visitors. Against four
  known colleagues they defend against nothing.

Stay with a native form when any of them fails, and **always** when the writer
could be a member of the public. A contact form, a booking, a sign-up: those
are submissions from strangers and the forms system exists for exactly them.

Two things the exception costs, both of which want handling rather than
accepting:

- **No JSONL submission store**, so no append-only record. Add a log table the
  script appends to on every write. It records what the page did and nothing
  else, so a correction made in the manager UI or over the API leaves a trail
  that looks complete and is not - which means the app's own correction path
  has to be the one people use.
- **No `create_form` to generate the markup**, so the control is yours to
  build and yours to keep accessible.

Say in the app's own docs that it took this exception and why. The next
session will otherwise read the hand-built control as a rule being broken.

**Watch for a design that only exists because the old store could not be
edited.** Append-only files force "write again, latest wins" and it looks like a
requirement long after it has stopped being one. Given a table, the correction
is an update, the superseding rule disappears from both ends, and so does the
risk of a partial re-submission blanking what it did not re-state. Ask what a
rule is protecting against before porting it.

**Creating or editing a handler is an operator action.** `lazysite/forms/handlers.conf`
is denied to every partner grant, so a build plan that needs a new handler has an
operator step in it. Say so up front rather than discovering it at kick-off.

### One submission is one row

The trap. A form maps **fields to columns**, so one submission becomes one
**record**. That is right when one form means one thing - a contact message, one
answer, one booking.

It breaks when a page collects many things at once. A form with forty-five
question fields cannot become forty-five rows; it becomes one row forty-five
columns wide, and that table changes shape every time the questions change,
which means it is a spreadsheet rather than a table.

When capture and storage disagree on shape, the honest options are:

- **one form per record** - clean, but check the page can carry more than one
  form, and that the record's identity can travel with it (there is **no hidden
  or fixed field type**, so a constant cannot simply be attached)
- **capture to the file handler and load into the table** as a separate step -
  keeps the append-only record as an audit trail and rests on nothing exotic
- never a column per question

### Two limits worth designing around

**Submissions must arrive between 3 seconds and 2 hours after the page
rendered** - an HMAC timestamp token, and unlike the rate limit it is not
configurable per form. Any long data-entry page, or one left open over a lunch
break, will cross it and the person loses what they typed. Design for **partial
submission**, keep pages short, and put "submit as you go" in the on-page
guidance rather than in a briefing nobody re-reads.

**Rate limiting is five submissions per IP per hour** by default, which is right
for a public contact form and wrong for a team working through data-entry pages
from one office address. From SM425 a submission whose **session cookie
verifies** bypasses the anonymous limit, so a signed-in team needs no tuning -
check the deployed build before reaching for `rate_limit: off`, which remains
the mechanism for forms that are open but protected another way.

**Wiring a native form needs a one-time operator step.** A token holding
`manage_forms` still cannot create the delivery handler: `handler-save` (and
`plugin-read`/`plugin-save`) are manager-UI / cookie-session only, and
`lazysite/forms/handlers.conf` is protected against WebDAV writes even with
`manage_config`. An agent CAN write the form config `lazysite/forms/<name>.conf`
(with `manage_config`) and create the target data table (`manage_data`) in
advance - but the operator must add the handler on the Forms page once. Plan for
that step, or use an editable gated page (an admins-group member answers inline;
the build reads it back) as the collaboration channel, which needs no handler.

## Importing from a feed

When rows arrive from another system on a cycle:

- **Upsert by a stable business key**, never by position.
- **Do not delete rows that stopped appearing.** Mark them resolved or archived.
  A deleted parent orphans whatever referenced it and destroys the record of
  what was once asked.
- **Keep one copy of the truth.** Once a feed file is loaded, it should not also
  sit in the docroot where a page could read it - two sources disagree
  eventually, and the one nobody is watching wins.
- Carry the source system's ordering in a `position` column, because tables have
  no order of their own, and do not re-sort it if that ordering is somebody
  else's decision.

## Identifiers must not be positional

If a checkbox is keyed `child:hw0` - child plus the *index* of the item in a
list - then deleting or reordering the list silently transfers the tick to a
different task. The same applies to any state stored beside a list rather than
in it.

**Give every row a stable key and store state against it.** Where a prototype
uses positional ids, that is a defect to fix in the port, not a pattern to
carry over.

## Workflow: the shape most family and team apps take

Nearly all of them are the same four movements. Naming them early makes the
schema obvious:

1. **Capture** - something arrives: typed, dictated, photographed, imported.
2. **Structure** - it becomes rows: a task with a date, a mark with a subject.
3. **Act** - somebody ticks, assigns, reorders, completes.
4. **Reflect** - a view that shows what happened and what is next.

Capture is where prototypes are strongest and production is weakest, because
capture is the part that needs a person's context. Be careful promising
automatic structuring of free text; specify what happens when it gets it wrong.

## Handing out work to several people at once

The moment more than one person works a shared list, the app has to answer:
who has this item, and how does nobody else get given it?

**The unique key on a table is an atomic test-and-set, and it is the whole
answer.** Claiming an item is INSERTING its row. A second insert carrying the
same key is refused on the unique constraint, so two people claiming at the
same instant produce one success and one refusal.

```
claim(item):
  insert {key: item.id, allocated_to: me, allocated_at: now}
  refused? somebody beat me to it - reload, take the next, retry (bounded)
```

There is no window between checking and taking, **because there is no check**.
The obvious alternative is the broken one:

> read the table, pick a free item, write it back

Two people who read before either writes both see it free, and both take it.
That code passes every test you will run alone.

Three things the design needs beyond the lock:

**One row, not two.** Keep the claim and the result in the SAME row, keyed on
the item. Its existence is the allocation and its answer field is the outcome:
no row means free, a row with no answer means somebody is on it, a row with an
answer means done. A separate allocation table needs the two kept in step, and
they will not be.

**Claims must expire.** Somebody will close the tab, or go home mid-item.
Without an expiry that item is allocated forever and no one can reach it. Pick
a span longer than a working session and shorter than a day, decide it from
the timestamp at read time, and take an expired claim by deleting the stale row
and inserting fresh - so the unique key keeps doing the locking.

**Give a person their own item back.** On arrival, look for a row allocated to
this person with no answer, and resume it before handing out anything new.
Otherwise someone who reloads collects a second item and strands the first.

**Let anyone release.** Own claims release without ceremony; someone else's
should ask first and name them. Colleagues sharing a queue need to free an item
when a person is off sick, and they should not be able to do it by mis-clicking.

## A stop action must actually stop

Both mine did the opposite, and it is an easy shape to write by accident: a
handler that finishes its job and then calls the same "what next" routine
everything else calls. So *put this back* released the item and immediately
claimed another one - the single action that means "I am leaving" handed the
person more work.

**Name the buttons for what they do to the SESSION, not to the record.** *Save
and take the next*, *Save and stop*, *Put back and stop*. Then make each one
end where its name says.

And where an action navigates away, **await the audit write before leaving**.
Fire-and-forget is right for a log everywhere else - a failing trail should
never block someone's work - but a request in flight when the page unloads is
cancelled, so the one action you most want a record of is the one that leaves
none.

## Exact totals need integer arithmetic

Any app where entered numbers must add up to a stated figure - allocations,
splits, invoice lines, stock quantities - must not compare them as floats.
`0.1 + 0.2` is not `0.3`, and a screen whose entire purpose is making a total
match will refuse a total that is visibly correct.

**Multiply into the smallest unit and compare integers.** Tenths for a quantity
to one place, pence for money. Convert once at the edge, compare in the middle,
format on the way out.

Say which way the total is wrong, too. *40.0 still to allocate* and *over by
2.5* are actionable; *does not match* means counting on your fingers.

## Start from the record, not from a blank form

When an app exists to CORRECT existing data, pre-fill what the system already
believes and let the person change it. The common case is that the record is
right - the exercise is finding where it is not - so confirming should cost a
glance and only a disagreement should cost typing.

Two conditions. Say on the page where the pre-filled value came from, or it
reads as a suggestion the app invented rather than the thing under review. And
fill only when there is no answer yet, so re-opening something already answered
shows what was saved and never quietly overwrites it.

The cost is that Save is valid the moment the page loads, so a distracted
person can confirm without reading. That is a real trade and worth naming to
whoever asked for the app rather than deciding it quietly.

## Where the intelligence runs

A prototype may call a model directly from the browser. A deployed app cannot:
the key would be in the page. Any model call belongs behind the server, with:

- a defined **input** (what text or image is sent) and **output** (a schema you
  validate, not prose you parse)
- an explicit answer to **what happens when it returns nothing useful**
- a **person in the loop** for anything that becomes a record - suggestions
  should be offered and accepted, never written straight in
- a note in the specification about **what leaves the building**, because
  family and pupil data going to a third party is a decision the client makes,
  not a detail

## Scheduling

Anything recurring lives **in the stack**, not in host cron - a sidecar or an
in-process timer that ships with the app. A schedule the operator has to
remember to install is a schedule that will be missing after the next move.

## Widen the page, do not break out of it

An app screen is usually wider than the prose column a site layout is built
for. The reflex is to break the content out - `margin-left:50%` with a
`translateX(-50%)` - and it works, for exactly the element you apply it to.

**Everything around it stays behind.** The site bar, the nav and the footer
keep the old width, so the page reads as a wide table wearing a narrow hat.
That is worse than the narrow table you started with, and it looks like a bug
because it is one.

The shipped chrome caps the page with `body { max-width: 800px }`. **Raise that
instead**, from the page's own stylesheet - a page can style `body` like any
other element, and it only affects that page:

```css
body { max-width: min(1400px, calc(100vw - 2rem)); }
```

Then the bar, the nav, the content and the footer are one column again and all
of them flow together. Pick ONE width for the whole section, or the header
shifts as somebody moves between pages.

Having done that, keep the prose narrow inside it. A table may use the full
width; a paragraph at 1400px is unreadable:

```css
.head, .sub, .caption, label, textarea, .msg { max-width: 62rem; }
```

And size the columns rather than hoping. A column with no width of its own
gives its space to whichever column carries the most words - a three-digit
number will wrap onto two lines next to a sentence. `width:1%` with
`white-space:nowrap` is the shrink-to-fit idiom: the cell gets exactly what its
content needs. Give the prose column the slack, and keep a horizontal
`overflow-x:auto` container around the table for the narrow-screen case.

## Borrowing a theme

A gated app should not look like the public site, and it does not need a theme
of its own to manage. **Take the palette and the conventions from an existing
theme and put them in the page**, scoped to the app's own container.

Ours came from a documented intranet theme: quiet greys, a dark bar along the
top, dense tables with small-caps headers. What made it worth borrowing was the
description rather than the colours - *a working surface, not a shop window* -
which decides a hundred small questions the same way.

Two things carry the signal on their own. A **dark bar** across the top says
which side of the gate you are on before anything is read, and it does it
without a label - the "Private" chip we put in it was telling signed-in staff
what the login had already told them. And **dense rows with quiet rules**: a
data-entry screen is read by someone comparing it against paper, not browsing.

## Before calling an app done

- Two devices, two people, one record: does an edit by one appear for the other?
- Sign out: is anything visible that should not be?
- A child's login: can they reach a sibling's data by editing the URL?
- Delete a row referenced elsewhere: what happens to the thing pointing at it?
- Clear browser storage: does the app still know everything it should?
- Restore from backup: is the data really in the store, or only in a page?
- **Two people, one item, at the same moment**: does one of them get refused?
  No single tester reproduces this, so say plainly that it is untested if
  nobody has tried it in pairs.
- Every action that ends a session: does it end where its name says?
- A total that must match: does 0.1 + 0.2 pass?

## Reading a client's prototype

A prototype is a **requirement expressed in the only language available**, not
a design to copy. Extract, in this order:

1. **The data** - every list, constant and record in the source. This is the
   schema, whether or not it is declared.
2. **The computations** - averages, roll-ups, groupings. These are business
   rules and they are usually written down nowhere else.
3. **The vocabulary** - the client's own words for things. Keep them exactly;
   they are the domain language and renaming them loses meaning.
4. **The interactions** - what is clickable, what persists, what is only
   visual.
5. **What is defined but never shown.** Dead constants are almost always an
   intention that ran out of time, and they belong in the requirements as a
   question rather than being silently dropped or silently built.

Then state plainly what the prototype could not express: sharing, permissions,
history, backup, what happens when two people edit at once.

## Where this came from

Imported on **2026-08-28** by `tools/import-field-practice.pl`, for the engine version stamped at the top of this page. Written by **the lazysite site agent (Claude Code)** - the agent that builds and maintains sites on this engine - as a working record, and kept current in its own project trees:

| Source | Covers | Last changed |
| --- | --- | --- |
| `/srv/projects/lazysite-sites/AUTHORING-PRACTICE.md` | sites and content | 2026-08-28 |
| `/srv/projects/lazysite-apps/APP-PRACTICE.md` | apps and data | 2026-08-28 |

Those paths are on the site agent's own machine and are **not** part of this engine. **Updates come from re-running the import**, which happens when a release is cut; a sysop can also run it between releases. Nothing you edit on this page survives the next import, and the engine's own test suite fails the build if this copy stops matching its sources - so a correction belongs in the source files, not here.

If you have found something durable that is missing - a mechanism worth reaching for, a trap worth naming, a measurement worth keeping - send it to the sysop for the source files rather than adding it to the site.
