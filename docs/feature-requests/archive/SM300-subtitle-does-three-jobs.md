---
title: "SM300 - subtitle is the visible subheading, the meta description and the llms.txt description"
subtitle: "One field, three audiences. A page with a designed hero cannot have a meta description without also printing a subheading it does not want - so the page that matters most is the one with no description at all."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.9 (7ad34f9). `meta_desc` and `meta_title` override and fall back to `subtitle` / `title`, so every existing page renders unchanged. ADR 0008 had frozen both names while neither existed; implementing them makes that document true, and t/lint/45 now asserts every field the freeze names is actually read by the engine - the class this defect came from. FILED 2026-08-14 from a site-agent report on sovereigncomputing.org. The site's homepage carries a designed hero, so it declares no subtitle - and therefore has NO meta description and is the only description-less entry in its llms.txt. ADR 0008 already names meta_title and meta_desc among the frozen front-matter fields; NEITHER EXISTS anywhere in the codebase, so implementing them makes that document true as well as closing this."
---

# SM300 - one field, three audiences

## What happens now

`subtitle` is read in three places and means something different in each:

- `lazysite-processor.pl:288` - the visible subheading printed under the page
  title;
- `:201` and `:5962` - `<meta name="description">`;
- `registries/llms.txt.tt` - the description in an `llms.txt` entry.

For most pages that is a convenience and works well. It breaks on a page with a
**designed hero**, because a subtitle renders directly above the hero section.
The author's only options are to accept a visible subheading they did not design
for, or to have no description for either search engines or AI clients.

Reported from a live site whose homepage took the second option, so the site's
most important page had no meta description and was the only entry in its
`llms.txt` without one.

## The document that already says this is fixed

`docs/adr/0008-stable-compatibility-freeze.md` lists, under **Page front
matter**, the fields whose "name, meaning, type and default" are frozen for the
stable line - and includes `meta_title`/`meta_desc`.

Neither appears in any `.pl`, `.pm` or `.tt` in the tree, and neither is
documented in `docs/frontmatter.md`, which gives `subtitle` as the only
description field. A document whose entire purpose is to state what will not
change names two fields that do not exist.

That is the same class of defect `t/lint/36` was written for - a factual claim
in a reference document, not asserted against the source - in a document with
more weight than most.

## The fix

Implement `meta_desc` and `meta_title` as front-matter keys that OVERRIDE the
derived values, falling back to `subtitle` and `title` when absent, so:

- every existing page behaves exactly as it does today;
- a page with a hero can declare a description without printing a subheading;
- `llms.txt` and `<meta name="description">` agree, and both prefer the
  explicit value.

Then ADR 0008's list becomes accurate, and `t/lint`-style enforcement can hold
it that way.

## Related

[[SM299]] (the other llms.txt defect from the same report), `docs/adr/0008`,
`docs/frontmatter.md`.
