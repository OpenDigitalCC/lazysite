---
title: AI briefing - data tables
subtitle: Guide for AI assistants declaring tables, loading records, and rendering them on a page.
register:
  - sitemap.xml
---

## Who this is for

This briefs an AI assistant working with a site's **data tables** -- records
the site owns, such as a product list or an events calendar. For page content
see [content authoring](/docs/ai-briefing-authoring); for the operator-facing
version of this material see [Data tables](/docs/data-tables).

You need the **`manage_data`** capability. If the `*_data_*` tools are not in
your tool list, that is your grant, not a fault. The plugin also ships
**disabled** -- an operator enables it on the Plugin Manager page, and until
they do, every call refuses and says so.

## The shape of the work

1. `save_data_table` -- declare the table
2. `migrate_data_table` -- create or update the stored table
3. `save_data_row` -- put records in
4. a page variable -- render them

`list_data_tables` first, on any task that mentions stored records. Learn what
exists rather than guessing a name.

## Declaring a table

You **cannot** write the descriptor with `write_file`. It lives under
`lazysite/`, which every general write channel refuses, so `save_data_table` is
the door -- and it validates before it stores, which a file write could not.

```yaml
title: Products
key: code
fields:
  code:
    type: text
    required: true
  price:
    type: decimal
    digits: 8
    places: 2
```

`key:` names the field that identifies a row. Leave it out and the store
assigns an `id`. Types: `text`, `integer`, `decimal`, `boolean`, `date`,
`datetime`, `enum`. A `decimal` must declare `digits` and `places`; an `enum`
must declare `values`.

**Call `describe_data_table` before writing rows.** A write is refused if a
value does not fit its declared type, and this is how you learn what fits.

## Writing records

`save_data_row` inserts without a `key` and updates with one, touching only the
fields you send.

**Send decimals as strings.** `"120.00"` keeps its trailing zeros; a JSON
number would arrive as `120` and lose them. This matters for money and is the
single most likely thing to get quietly wrong.

A refusal names the field and the reason. It is information, not a failure:

- too many decimal places -- **refused, not rounded**
- a value outside an enum, or an integer outside its bounds
- a date that is not a real date
- a field the table does not declare -- refused rather than dropped, so a typo
  in a column name cannot look like a successful write
- a required field left empty

An empty value means absence. Clearing a number stores nothing rather than `0`.

## Reading on a page

```yaml
tt_page_var:
  products: db:products sort=name asc limit=20
```

`sort=` takes a **declared field name**. The layout then iterates it exactly as
it would a `scan:` list.

**Who sees the rows: the `public:` key** (SM476). A table is closed to
anonymous visitors until its descriptor says `public: true` -- an unpublished
table renders nothing for a visitor, on every page that binds it, and the
data endpoint answers them nothing either. A **signed-in** account is
different: `public:` is about anonymous visitors only, so an authenticated
reader gets rows from an unpublished table unless a **read list** narrows it
-- an ACL entry on `lazysite/db/tables/<name>` (users and `@groups`, same
store and shape as a file ACL; a rule on `lazysite/db/tables` governs every
table at once). That composition is what a gated application wants: leave the
table unpublished, gate the pages, and add a read list when only named
accounts may see the rows. `public: true` plus a read list still refuses the
anonymous visitor -- a list that names accounts cannot name an anonymous one.
If a bound page shows nothing and you expected rows, check `public:` and the
read list before anything else; `validate_page` says which is closed.

If a read returns no rows and says `pending_schema`, the table is declared and
not yet created -- run `migrate_data_table`. That is different from a table
being empty, and the answer says which.

## Changing a table

Add a field, add an index, add a default: edit the descriptor, save it, run
`migrate_data_table`. Safe to re-run.

Change a type, make a field required, or remove one: `migrate_data_table` will
**refuse and tell you**, because all three rewrite the table. Use
`rebuild_data_table` when you mean it. It requires you to name each column
whose data will be lost -- call it without `confirm_lost` first to be told
which. Every row is exported first and the path is returned.

**Ask the operator before rebuilding a table that holds real records.** The
migration refuses these by default precisely because they are not decisions for
whoever happens to be editing the descriptor.

## Checking your work

`preview_public_page` renders a page as an anonymous visitor receives it, under
the Host that owns the path, and reports the layout and theme actually used. It
is how to confirm a data-backed page renders -- what a page *should* look like
is a question about configuration, and what a visitor *got* is a question about
the response.

## What tables are not for

Tables hold **site** data. Per-visitor state -- a session, a basket, somebody's
profile -- is an application and is out of scope. If a task needs one of those,
say so rather than modelling it as a table.

Do not put personal data in a table without asking. A site package can carry
table contents to another organisation, and a directory of names is exactly the
sort of thing an operator should decide about deliberately.
