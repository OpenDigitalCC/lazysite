# The app foundation: from a visual prototype to an integrated app

This is the foundational approach for building an application on lazysite. It is
not an optional refinement or an addendum to `APP-PRACTICE.md` - it is the shape
every app build takes. `APP-PRACTICE.md` is the detailed platform how-to; this
is the method those details serve.

The one-line statement: **ingest from whatever produces the visual prototype,
expand it into a full specification with the user, then apply it as separated
parts.** It works the same whether the visual came from Figma, Claude Design, a
screenshot, or a hand-built HTML mockup - the source is just an input.

There is an experimental machine-readable form of this: `PROTOTYPE-TARGET.md`, a
reference architecture the *upstream* design AI develops the app INTO, so that
ingesting it here is mechanical. This document is the human method; that one is
the target the method is converging on. Use it when you want the design tool to
hand over a structured bundle rather than a prototype to read.

## The problem it exists to prevent

A design tool produces a visual - very often a single self-contained HTML
artifact - and it gets dropped onto the platform as if it were static hosting.
Styling, data and structure arrive fused into one page. The result cannot be
themed, cannot be bound to real data, cannot be extended, and the next agent to
touch it writes another monolith beside it. We build the opposite: the visual is
an **input**, not the deliverable; it is taken apart and rebuilt as parts that
are each independently correct.

## The pipeline

Three stages, always in this order:

```
   INGEST  ->  EXPAND (with the user)  ->  APPLY as parts
  the visual     the full spec          schema | design system
   prototype   + open questions        | style guide | protected
                                         files | pages | intranet
```

The stages are tool-agnostic. Everything tool-specific lives in Stage 1; from
Stage 2 on, the process is identical no matter what drew the picture.

---

## Stage 1 - Ingest the visual prototype

The prototype is the authority on the **look** and the intended **behaviour** -
never the authority on the implementation. Read it for six things: the
views/screens, every component and its states, the design tokens (colour, type,
spacing, radius), the exact wording, the data it implies, and the rules and
arithmetic it encodes.

**Separate the logic from the pixels.** A saved artifact usually does not execute
its own logic - a Claude Design `.dc.html` keeps its behaviour in a script block
the browser never runs; a Figma prototype's interactions are not code; a
screenshot is pixels only. Find where the arithmetic, labels, sort orders and
colour rules actually live and treat THAT as the behaviour authority, and the
rendered image as the look authority. When they disagree, say so.

**By source, you are extracting the same things:**

- **Figma** - frames are screens/views; components and variants are the
  component catalogue and its states; the token/styles panel is the design
  tokens; auto-layout hints at structure. Behaviour is in the annotations and
  the prototype links, not in runnable code, so the data model and rules come
  from reading the design plus the user.
- **Claude Design (`.dc.html`)** - the rendered body is the look; the
  `x-dc`/logic block is the behaviour authority (arithmetic, labels, states);
  the `.dc_files`/runtime is disposable. Export screenshots of every screen,
  because the saved body often holds only the one screen that was open.
- **Screenshots / an HTML mockup** - pixels and, in a mockup, markup + inline
  styles. Treat inline styles as tokens to name, not styles to keep.

Ingesting a large or messy prototype is a job to hand to a dedicated pass (a
subagent), whose output is the raw material for Stage 2, so the bulk reading
does not crowd out the judgement.

---

## Stage 2 - Expand to a full specification, with the user

The prototype is never a complete spec. Expand it into three artifacts and one
conversation:

1. **A design-system catalogue.** Every token with a name; every component with
   its DOM sketch, its class name, and every state; the shell; and the
   colour-is-data mechanism (a person/entity tint reaches an element as
   `style="--who:#hex"` and classes consume `var(--who)`, so the palette lives
   in data, not the stylesheet). This becomes the design contract.
2. **A data model.** The tables, keys, types, relationships, and the rules and
   arithmetic - read out of the prototype's logic. Name what a table descriptor
   cannot express (relations, lists, ordering, joins) and how you carry it
   instead.
3. **Open questions, put to the user.** Anything the prototype leaves genuinely
   open - identity, retention, scope, a rule the code and the design disagree
   on. Do not absorb these silently; surface them and let the user answer. Some
   are load-bearing on the schema and block Stage 3 until answered.

**Reconcile multiple and newer inputs.** Prototypes iterate; a client sends v8,
v9, a written spec, a later artifact. A rejected experimental branch is not the
target however new its timestamp - the latest *coherent* artifact plus any
written spec settle the direction. Where a spec lags a decision the user already
made, keep the decision and tell them the spec is behind it. Diff the versions;
write down what actually changed and what its impact is (schema / design /
wording / none).

**Core stable, edge flexible.** Fix the core entities and keys; let peripheral
membership and provenance data flex in rows rather than in the schema, so a
"which set?" question is a row edit, not a migration.

The output of Stage 2 is a spec solid enough that Stage 3 is assembly.

---

## Stage 3 - Apply as separated parts

The heart of the method: the three kinds of input **never fuse**. Data lives in
the schema, the look lives in the theme's classes, and structure lives in the
pages - and they are built in dependency order, each finished and gated before
the next relies on it.

### Part 0 - Where it lives: one protected folder per app

