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
matching nothing. `limit=` is capped at **500**; ask for more and you are told,
rather than served 500 and left wondering.

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
`snapshot` | **the default.** Read once at render and cached with the page, refreshed by the page's `ttl:` like any other content
`live` | read on every request. The page is never cached -- use it for stock levels and queue lengths, and pay for it knowingly
`client` | no rows at render; the page's own script fetches them
```

```yaml
  stock: db:stock(mode=live)
```

A snapshot is **snapshot at render**: a row you change now appears when the
page's `ttl:` next expires, not on the next request. Nothing depends on the
database file's timestamp, because the store is written through WAL and a row
can change without that timestamp moving -- so a dependency on it would report
a freshness it never established.

## Field types

`text`
: Any string. `max:` limits its length; `widget: textarea` hints at the editor.

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

### A table is closed until you publish it

A page's own JavaScript reads rows from `/cgi-bin/lazysite-data.pl?table=<name>`,
and that address is reached directly -- it inherits nothing from any page.
Putting a table behind a gated page gates **the page**, not the table.

So publication is declared on the table itself:

```yaml
public: true
key: code
fields:
  code:
    type: text
```

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

### Who may write

A write needs all three:

- a signed-in session (a public visitor submitting data is what a **form** is
  for -- forms have rate limits, spam controls and a handler that vets what it
  accepts, and a table write has none of that);
- the **`manage_data`** capability;
- membership of a group in the table's **`writable_by`**, if it names any.

`writable_by` only ever **takes access away**. It cannot grant a write to an
account without `manage_data`, because the descriptor is a file an agent can
write -- if the list could widen, an agent could hand write access to a group
it chose.

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

## Where things live

`lazysite/db/tables/<name>.yaml`
: One descriptor per table.

`lazysite/db/data.sqlite`
: The store. One file, so a backup is a copy. Its directory must be **writable
  by whoever reads it** -- the store uses WAL journalling, and a WAL reader
  creates a file beside the database.

`lazysite/db/rebuilds/`
: Safety exports written before a destructive rebuild.
