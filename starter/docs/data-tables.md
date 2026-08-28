---
title: Data tables
subtitle: Tables a site declares and holds - a product list, an events calendar, a directory - read on a page like any other variable.
register:
  - sitemap.xml
---

## Overview

A **data table** is a set of records the site owns: a product list, an events
calendar, a staff directory. You describe its shape in a small YAML file, the
engine keeps the records, and a page reads them through the same page-variable
mechanism it uses for everything else.

Tables hold **site** data. Per-visitor state -- a session, a shopping basket,
somebody's profile -- is an application, and deliberately out of scope.

The feature ships **disabled**. Enable *Data tables* on the Plugin Manager page
before anything below will answer.

## The three steps

### 1. Declare the table

A table is described by YAML. You do not write that file directly: it lives
under `lazysite/`, which holds the account store and the session secret, and
every general write channel refuses that area on purpose. Use the door built
for it, which also **checks the descriptor before storing it**:

- MCP: `save_data_table` with `table` and `descriptor`
- Control API: `POST ?action=data-table-save` with
  `{"table": "products", "descriptor": "…yaml…"}`

```yaml
title: Products
key: code
fields:
  code:
    type: text
    required: true
    max: 20
  name:
    type: text
  price:
    type: decimal
    digits: 8
    places: 2
  in_stock:
    type: boolean
    default: true
```

The table **name** becomes the filename and must be lower-case letters, digits
and underscores. A descriptor that does not load is refused with the field and
the reason, and nothing is written -- so a refusal here is information rather
than a failure.

### 2. Create or update the stored table

Declaring a table does not create it. Run the migration once:

- MCP: `migrate_data_table`
- Control API: `POST ?action=data-migrate&table=products`

It is safe to re-run: a table already in line is a no-op. It applies what is
safe and **reports what it refuses**, and the refused list is the useful half
-- it is the account of why a column is not there yet.

To see that account **before** anything is applied, ask for the plan:

- MCP: `plan_data_migration`
- Control API: `GET ?action=data-migrate-plan&table=products`

It runs the same planner the migration does and changes nothing, so the
preview and the action cannot disagree. To edit a descriptor as the text you
wrote it -- comments, key order and spacing intact -- read it back with
`read_data_table_source` (MCP) or `data-table-source` (Control API), change
it, and save it again.

### 3. Put rows in, and read them out

- MCP: `save_data_row`, `read_data_rows`, `delete_data_row`
- Control API: `data-row-save`, `data-rows`, `data-row-delete`

On a page:

```yaml
---
title: Our products
tt_page_var:
  products: db:products(order=name,limit=20)
  total:    db:products.count()
---
```

and in the layout:

```
[% total %] products
[% FOREACH p IN products %]<li>[% p.name %] — [% p.price %]</li>[% END %]
```

### What you may ask for

```datatable
columns: Written | Means
widths: 7.4cm | X
bold: 1
tone: medium
---
`db:products` | the whole table, declared order
`db:products(featured=true,limit=4)` | filtered, AND-combined
`db:tasks(order=due)` / `(order=-due)` | ordered, ascending or descending
`db:tasks.count(done=false)` | a number, not a list
`db:products.field(price,code=SKU1)` | one value out of one row
```

The older spacing -- `db:products sort=name asc limit=20` -- still means
exactly the same thing.

You may filter or order on **any declared field**. Filtering on a field with
no index means the whole table is examined, which for the sizes these tables
are for costs about as much as nothing: measured at 100,000 rows, an unindexed
`order by ... limit 10` takes 5.6 ms against 0.03 ms indexed, and a filter on a
common value costs nothing either way because the `limit` stops it early.

If a read does turn out slow, **the log says which binding, how long, and which
field to index**:

```yaml
indexes:
  - [name]
```

A compound index `[area, street]` makes `area=` cheap and leaves `street=` a
scan -- an index can only be entered at its first column.

If a table is big enough that an index does not settle it, it has outgrown
SQLite rather than outgrown the query, and the answer is a different engine.

Filter values are checked against the field's declared type, so
`done=perhaps` on a boolean is **refused and says so** rather than quietly
matching nothing. `limit=` is capped at **500**: ask for more and the binding
**clamps to 500 and warns in the render log**, naming the page -- serving what
it can beats rendering nothing. With no `limit=` at all the default is **200**,
so a list that outgrows 200 renders short; the render log says so, and the
page can too: every list binding gets a companion **`<var>_total`** variable
carrying the true count, so a template can write `showing [% items.size %] of
[% items_total %]`. `.count()` is the **true count** as well -- it ignores any
`limit=` beside it.