For an intranet or a predominantly non-public app, decide the location before the
first file: build the whole app INSIDE one protected folder, from the start - do
not build in the docroot and gate afterwards. The docroot keeps only what must be
public - login, `/forgot`, `/robots.txt`, the shared `/assets/app` JS. Everything
else is born inside the app's folder, so a new file is protected the moment it
exists rather than public until someone remembers to gate it. One folder per app
also lets separate apps carry separate permissions (a different group per
folder). This is the structural half of leak-prevention; the gating mechanism is
the other half, and the two mechanisms are NOT interchangeable:

- **Gate pages at render time** (`auth: required` or a `@group` in front matter).
  The source stays in the docroot, so `::: include` still resolves its partials;
  anonymous gets a 302.
- **`acl-set` MOVES a folder into the private store**, and the `::: include`
  resolver reads the docroot - so acl-gating a folder of include targets (a
  `/partials`) blank-renders every page that includes from it (the body collapses
  to an `include-error`; a stale cache hides it until re-render, when it looks
  like "all pages broke"). Reserve `acl-set` for leaf content nothing includes
  (see Part 4).
- **Protect a partial itself by writing it as `.md` with `auth: required`** (not
  a bare `.html`). On include the front matter is stripped and the HTML body
  inserted unmangled (scripts and indentation intact); a direct GET of the
  partial's path is gated (302). That keeps every include-target private with no
  `acl-set` move - the include still resolves. Keep bare `.html` includes only
  for genuinely public partials.

### Part 1 - The data schema, first

The data contract is the most expensive thing to change once pages read it, so
it is settled first. Declare every table by descriptor and migrate it; prove a
full read/write round-trip (create -> read -> update -> delete) before any page
exists. Platform specifics that bite: send decimals as strings, never key a
tickable thing by position, carry text foreign keys on every table you filter
by, keep tables private by default, and name the writing groups in
`writable_by`. Seed the stable reference data (the entity palette, the fixed
lists) here. A schema built this way can be exercised entirely over the control
API, before any user account exists.

### Part 2 - The design system (separation of inputs)

Extract the WHOLE class vocabulary from the Stage-2 catalogue and build it into
ONE theme and ONE layout. The theme holds every class the app will ever use; the
layout holds the shell. Colour is data via `--who`. From here on, **no page ever
carries its own styling** - the ONLY inline style permitted is the `--who` data
hook. This is the separation that makes everything downstream mechanical: a page
is structure + a class name + a data binding, and can introduce neither a new
style nor a new type without that being a gap to fix in Part 1 or Part 2.

### Part 3 - The internal style guide, with every element

Build one page - `/style-guide` - that renders EVERY visual element the app
uses, with test content, in every state. It is:

- **complete** - if an element renders anywhere in the app, it renders here;
- **the single control point for the look** - styling is reviewed and adjusted
  here, between this page, the layout and the theme, and NEVER on a content
  page. This is where the user signs off the design;
- **the standing rule** - any new element is prototyped here first, then used;
- **the fence against the monolith** - a later agent building a new page reuses
  a catalogued class instead of dumping a bespoke block, because the element it
  needs already exists, named and styled.

Author it as an included bare `.html` partial so its indented markup is not
mangled by the Markdown processor. Establish it before the first real page and
get the user's sign-off there - that sign-off is the design contract for
everything that follows.

### Part 4 - Protected files

Real content - photos, uploads, scans, exports - must not sit on a public asset
path. Gate the media subpath with a longest-prefix ACL (`read:[@group,...]`) so
just that subpath moves to the private store while the rest of the public assets
(the app's own JS/CSS) stay public. Set the ACL before publishing so content
lands protected. Prove the gating per build with an anonymous request - a gated
image must be refused, not served byte-identical. The layout then serves those
files to a signed-in group member only.

### Part 5 - The pages, mechanical

Each page is front matter + structure in catalogued classes + a data binding,
gated with `auth: required`. Reads and writes go through one shared browser data
module against the platform's data endpoint (fetch, a CSRF token per write with
one retry, an in-memory index, and the client-side entity filter), reused by
every view. Writes are reversible and attributed (dated `done_by`/`done_at`,
never keyed by position). Build the reference view first to prove the whole
pipeline end to end; the rest follow the same pattern and add no design
decisions. Where the write path needs a signed-in session that does not exist
yet, build it and mark it "built, not proved" until a test account exists -
the read/render/structure is verifiable without one by temporarily un-gating a
scaffold.

### Part 6 - The project intranet (running throughout)

Give the build its own gated area on the site itself - a `/team/` section ACL'd
to an admins group - holding the plan, the settled decisions, the build method,
and a questions page for the things only the user/client can answer. Carry a
brief on each app page (its purpose and rules, out of band). This travels with
the site, so a new collaborator - the operator, another agent, the client's own
builder - picks the work up without re-deriving it. It is the project's own
intranet, distinct from the app the end users see, and it is what makes a clean
hand-over possible.

---

## Why it is tool-agnostic

Figma, Claude Design, a screenshot, a hand-built HTML mockup - each produces a
visual and, sometimes, a logic authority. Both feed Stage 1 and nothing else.
The catalogue, the data model, the schema, the theme, the style guide, the
protected files, the pages and the intranet are identical no matter what drew
the picture. The tool's job ends at "here is the look"; this method's job is to
turn that into an integrated, themeable, data-bound, extensible app.

## The payoff

Once the schema, the design system and the style guide have passed their gates,
every further page is straightforward and looks right for free. The client can
add a view later without touching design. And what is handed over is a finished,
integrated application - not a monolith that only its author can change.
