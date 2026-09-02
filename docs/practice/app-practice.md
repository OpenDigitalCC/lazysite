# Building apps on lazysite

**Companion to `/srv/projects/lazysite-sites/AUTHORING-PRACTICE.md`.** That file
is about pages: content, layout, theme, HTML and styling. This one is about
**apps**: workflow, where state lives, how data is stored and read back, who is
allowed to see it, and what has to be true before a person can rely on it.

Read both. A lazysite app is a site with a data store and a notion of who is
looking, so everything in the authoring practice still applies.

**Start with `APP-FOUNDATION.md`.** It is the foundational approach every app
build follows - ingest whatever produced the visual prototype (Figma, Claude
Design, a screenshot, an HTML mockup), expand it into a full spec with the user,
then apply it as separated parts (schema, design system, style guide, protected
files, pages, project intranet). This document is the detailed platform how-to
that those parts are built with; read the foundation first for the shape, then
this for the specifics.

This is a living document. Add to it when a build teaches something durable;
correct it in place when something proves wrong.

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

## Three things gate the first write - settle them before kick-off

A data app was blocked at step zero three separate ways, each an operator action
a partner token cannot take:

- **Token exchange may be disabled** on the instance (`service_disabled`), so the
  agent cannot even get a token.
- **`manage_data` may be absent** - and the partner brief is a stale snapshot
  (it advertised six capabilities where the server granted fourteen). Trust
  `describe-capabilities` / `whoami`, never the brief.
- **The data plugin ships disabled** and can only be enabled from the manager
  UI - so an account holding `manage_config` still cannot switch on the plugin
  it was provisioned for.

Provision a build with all three settled, or say up front that an operator step
stands between the plan and the first write.

## What the build agent cannot prove, and must say so

The data endpoint answers `{"ok":0,"error":"not signed in"}` to a **partner
token** - only a browser cookie session reaches it. So the agent that builds the
app **cannot execute a single write path** (claim, save, amend, release) and
**cannot exercise a binding against a private table** from its own credentials;
all of it runs as a human, or not at all before hand-over. And the
claim/allocation race needs two people clicking in the same instant - a green
run by one tester is not evidence about it. State both plainly at hand-over
rather than letting them read as tested. (This is why the author of a data app
often never sees it render with real data.)

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

```datatable
columns: Ref | What the page reads | json: | db:, no ttl:
widths: 1.4cm | X | 3.0cm | 3.0cm
bold: 1
tone: medium
---
S-1 | 10 rows | +1 ms | **+159 ms**
S-2 | 100 rows | +2 ms | **+190 ms**
S-3 | 500 rows | +29 ms | **+202 ms**
S-4 | 100 rows of long text | 0 ms | **+163 ms**
S-5 | 500 rows, filtered to 125 | +2 ms | **+173 ms**
S-6 | a count of 500 rows | +19 ms | **+178 ms**
```

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

```datatable
columns: Ref | Page | Cost per request | What a visitor sees
widths: 1.4cm | 4.2cm | 3.4cm | X
bold: 1
tone: medium
---
T-1 | `db:` with no `ttl:` | **+166 ms** | always current
T-2 | `db:` with `ttl: 300` | **+3 ms** | up to 5 minutes old
T-3 | `json:` (control) | +2 ms | current within the cache's own tracking
```

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

```datatable
columns: Ref | Dataset | Table write | JSON write
widths: 1.4cm | X | 3.4cm | 3.4cm
bold: 1
tone: medium
---
W-1 | 10 records (0.9 KB) | 678 ms | 303 ms
W-2 | 100 records (9.5 KB) | 687 ms | 330 ms
W-3 | 500 records (48.6 KB) | 696 ms | 371 ms
```

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

```datatable
columns: Ref | The data | Store | Why
widths: 1.4cm | 4.6cm | 2.6cm | X
bold: 1
tone: medium
---
C-1 | A price list, a gallery, a set of questions, a lookup table | **JSON** | Author writes it, visitors read it, cache serves it for nothing
C-2 | Anything a visitor or operator submits | **Table** | There is a write path, and it needs to be safe
C-3 | A work queue several people draw from | **Table** | Only a unique key makes the claim atomic
C-4 | Anything not everyone may see | **Table** | A docroot file has no reader check
C-5 | Reference data that changes monthly, on a busy public page | **Either** | Give the page a ttl and both cost the same; decide it on C-2 to C-4
C-6 | Rows that must be right to the second | **Table, no ttl** | The per-request render is exactly what buys that
```

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

**Table names are instance-wide - there is no per-domain namespace.** Every
domain on an instance shares one table space, so a family's school marks would
otherwise sit beside another site's data. Give a private app its **own dedicated
instance** (the fix is deployment, not configuration), or prefix defensively if
it must share one.

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

