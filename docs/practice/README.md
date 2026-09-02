---
title: "Field practice: what lives here and who maintains it"
subtitle: "The two source documents from which starter/docs/ai-briefing-practice.md is built and shipped to every site. The site agent maintains them; the release side is custodian of what ships."
brand: plain
standard-margins: true
---

# What these are

| File | What it holds |
| --- | --- |
| `authoring-practice.md` | Building and maintaining sites - layouts, themes, content, the manager |
| `app-practice.md` | Building applications on the engine - data tables, forms, page scripts |

`tools/import-field-practice.pl` assembles both into
`starter/docs/ai-briefing-practice.md`, **which ships inside every lazysite
installation**. `t/lint/89` fails when the served copy and these sources
disagree, so an edit here is not live until the import is re-run and committed.

# Who does what

The **site agent** maintains the content. These are its field notes, written
from real work, and its judgement about what belongs in them is better than
anyone's - that has not changed by moving the files.

The **release side** is custodian of what ships. Whoever answers for a published
document holds the copy that gets published.

# Why they moved here (SM733)

They were read from `/srv/projects/lazysite-sites/` and `/srv/projects/lazysite-apps/`,
which made the shipped briefing depend on two paths outside the repository.
SM597 had already filed that as coupling every gate to a file the repo does not
own.

The 2026-09-02 update showed the second cost. It named three clients - two site
names with a comparative judgement about one of them, and a client project - and
nothing between the notes and the shipped artefact could see it until the import
refused. The people who could act on it did not have the files.

# The one rule these documents have

**Name the shape, not the site.**

A field note's natural instinct is to say where a lesson was learned, and that
instinct is right in a private notebook and wrong in a document installed on
every site. `tools/import-field-practice.pl` refuses to write when the assembled
document contains a client identifier, naming the line.

The list it checks lives in the importer, beside the guard, so that whoever adds
a client to the estate can see it. **It is a list, not a classifier**: a new
client is invisible to it until somebody adds the name.

Every point in these documents that once named a client makes its point just as
well without one - which is the argument that the rule costs nothing.

# Editing them

1. Edit the file here.
2. `perl tools/import-field-practice.pl` - it refuses if a client is named.
3. Commit both the source and the regenerated `starter/docs/ai-briefing-practice.md`.

The import stamps the briefing with `NEXT_VERSION`, so it is stamped for the
release being prepared. `t/lint/89` and the release gate both check that stamp:
a briefing stamped for a different version refuses the cut, in a second rather
than nine minutes in.
