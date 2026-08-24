---
title: "SM483: three registry conditions nobody has reproduced"
subtitle: "Carved out of SM442 so a shipped fix could close and these could be owned. All three were observed on live sites, none has been reproduced, and none is explained"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.30-bound (the pre-beta batch), fixing all three reproduced mechanisms: (1) the invalidator now derives its cache key from REALPATHS on both sides, exactly as the processor does, and strips whichever docroot spelling prefixes the resolved root - a symlinked content root or a symlinked docroot no longer splits the pair, and regenerate clears what the processor cached; (2) the reader accepts FLOW-STYLE register lists (healing every MCP-created page already deployed) AND the MCP writer now emits block style with names normalised against the registries that actually exist (a bare stem like sitemap resolves to sitemap.xml), with the schema example telling the truth; (3) DAV content writes and deletes invalidate the registries at the same point they maintain the alias map, so a page published over WebDAV reaches the sitemap now rather than at the TTL. t/integration/74 holds all three, built from the reproduction rigs. ORIGINAL NOTE: REPRODUCED 2026-08-24, all three claims, by rig against HEAD (0.10.28) - rigs kept in tmp/sm483-*.pl. CLAIM 1 (frozen registry): TWO mechanisms. A symlink anywhere in the content-root path splits the cache key - the processor caches under the realpath-derived key while the invalidator derives its key from the config string with no realpath (Files.pm _invalidate_registries), so regenerate clears nothing and reports cleared_count:0 while the deleted page keeps serving until the 4-hour TTL; same split when DOCUMENT_ROOT itself is a symlink. Second mechanism: a pre-SM293 leftover file at the content root is served in preference and deliberately never deleted (reported in shadowed_by_files). ALSO: DAV writes/deletes never invalidate registries at all. CLAIM 2 (empty from birth): the MCP writer and the processor reader disagree about the register front-matter FORMAT - create_page writes flow-style register: [sitemap.xml] while the reader parses only block-style lists, AND the tool's own schema example says short names (sitemap) while the reader matches template output names (sitemap.xml) - so every MCP-created page is invisible to every registry while list_pages echoes its registers back as though registered. The fixtures-agree-with-readers defect, in production. CLAIM 3 (accepted-and-discarded sitemap): multi-domain shape REPRODUCED - an unconfined operator's PUT /dav/sitemap.xml answers 201 and lands at the DOCROOT while the domain's registry check looks in the domain's content root, so the write path and read path resolve different files; the single-site shape is DISPROVED (scope confinement answers 403, nothing lands). REMEDY LIST, confirmed by the rigs: derive registry cache keys ONE way (realpath both sides) + invalidate on DAV writes; create_page writes block-style lists with normalised names (or the reader accepts flow style); DAV domain-aware guidance or the file-wins check looking where DAV writes. SIDE FINDING FILED AS SM500: shadowed_by_files returns absolute filesystem paths over MCP for non-docroot roots. ORIGINAL NOTE: CARVED OUT OF SM442 ON 2026-08-23, because carrying them as an open note on a shipped fix meant a filing that could never be closed and a gap nobody owned. SM442 made regenerate-registries say what it CLEARED rather than what it considered, and that shipped; these three are separate field conditions that the fix does not address and was never going to. WHAT MAKES THEM ONE FILING rather than three: all three are a registry that does not hold what the site's content says it should, and the most likely explanations overlap - a per-domain path resolving somewhere unexpected, a write accepted by a channel that does not own the file, or a regeneration that ran against a different root than the one being read. NONE IS REPRODUCED. That is the first piece of work here, and it is deliberately not being guessed at: SM442's own fix exists because ninety minutes went into probing a symptom whose cause was not visible from the outside, and the answer was that the tool reported the wrong thing. The same trap is available here."
---

# The three

```datatable
columns: Condition | Where seen
widths: 7.4cm | X
bold: 1
tone: medium
---
A registry frozen -- kept advertising deleted pages through two regenerations | community.dhcf.eu
A registry empty from birth -- never populated at all | a xisl-family site
`sitemap.xml` accepted over WebDAV with a 201, and discarded | a content-root site
```

The third is the documented escape hatch: an operator who does not like the
generated sitemap is told to write their own. It is accepted and does not take
effect, so the remedy the documentation offers does not work.

# What is not known

Whether these are one fault or three. Whether any is specific to a
**content-root** site -- two of the three were, which is suggestive and is not
evidence. Whether the write path and the read path resolve the same file.

# Why this is filed rather than fixed

Nothing here has been reproduced on a fixture. SM442 exists because ninety
minutes went into probing a symptom whose cause was invisible from outside, and
the eventual answer was that the tool was reporting something other than what
it had done. Guessing at a cause and shipping a change against the guess is the
same mistake with a longer feedback loop.

**First work: reproduce one of them.** The content-root shape is the obvious
place to start, since two of the three had it.

# What is already done

`regenerate-registries` now reports what it cleared rather than what it
considered, so the next occurrence is diagnosable from the first response
instead of from a session of probing. That was SM442 and it shipped; it does
not fix any of the three above, and this filing exists so that saying so does
not require reopening it.