```datatable
columns: Read path | Filtering
widths: 6.0cm | X
bold: 1
tone: medium
---
`db:t(col=v,order=x,limit=n)` in front matter | conditions AND-combine; `.count(col=v)` and `.field(col,key=x)` too
`/cgi-bin/lazysite-data.pl?table=t` | `order_by`, `order`, `limit`, `offset` **only** - anything else is IGNORED, and the reply looks exactly like a filtered one
```

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
- **Render identity onto the page, never into a `<script>`.** `[% auth_user %]`
  and its siblings are entity-escaped at render entry (0.11.9, SM709), and a
  browser decodes no HTML entities inside `<script>` - so a value interpolated
  into JS arrives as literal entity text (`O'Brien` shows as `O&#39;Brien`),
  whatever filter you use, and `| html` doubles it. Carry it on a hidden
  element's `data-` attribute and read it with `getAttribute`; an attribute
  decodes the entity back. This bit a live app that set `window.FH_ME` from
  `"[% auth_name | html %]"` in five page scripts at once. See
  `AUTHORING-PRACTICE.md`, *Template Toolkit in the page body*, for the pattern
  and for the companion rule (a literal `[%` anywhere in page JS is a TT
  footgun)

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

**Before real names go into a row, decide whether they may travel.** A site
package can carry a table's contents to another organisation, so whether a
column like `allocated_to` or `answered_by` may hold real personal names is a
governance decision to settle with the operator **before first load** - not a
technical default. Where you can, match on a reference (a sales-order number, a
pseudonymous id) and keep names out of site data entirely.

## Build a non-public app inside its own protected folder

For an intranet or a mostly-private app, do **not** build in the docroot and gate
afterwards. Start in a protected subfolder and build there from the first file:
the docroot stays for the public surface only (`/login`, `/forgot`,
`/robots.txt`, the shared `/assets/app` JS), each app gets its own folder so apps
can carry different groups, and a new file is born protected instead of being
public until someone remembers to gate it. Gate by subfolder, **never with a
site-wide ACL at `/`** - an ACL on `/` catches the login page itself and can
leave it in a redirect loop, locking everyone out including you.

**The two protection mechanisms are not interchangeable, and one of them has a
trap that surfaces late:**

- **Pages: render-time auth** (`auth: required`, or a `@group`) in the page's
  front matter. It gates the rendered page at request time; the source stays in
  the docroot, so `::: include` still resolves its partials. Anonymous gets a
  302. This is the safe gate for anything that includes a partial.
- **`acl-set` on a folder MOVES it into the private store.** The `::: include`
  resolver reads the docroot, not the private store - so ACL'ing a folder that
  holds include targets (e.g. `/partials`) **blank-renders every page that
  includes from it**: the body collapses to one `<span class="include-error">`
  and everything after the intro vanishes. The stale page cache hides it until
  the next re-render, so it shows up later as "all the pages broke at once."
  Reserve `acl-set` for leaf content (media, whole standalone pages) that nothing
  includes.

**Private partials: write them as `.md` with `auth: required`, not bare `.html`.**
A bare `.html` partial stays directly GETtable (200) even when the pages
including it are gated. An `.md` partial with `auth: required` is include-readable
but not GETtable: `::: include` strips the front matter and inserts the body (an
HTML-fragment body passes through the Markdown processor unmangled - `<script>`
blocks, deep indentation and classes survive), while a direct GET of the
partial's own path hits the page system, sees `auth: required`, and 302s. No
`acl-set` move is involved, so includes still resolve.

**Protecting media without gating the instance:** a longest-prefix `acl-set` on a
subpath (`/assets/photos`) gates just that path (anonymous → 302) while the rest
of `/assets/` stays public and the app JS still 200s. Set the ACL **before**
publishing so content lands in the private store. Prove it per build with an
anonymous GET - a gated image must be refused, not served byte-identical.

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

**Weigh the admin group's capabilities against who will onboard admins.** To add
a user to a group you must be allowed to *confer* every capability that group
grants - membership is not enough. An admin group carrying `housekeeping` (or
`manage_users`, `ui`) refuses the add with *"it grants 'housekeeping', which you
may not confer"* until an operator runs `group-set <onboarder-group> grantable
housekeeping`. So a powerful capability on the admin group means only a
high-privilege operator can add admins - the owner cannot self-serve. Either
keep the admin group minimal, or agree up front that an operator runs the
one-time `grantable` grant (or does the adds). This is provisioning territory a
partner token never reaches, so surface it early, not at go-live.

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
through `/cgi-bin/lazysite-data.pl`.** Operator's ruling, 2026-08-25, on a custom
stock-corrections build. It is an exception to "forms are native and
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

## A flag that gates the whole app must fail OPEN

An app-wide switch - a "the queue is closed" banner, a maintenance flag - is
often a single-row control table the page reads before deciding what to show.
Enforcement of the *closed* state belongs on the server (drop the writing group
from the table's `writable_by` while it is closed, so the engine refuses every
write regardless of the UI). But the page-side read must treat **a missing row,
or a missing control table, as the permissive/open state** - never as closed. A
lost or un-migrated control row must not strand everyone out of a working app.
The reverse - defaulting closed when the flag can't be read - locks the office
out the first time the row is absent, which is exactly when nobody can fix it.

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
