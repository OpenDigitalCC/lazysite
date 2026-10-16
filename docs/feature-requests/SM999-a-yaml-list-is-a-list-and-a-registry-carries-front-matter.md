---
id: SM999
title: "SM999: a YAML list is a list, and a registry carries the page's front matter"
subtitle: "A registry object held seven fields and a list key other than tags arrived as raw text, so a 1,745-post index could not list a post's author, categories or tags."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a 1,745-post site on 0.15.3, item 2); WORK-PLAN-0154 P12 and P13; ruling of 2026-10-12
area: rendering
status-note: "SHIPPED (0.15.5): flow and block lists of scalars parse as lists for every non-engine key (scan, registry, page_<key>); registry objects carry the scan's custom keys and tags less _front_matter_private (t/unit/processor/101)."
---

# The ruling

"Full front matter + general lists": registry objects carry the same
front-matter keys a scan object has (minus engine-private keys - define the
private set and say it); any YAML block or flow list is parsed as a list (not
only tags), in the scan and registry objects and page vars - check SM980's
single access-key reader is not disturbed and the processor/lib marked copies
stay equal.

# Lists (P13)

`parse_yaml_front_matter` (lazysite-processor/front-matter.pm) ends with
`_front_matter_lists`: a key whose value is

- a flow list `key: [a, "b c", d]` - split as the `sections:` parser splits
  flow (quotes respected), one level of quotes stripped, TT markers stripped; or
- a block list: every line below `key:` until the next key is a `- item` at one
  indent (the key's own column too, which is valid YAML), with blank and comment
  lines allowed

is a list. A list of mappings (`- name: x`), a nested list, or a block with any
other line in it is not a list of scalars and is left as the scalar loop read
it, as before. `[]` is an empty list.

**The engine's keys are not touched** (`_front_matter_engine_keys`): auth,
auth_groups, payment, form, register, tt_page_var, sections, query_params,
layout, theme, title, subtitle, meta_title, meta_desc, date, search, api, raw,
content_type, ttl, redirect, lang. Each has its own reading, and a list where
the engine reads one scalar would change what a page does. A key already read
as a list (tags, a block) is left as read; `tags: [a, b]` is now a list too.

**SM980 is not disturbed.** SM980 (on the security agent's stack, not yet on
main) gives auth, auth_groups and payment one reader, `_access_keys_read`,
shared by the gate's peek and this parse. Those three keys are in the engine
set, so this pass never writes them; the gate reads its own peek, not this
parse. The new subs sit at the end of the part, apart from where SM980 adds
its own.

**Marked copies.** `Lazysite::Manager::Common::page_form` (lint 219) reads
`form`, which is an engine key: unchanged, and lint 219 passes.
`Lazysite::Validate::read_access_keys` (SM980) reads the access keys only.
Nothing in lib/ copies the general key parse.

# Where a list arrives

- **A scan object**: `_front_matter_custom` (registries.pm) - the loop
  resolve_scan had, lifted so the registries share it - carries a list as a
  list. `filter=categories:news` matches an item, as it did for tags.
- **The page's own stash** (render.pm): `page_<key>` is a list of escaped
  strings for a list of scalars. Scalars as before; the engine's lists
  (`_front_matter_private`) stay out.

# Registry objects (P12)

`scan_pages` adds `_front_matter_custom( $meta, $reserved, $private )` and
`tags` (a list, `_page_tags`, shared with the scan) to each object; the seven
fields it had are unchanged and take precedence.

**The engine-private set** (`_front_matter_private`, registries.pm): a registry
is a static file served to anyone, so beyond the reserved keys (computed
fields, or the engine's) and `tt_*`/`_*`, it never publishes auth_groups,
payment, form, query_params, sections, tt_page_var, api, raw, content_type,
ttl or redirect - who may read a page, what it costs, which form it binds and
how it is served. A registry lists only public pages already
(`_registry_hidden`); the set keeps the engine's settings out of what it says
about them. The scan object is unchanged in this respect: it renders for a
reader the scan's gate has admitted.

# Behaviour change

A key that was a list in the source and reached a template as raw text now
reaches it as a list: `[% page_categories %]` renders as an array reference
where it rendered `- "Perl"`; write `[% page_categories.join(', ') %]`.

# Tests

t/unit/processor/101: block and flow lists (quotes stripped), tags as a flow
list, `[]`; a list of mappings left as read; form, auth_groups, payment and
register keep their readings; `page_categories`/`page_keywords` are lists in
the page; a scan filters on a list item; a registry object carries author,
categories, keywords and tags and does not carry form, auth_groups or payment.
t/unit/processor/60 updated for lists in the stash (each item escaped).
