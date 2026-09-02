# Authoring practice on lazysite

**Companion to `CLAUDE.md` in this tree. Read both before building a site.**

The purpose of everything below is one thing: **a site should stay maintainable
by someone who has only a text editor and the site itself** - no build step, no
generator, no local toolchain, no knowledge that lives only in a past
conversation. That applies equally to a human picking it up in a year and to an
agent picking it up in the next session.

The test to apply to any decision:

> If I disappeared, and the client wanted to change a title, add a work, or
> restyle the site, could they do it by editing one obvious file?

If the answer needs a script that lives on my machine, the design is wrong.

This is a living document. When a session teaches something durable, add it
here (see *Keeping this current*, at the end).

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

**Two traps live specifically in a `<script>` block, and both bite silently.**

**A literal `[%` anywhere in page JS is read as a directive open** - even one you
never meant as TT: a regex like `/\[%|%\]/`, a string, a comment. TT scans the
rendered HTML for `[%` and swallows everything up to the next `%]`, blanking a
span (and, from 0.11.10, refusing the write if the body no longer parses -
though only on the manager/MCP path; a WebDAV PUT still ships the broken page).
Keep TT tokens out of `<script>`. Where you need to test a value for an
un-interpolated token, use the TT-safe idiom `/%\]/` - the `\` stops `%]` from
forming a close tag and there is no `[%` at all - never `/\[%.../`, which *is*
the footgun.

**Never interpolate an auth variable into a `<script>`.** From 0.11.9 (SM709) the
engine entity-escapes `auth_user` / `auth_name` / `auth_email` / `auth_groups`
where they enter the render. A browser decodes no HTML entities inside
`<script>`, so an escaped value arrives as **literal entity text** - a name like
`O'Brien` shows as `O&#39;Brien`, and adding `| html` makes it `O&amp;#39;Brien`.
No filter is right there. Carry the value on a hidden element's `data-` attribute
and read it with `getAttribute` - an attribute **does** decode entities, so the
apostrophe comes back intact. Bare `[% auth_name %]` in the attribute, no filter:

```html
<span id="me" hidden data-login="[% auth_user %]" data-name="[% auth_name %]"></span>
<script>
  var el = document.getElementById("me");
  var me = { login: el.getAttribute("data-login"), name: el.getAttribute("data-name") };
</script>
```

This is why an app renders identity onto the page, never into a script string -
see `/srv/projects/lazysite-apps/APP-PRACTICE.md`, *Identity*.

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

Keep the style guide as a single **monolithic file** - every component and every
state in one place - rather than composed from partials or `::: include`s. This is
the deliberate exception to normal content composition: the whole point of the
guide is discovery, and one file is the surface where an author or the design side
finds everything at a glance. Splitting it across partials would scatter the
components and defeat the contract. (It is still authored as one bare `.html` so
indented markup is not mangled by the Markdown processor - monolith, not fragments.)

### Other things worth remembering

- `aliases:` - every retired URL gets one on its successor at conversion
- `register:` - what appears in `sitemap.xml` / `llms.txt`
- `.url` files - a page that is a redirect
- Native forms - `create_form` or a `:::form` bound to a vetted handler, never
  hand-written form HTML or a third-party service

## Briefs: stop writing sidecars from 0.10.29

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

**A data ROW takes one too (SM657, 0.11.4).** A row has no path, so it is named
rather than pathed: `type=row`, `table=NAME`, `key=KEY` in place of `path`, on
`brief-read` and `brief-append` alike. That is the object that most needed it -
on a data-driven site a row IS the content, and it was the only content object
with nowhere to record why it is as it is. `table` and `key` are single opaque
segments; neither may contain a slash.

Typed entries list and delete exactly like any other brief - the condition for
adding them at all, since rows are deleted constantly and a brief that could not
be listed or cleared would leave one invisible orphan per deleted row. In
`briefs-list` a typed entry carries its `type` and reports `orphan` as `null`
(unknown) rather than guessing: the key is present with a null value, a third
state distinct from `false` (a live file) and `true` (an orphan), because its
liveness is a question about the row, not about a file on disk.

Still not keyed: anything under `lazysite/db/` (blocked), and `type=table` - a
table's intent already survives as comments in its descriptor, verbatim through a
round trip, so it is the weaker half and is not built.

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

One site writes a three-number stats panel as 24 lines of hand HTML with an
inline `style` hack. Another renders the same shape from a 9-line component fed
by a list. Same engine, same week.

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

## Keeping this current

Add to this file when a session produces something durable: a mechanism worth
reaching for, a trap worth naming, a measurement worth keeping. Prefer a short
entry with the evidence over a long explanation. If something here turns out to
be wrong, correct it in place and say so - a stale line here is worse than no
line, because it will be trusted.

Related: `CLAUDE.md` in this tree (how we work, per-site conventions), and the
site briefings published on every lazysite instance at `/docs/`.