Anything this grammar will not express -- joins, ranges, OR -- is deliberate.
Front matter is not a place for a query language.

The **data endpoint** takes `order_by`, `order`, `limit` and `offset` in its
query string and runs them through this same grammar, so a page and its own
script cannot be told different things about one table.

### When the rows are read

```datatable
columns: Mode | When
widths: 3cm | X
bold: 1
tone: medium
---
`snapshot` | **the default.** Read at render. The page is served from cache for its `ttl:`, and re-rendered on every request if it declares none
`live` | as `snapshot` today -- see the note below. Intended for stock levels and queue lengths
`client` | no rows at render; the page's own script fetches them
```

```yaml
  stock: db:stock(mode=live)
```

**`live` and `snapshot` currently behave identically, and this table used to
say otherwise.** It said `live` was "read on every request, the page is never
cached". That was wrong in a way worth spelling out, because an agent read it,
reasoned correctly from it, and reached a false conclusion.

A table has no timestamp that can prove a cached page still current, so a
binding withdraws the *mtime* proof of freshness. It does not touch the page's
`ttl:`, which is a separate mechanism and the only one such a page has. So a
page carrying `ttl: 300` is served from cache for five minutes whatever its
mode, and a page carrying no `ttl:` is re-rendered every request whatever its
mode. "Never cached" was only ever true of the second case.

Since SM604 every `db:` binding withdraws that proof - it had to, because
otherwise one `json:` binding on the same page vouched for the table's
freshness, which nothing can do. That is what leaves the two modes with no
observable difference. `mode=live` is accepted and parses; it does not change
behaviour today. Do not choose between them on the strength of caching: choose
a `ttl:`.

A snapshot is **snapshot at render**: a row you change now appears when the
page's `ttl:` next expires, not on the next request. Nothing depends on the
database file's timestamp, because the store is written through WAL and a row
can change without that timestamp moving -- so a dependency on it would report
a freshness it never established.

## Removing a table

A table can be removed, and until 0.10.27 it could not be -- declaring one was
reachable from three surfaces and removing one from none, so a table made by
mistake, or renamed, or created for a single test was permanent.

- MCP: `drop_data_table`
- Control API: `data-table-drop`

Every drop, and every rebuild that loses a column, writes a **safety export**
first under `lazysite/db/rebuilds/` -- the only copy of the rows it removed.
`list_data_safety_exports` (control API `data-safety-exports`) lists them with
their table, kind and stamp; `delete_data_safety_export`
(`data-safety-export-delete`) clears one by its exact file name, audited.
`read_data_safety_export` (`data-safety-export-read`) opens one -- table,
key, fields, rows -- and the listing carries each export's row count and a
key sample, so it can be judged first. `restore_data_safety_export`
(`data-safety-export-restore`) offers the rows back to their table: a plan
without `apply`, a write with it; columns the table no longer has are
reported, not refused -- re-declare them and restore again. Read an export,
or know it came from a throwaway, before clearing it.

**It takes everything**: the descriptor, the stored table and every row. So it
asks first, and the confirmation is the table's own name rather than a yes:

```
drop_data_table { "table": "old_prices" }
-> needs_confirmation, naming what would be lost

drop_data_table { "table": "old_prices", "confirm": "old_prices" }
-> dropped
```

**A safety export is written before anything is dropped**, beside the rebuild
exports in `lazysite/db/rebuilds/`, and its path is returned. The table is not
recoverable; the data is.

If the export cannot be written, nothing is dropped.

## Field types

`text`
: Any string. `max:` limits its length; `widget: textarea` (or `input`) says
  how it should be edited -- a 500-character description and a short title are
  the same kind of value and differ only in how you type them.

`integer`
: A whole number. `min:` and `max:` bound it.

`decimal`
: A fixed-point number, for money and anything else that must not drift.
  **Requires `digits:` and `places:`** -- a decimal without them is a float
  wearing a name. Stored and returned as a string so it never passes through a
  floating-point value: `120.00` comes back as `120.00`.

`boolean`
: Yes or no. Accepts `1/0`, `true/false`, `yes/no`, and stores `0` or `1`.

`date`
: `YYYY-MM-DD`, checked against the calendar -- `2025-02-30` is refused.

`datetime`
: `YYYY-MM-DD HH:MM:SS`, UTC, normalised to one spelling so string ordering
  and chronology agree.

`enum`
: One of a declared list. **Requires `values:`**.

Every field may carry `required: true` and a `default:`.

## What a write is refused for, and why

The store **checks rather than repairs**. Each of these is refused with the
field named:

