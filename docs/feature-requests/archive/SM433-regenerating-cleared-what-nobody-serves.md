---
title: "SM433: regenerate-registries cleared a path the server stopped reading"
subtitle: "SM293 moved the generated registries into a cache directory. The invalidator was not moved with them - so the control reported success, cleared nothing a visitor sees, and the artefact stayed stale for its full four-hour TTL."
brand: plain
standard-margins: true
status: shipped
status-note: "THREE TESTS AGREED WITH THE CODE ABOUT THE WRONG PLACE, which is why this survived from SM293 until a field report: t/unit/manager/21 (SM087), t/unit/manager/55 (SM251 per-content-root) and t/unit/mcp/18 all seeded a registry at $root/<name> and asserted it was removed. Each was written beside the code it tested and inherited its assumption, so the suite confirmed the invalidator did exactly what it did - to a file nobody serves. All three now seed and assert the served location; every property they existed to prove (SM087 invalidate-on-save/delete, SM251 both roots not just the docroot) is unchanged. A test written from the same premise as the code cannot falsify the premise. FOUND 2026-08-20 from a field observation and reproduced on disk before any change: `regenerate-registries` deletes $root/<name>, the pre-SM293 location, while _serve_registry reads lazysite/cache/registries/<key>/<name>. The two have pointed at different files since SM293 step 3 moved the registries out of the document root. The field measured the consequence without being able to name it - two regenerate calls, both reporting cleared_roots, the served sitemap unchanged after a page had been renamed out of it - and correctly said they could not tell from outside whether the artefact was not rebuilding or a cache was holding it. It was neither: the rebuild trigger was deleting a file nobody reads. THE SECOND DEFECT IS WORSE AND NOBODY HAD FILED IT: since SM293, _serve_registry returns early when $root/<name> exists, because 'an operator who wrote their OWN sitemap.xml as content keeps it' - so the path the invalidator deleted became a supported home for OPERATOR CONTENT, and a routine regenerate would have deleted a hand-written sitemap with no warning. Fixing the first without noticing the second would have left a data-loss bug behind a newly-working control. NOW: the cache artefacts are cleared, the in-docroot file is never touched, and a shadowing file is REPORTED by name in shadowed_by_files with a note saying why regenerating cannot change what is served while it wins - which is the answer to 'I regenerated twice and nothing changed'."
---

# The two paths

```datatable
columns: Component | Path
widths: 5cm | X
bold: 1
tone: medium
---
`_serve_registry` reads | `lazysite/cache/registries/<key>/<name>`
`_invalidate_registries` deleted | `<root>/<name>` (pre-SM293)
```

::: widebox
A control that reports success and changes nothing is the shape this project
keeps finding. This one had an extra turn: the path it *was* deleting had
since become a place operators are invited to put their own content.
:::

# What an operator now gets

A regenerate on a site with a leftover or hand-written registry in the docroot
returns `shadowed_by_files` naming it, and a note saying the generated
registry cannot reach a visitor while that file exists. The file is not
deleted: we cannot prove we wrote it.

# Verification

`t/unit/manager/83`: the served artefact is cleared; an operator-authored
`sitemap.xml` survives with its bytes intact; the shadow is reported by name
with the explanatory note; and a control asserting a clean site reports **no**
shadow and the ordinary note - without which a response that always warned
would pass. Three sabotages bite: clearing the old path, deleting the
operator's file, and finding the shadow but staying silent.
