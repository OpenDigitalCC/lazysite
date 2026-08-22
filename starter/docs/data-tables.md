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
  products: db:products sort=name asc limit=20
---
```

and in the layout:

```
[% FOREACH p IN products %]<li>[% p.name %] — [% p.price %]</li>[% END %]
```

`sort=` takes a **declared field name**; `limit=` and `offset=` page through.
A page bound to a table is rendered on every request rather than cached,
because no file timestamp can prove such a page current.

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

Reading and writing tables needs the **`manage_data`** capability, granted like
any other through a group. A page binding is not a capability question: it
renders as part of the page, and a gated section's table is as reachable as the
section is.

## Where things live

`lazysite/db/tables/<name>.yaml`
: One descriptor per table.

`lazysite/db/data.sqlite`
: The store. One file, so a backup is a copy. Its directory must be **writable
  by whoever reads it** -- the store uses WAL journalling, and a WAL reader
  creates a file beside the database.

`lazysite/db/rebuilds/`
: Safety exports written before a destructive rebuild.