- a decimal with more places than declared -- refused, **never rounded**. A
  store that silently rounds money is worse than one that will not take it.
- a date that is not a real date
- a value outside an enum's list, or an integer outside its bounds
- a field name the table does not declare -- refused rather than ignored, so a
  typo cannot look like a successful write
- a required field left empty

An empty value means **absence**, not zero: clearing a number stores nothing
rather than `0`, since `0` would be data the author did not enter. A text field
keeps its empty string, which is a real value.

## Changing a table

Editing the descriptor and re-running the migration handles anything additive
-- a new field, a new index, a default filled in on the rows that predate it.

Three changes are **refused and reported** instead: changing a field's type,
tightening one to required, and removing one. All three rewrite the whole
table, which is not something to do because a descriptor changed.

When you do want one, use `rebuild_data_table` (MCP) or `data-rebuild` (API).
It asks you to **name each column whose data will be lost** -- call it without
the list first to be told which those are. A list rather than a yes/no on
purpose: agreeing to lose one column you read about should not agree to a
second you did not notice. Every row is exported to `lazysite/db/rebuilds/`
before anything is dropped, and the path comes back with the result.

## Backups and handing a site over

A **backup** carries table data. A **site package** carries it only when you
ask, naming the tables:

```json
{"host": "clients.example", "data_tables": ["products"]}
```

Opt-in because a package is a portable hand-over artefact: shipping table
contents by default would mean handing a third party whatever is in a directory
or a contact table. The tables are named rather than switched on, because the
store is instance-wide -- there is no such thing as *this domain's* data, and a
flag would sweep another site's tables into the package.

A package **says what it left behind**: `data_omitted` counts declared tables it
does not carry, so whoever receives it learns the tables exist. On apply, a
table that already holds rows is **refused, not overwritten** -- restoring over
a live product list would replace it with a snapshot from whenever the package
was built.

## Access

Reading and writing tables through the manager, the API or MCP needs the
**`manage_data`** capability, granted like any other through a group.

A **page binding** is not a capability question: it renders as part of the
page, so a gated section's table is as reachable as the section is.

### On an instance hosting several domains

`manage_data` is an **instance** capability, and a table name is
instance-wide -- there is one `lazysite/db/tables/` for the whole
instance, not one per domain. On a single-site instance that is all there
is to know.

Where one instance serves several domains belonging to different people,
say which domain a table belongs to:

```yaml
domain: shop.example.com
```

A caller whose grant confines it to one domain's content then reaches
that domain's tables and no others -- and is not told that the rest
exist, because a table name is itself a disclosure. That is why an
unpublished table is invisible to a visitor in the first place.

**A table that names no domain is reachable by any `manage_data`
holder on the instance.** That is deliberate, so an upgrade takes nothing
away from a running application, and it means the protection is opt-in:
until you write `domain:` on a table, a partner scoped to a neighbouring
domain can read it.

Two things follow, and both matter on a shared instance:

- Add `domain:` to every table on an instance that hosts unrelated
  parties. `lazysite-check` lists the ones that lack it.
- An operator's own grant is normally unconfined, and an unconfined
  caller reaches everything by design. The confinement describes what a
  *partner* reaches, not what you do.

The older mitigation still works and composes with this: ACL lookup takes
the longest matching prefix, so a restrictive rule on
`lazysite/db/tables` plus a per-table rule for each site's own people
closes the same gap by hand.

### The order the table is in

A gallery is an ordered list -- somebody chose the sequence. Say so once, on
the table, rather than repeating `order=` in every binding and getting it wrong
in one of them:

```yaml
default_order: position     # or -position, for descending
```

A binding that names its own order still wins; this fills the gap when one
does not.

### Saying a value is unique

`key:` says which field identifies a row. To say that *another* field must also
be unique -- a slug, a reference, an email -- mark the field:

```yaml
fields:
  slug:
    type: text
    unique: true
```

Two rows cannot then share a value. Empty values are exempt: any number of rows
may leave it blank, which is what "unique" means everywhere else and is worth
saying because the opposite is a fair guess.

Adding `unique: true` to a field that already holds duplicates is **reported,
not attempted** -- the migration tells you which value appears twice, and you
make the existing rows distinct before migrating again.

### A table is closed until you publish it

A page's own JavaScript reads rows from `/cgi-bin/lazysite-data.pl?table=<name>`,
and that address is reached directly -- it inherits nothing from any page.
Putting a table behind a gated page gates **the page**, not the table.

