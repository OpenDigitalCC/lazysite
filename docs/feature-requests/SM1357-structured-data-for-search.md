---
id: SM1357
title: "SM1357: structured data for search engines and AI search"
subtitle: "Every site's facts (what it is, where, when it is open, what it offers) are published as schema.org JSON-LD generated from its data tables and schedules, so search engines and AI search read them without anyone writing markup."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: seo
status-note: "SHIPPED (PENDING, 0.16.8) on n773 with ruling 165: structured_data: in a table's descriptor, JSON-LD from public rows, the organisation entry, a row write refreshes its pages, every public page in sitemap.xml and llms.txt (llms_txt: off), check's findings."
---

# Proposed

- **A mapping file:** it maps a data table or schedule to a schema.org type and its properties. An app ships the mapping for its market; the engine ships none for any market.
- **Emitted on the page:** the engine adds the JSON-LD to the pages the mapping names, from the rows that are available now. The site's own details (name, address, contact, hours) form the organisation entry.
- **Freshness:** a change to a row or schedule refreshes the pages that carry its data (the same invalidation as content).
- **Also covered:**
  - a sitemap including every public page;
  - page titles and descriptions checked by `lazysite check`;
  - an AI-readable summary page or file, if ruled.
- **Validation:** `lazysite check` validates the emitted JSON-LD against the mapping's types.

# Questions for ruling

1. Should the AI-readable summary (an `llms.txt` style file) be generated alongside the sitemap?

Ruled (165): the engine generates an AI-readable summary file (llms.txt style) alongside
the sitemap, on by default; a site may turn it off.

# Shipped

## The mapping is the table's descriptor

The mapping lives in the table's descriptor, under `structured_data:` - one mapping per
table, in the file that already describes the table. Why there rather than a separate
mapping file:

- **One door, checked at save.** A descriptor is written through `save_data_table` /
  `data-table-save`, which load it before storing it; a wrong mapping is refused there, by
  name. A separate file under `lazysite/` would have needed a new door on every surface.
- **It travels with its table.** A backup, a site package and an app carry the table and
  its mapping together; an app ships the mapping for its market with its tables, and the
  engine ships none.

```yaml
structured_data:
  type: Event              # a schema.org type
  pages: [/events]         # the pages that carry it
  properties:
    name: title            # a field of the table
    eventStatus: "=https://schema.org/EventScheduled"   # a literal
    location:              # a nested object (three deep at most)
      type: Place
      properties:
        name: venue
```

Checked (`Lazysite::Data::StructuredData::check_mapping`): a type and property must be
schema.org-shaped names, a field must be the table's, a page a site path, at most fifty
pages. On a `schedule: true` table the mapping is one place: literal properties, and the
engine adds `openingHoursSpecification` from the schedule.

## What a page carries

`_inject_structured_data` (layout.pm) puts one `<script type="application/ld+json">`
before `</head>`: the organisation entry on the home page, and every mapping's objects on
the pages it names. The rows are read through `Tables::resolve_binding` as an anonymous
visitor, so a table that is not public publishes nothing and `where:` and the dated window
apply - what is published is what the site already serves publicly. Every value goes
through one inert encoder (ASCII JSON, `<` `>` `&` as `\u` escapes); a link property with
a script-capable scheme is dropped; one mapping emits at most 100 objects. A site that
declares no mapping and states no details loads no module (a line scan of the
descriptors).

The **organisation entry** is from `lazysite.conf`: `site_name`, `site_url`, and the new
`site_type` (default `Organization`), `site_address`, `site_phone`, `site_email`,
`site_hours` (a schedule table). It is published once one of the new keys is set, so a
site that has said nothing about itself publishes nothing new.

## Freshness: a row changed refreshes its pages

Every write the data layer makes - a row saved, deleted or imported, the shape applied,
rebuilt or dropped, on every door - touches the table's change stamp
(`lazysite/db/stamps/<table>`, `Tables::touch_stamp`). A render that read the table
records the stamp in its dependency record (`=<path>`), and the cache renders the page
again when the stamp is newer, on both branches (a `ttl:` does not outlast it), as a saved
page refreshes its own render. This reaches every `db:` page too: a row change used to
wait for the page's `ttl:`. The expiry (SM1356) is the same record's `@<epoch>` line.

## The sitemap and the summary

There was already a sitemap (`sitemap.xml`, a registry) and an `llms.txt` registry, each
listing only the pages that registered for it. Extended, not duplicated:
every page with no `register:` key is listed in both, and a page's own list is kept where
it has one. Ruling 174 (release manager, 2026-11-08): the two are equivalent, built from
ONE page set (`_public_page_set`, which both call) and listing exactly the same pages, so a
page registered for either is in both; protected pages are excluded from both.
t/unit/processor/187 compares the two lists' page paths on one fixture. Ruling 171: a
folder under the docroot that is not a declared content root but looks like another site's
content (`<docroot>/sites/<name>`, or a folder holding its own `lazysite.conf` or
`lazysite/lazysite.conf`) is left out of the walk the page set is built from
(`_foreign_site_folder`), and `lazysite check` names it as served on the bare host with
the remedy (`report_foreign_site_folders`: declare it as a domain's content root, or move
it); t/integration/17 is back to its intent (no `/sites/` path in the bare host's sitemap
or llms.txt). Ruling 176 (n776, at the restack): the site's search and every `scan:` listing
(`resolve_scan`, `_scan_collect_files`) leave such a folder out too - the walk does not
descend into it and a one-level pattern naming it lists nothing - while the bare host
still serves it; t/integration/17 holds both. Never listed: a draft, ACL-governed or gated page
(`_registry_hidden`, as before), anything under `lazysite/` (SM1354's page copies), an
`api:`/`raw:` page, `search: false`, a redirect, `starter_role: demonstration` (SM486) and
the engine's system pages at a content root. `llms.txt` is on by default with titles,
descriptions and an *About* section from the organisation entry (the starter template);
`llms_txt: off` neither generates nor serves it. `page_url_raw` (SM1398, n770) is not on
this base and nothing here needed it: the registries build their URLs from the page
paths they walk, as before.

## lazysite check

`report_page_titles`: a public page with no title, no description (meta_desc or
subtitle), or a title another public page shares. `report_structured_data`: the JSON-LD
every mapping emits now, through the engine's own module, checked against the mapping's
type - the properties a known type needs (an Event's `name` and `startDate`), ISO 8601
dates, the pages named existing, the table readable by a visitor; a type it does not know
is said to be unchecked. `report_time_zone` (SM1356).

Tests: t/unit/processor/186, 187, 185 (a db: page refreshes on a row write); t/tools/340.