**The endpoint reads four query parameters and no others:** `order_by`,
`order`, `limit`, `offset`. Anything else is **ignored, not refused** - so
`?table=t&chunk=AAA` returns *every* row, in a reply shaped exactly like a
filtered one. Filter on the page binding (`db:t(chunk=AAA)`), which does
support conditions, or filter the rows in your own script after reading them.
Never read an unfiltered result as a filtered one (SM606).

So publication is declared on the table itself:

```yaml
public: true
key: code
fields:
  code:
    type: text
```

`public` (like `timestamps`, `required` and `unique`) accepts `true`/`false`,
`yes`/`no`, `on`/`off` or `1`/`0` in any case; any other word is refused when
the descriptor loads, so a flag never silently reads as the opposite of what
you wrote.

**The default is `false`**, and a table is a store rather than a published
artefact -- a file is under the docroot because you put it there to be served,
and a table is not. Until you publish it, an anonymous visitor sees nothing:
not the rows, and not that the table exists at all. It answers exactly as a
table that was never declared does, so nobody can discover your table names by
guessing at them.

`public` is about **anonymous visitors**. Any signed-in account may read an
unpublished table unless an ACL says otherwise, which is the next section.

### Narrowing to accounts and groups

Tables use the **same read/write lists as files**, in the same store, with the
same meaning: entries are a username or `@group`, and no entry means no
restriction. A table's ACL path is its descriptor's own path:

```
lazysite/db/tables/<name>
```

Because the matcher takes the longest matching prefix, a rule on
`lazysite/db/tables` governs **every** table at once, and a site-wide private
rule covers tables exactly as it covers pages.

A read list and `public: true` **compose rather than compete**: a published
table that also carries a read list still refuses an anonymous visitor, because
an anonymous visitor matches no entry in a list.

**An operator is not asked.** The manager, MCP and the API have already
answered the capability question with `manage_data`, so they read regardless. A
**page** is never treated as an operator -- it renders the same rows for
whoever is looking at it, so what you see while signed in is what your visitors
see.

### Collecting data from visitors

A visitor cannot write to a table directly, and that is deliberate: the data
endpoint refuses an anonymous write. **Use a form.** A form has rate limits,
spam assessment, quarantine and an audit trail, and a data binding taking
anonymous writes would rebuild that surface without any of it.

Point a form handler at a table:

```
handlers:
  - id: store-enquiries
    type: db
    table: enquiries
    fields: name=name,email=email,message=body
```

`fields` reads **form field = column**, and it is required. A form field nobody
maps is **dropped**, so a form gaining a field cannot start writing a column,
and a visitor cannot choose where their data goes by naming a field after one.

Values go through the same checks as any other write, so a submission that does
not fit the declared types is **refused rather than stored wrong** -- the
visitor is told the submission failed instead of being thanked for one that was
quietly lost.

The data plugin must be enabled; a form pointed at a table while it is switched
off refuses and says so.

A handler of `type: table` takes the same `table` and `fields` keys and does
the same insert, **and** keeps the JSONL submissions store written alongside --
the Submissions page, `read_form_submissions`, exports and bulk delete keep
working exactly as for a `file` handler. A submission the table's types refuse
leaves **no row** and the stored copy is marked `_row_refused`, the same shape
as a rejected import row. Reading the **table's** rows is governed by the
table's own declaration, like any other table: `manage_data` on the operator
surfaces, page bindings only what the descriptor declares readable, and
`public` defaults to closed -- a form never publishes its submissions by
landing them in a table. The JSONL copy stays under `read_submissions`.

### Who may write

A write through the manager, the API, MCP or the data endpoint needs all
three:

- a signed-in session (a public visitor submitting data is what a **form** is
  for -- forms have rate limits, spam controls and a handler that vets what it
  accepts, and a table write has none of that);
- the **`manage_data`** capability;
- membership of a group in the table's **`writable_by`**, if it names any.

### Quietening a table's row audit

Every row write is recorded in the audit trail with the row's key, so an auditor
can tell **which** row changed rather than only that the table did. On a table
with thousands of rows that is thousands of lines.

`audit_rows: off` in the descriptor turns the per-row lines off for that table
only. Nothing else turns them off: an absent key, a typo, or any value other
than `off` / `false` / `0` leaves the table audited, because a misspelling must
not quietly stop recording who changed what.

```yaml
key: code
audit_rows: off
fields:
  code:
    type: text
```

**The table-level events are unaffected.** Declaring, altering, migrating,
dropping and importing each remain one audited event whatever this says - so
quietening a noisy table never silences the record that it was restructured,
emptied or bulk-loaded.

Before reaching for it: a bulk load belongs in `data-import`, which is already
one event for the whole file. The volume this addresses is an application
writing rows one at a time, where each really is a separate act.

`writable_by` only ever **takes access away**. It cannot grant a write to an
account without `manage_data`, because the descriptor is a file an agent can
write -- if the list could widen, an agent could hand write access to a group
it chose.

`writable_by` means two different things, depending on which capability the
caller holds.

For **`manage_data`** it only ever **takes access away**: a holder writes every
table, except those naming groups it is not in.

For **`write_data`** it is an **allow-list**: a holder writes only the tables
that name one of its groups, and a table naming nobody is closed to it entirely.

| Caller holds | no `writable_by` | `writable_by: [secretaries]` |
|---|---|---|
| `manage_data` | writes | writes only if in `secretaries` |
| `write_data` | **refused** | writes only if in `secretaries` |

That asymmetry is what keeps the descriptor from being a grant. The file is
writable by any agent holding `manage_data`, so if the list could hand write
access to an account that had none, an agent could give it to a group it chose.
It cannot: `write_data` comes from the group store, where an operator granted
it, and the list only says which tables that grant reaches.

`write_data` is the grant for an app's own users -- a learner writing their own
submissions, a member updating their own record. It permits row insert, update
and delete and nothing else: no declaring, altering, migrating or dropping a
table, and no reach into a table that does not name them. Where `manage_data`
would mean handing instance-wide data administration to your least-trusted user
class, this is what to grant instead.

```yaml
key: code
writable_by:
  - secretaries
fields:
  code:
    type: text
```

Leave it out and any `manage_data` holder may write.

**`writable=` on a page binding is not a permission.** It tells the page's own
script whether to offer editing controls. The endpoint cannot see which page
called it, so a marker in front matter could never gate anything.

### Calling the endpoint

`/cgi-bin/lazysite-data.pl` -- reached directly, so it is available to a page's
JavaScript wherever that page lives.

```datatable
columns: Call | Answers
widths: 8cm | X
bold: 1
tone: medium
---
`GET ?table=notes` | `{ok, table, rows}`
`GET ?table=notes&order_by=code&order=desc&limit=20&offset=40` | the same, ordered and paged
`GET ?csrf=1` | `{ok, token}` for a signed-in caller, and nothing for anyone else
`POST ?table=notes` with `X-CSRF-Token` | `{"row": {...}}` to insert, `{"key": "...", "row": {...}}` to update
`POST ?table=notes` with `{"key": "...", "delete": 1}` | removes that row
```

A write that is refused says which of the three gates stopped it -- `kind` is
`anonymous`, `csrf` or `forbidden` -- so a page can tell "sign in" from "your
token went stale" from "this is not yours to edit" and say the right thing.

Fetch the token once per page and reuse it; fetch a fresh one and retry if a
write comes back `csrf`.

### Filling a region from the page itself

You do not have to write the fetching. Declare a region and what one row looks
like, and the shipped helper does the rest:

```html
<ul data-ls-db="products" data-ls-db-order="-price" data-ls-db-limit="10">
  <template>
    <li><span data-ls-field="name"></span> —
        <em data-ls-field="price"></em></li>
  </template>
  <p data-ls-empty>Nothing here yet.</p>
</ul>
```

```datatable
columns: Attribute | Means
widths: 6.4cm | X
bold: 1
tone: medium
---
`data-ls-db` | the table to read
`data-ls-db-order` | a field, `-field` for descending
`data-ls-db-limit` / `-offset` | how many, from where
`data-ls-db-every` | refresh every N seconds -- **opt in**, minimum 5
`data-ls-field` | on any element inside the template: put this column's value here
`data-ls-empty` | shown when there are no rows, hidden when there are
```

The script is added to a page **only when that page has a region**, so a site
that never uses one ships nothing extra.

**Values are inserted as text, never as markup.** A row containing `<script>`
renders as those characters. This matters because rows can arrive from a public
form, and a helper that treated them as markup would turn a contact form into a
way to run script on every visitor's page.

A refresh that fails **leaves what is already on the page**. Content a minute
old beats an empty list because one request timed out.

Regions load when they come into view, so a table below the fold on a page
nobody scrolls costs nothing. Nothing polls unless you set `data-ls-db-every`.

The helper reads through the same endpoint and the same rules as anything else:
an unpublished table returns nothing to it, exactly as it does to anyone.

## Where things live

`lazysite/db/tables/<name>.yaml`
: One descriptor per table.

`lazysite/db/data.sqlite`
: The store. One file, so a backup is a copy. Its directory must be **writable
  by whoever reads it** -- the store uses WAL journalling, and a WAL reader
  creates a file beside the database.

`lazysite/db/rebuilds/`
: Safety exports written before a destructive rebuild.
